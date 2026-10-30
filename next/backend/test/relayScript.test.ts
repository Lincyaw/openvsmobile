import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const SCRIPT = resolve("pkg/relay.py");
let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ovsm-relay-config-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});
function configure(args: string[] = []) {
  return spawnSync(
    "python3",
    [SCRIPT, "--dir", dir, "--configure-only", ...args],
    { encoding: "utf8" },
  );
}
function read(name: string) {
  return readFileSync(join(dir, name), "utf8");
}
function toml() {
  const result = spawnSync(
    "python3",
    [
      "-c",
      "import json,sys,tomllib;print(json.dumps(tomllib.load(open(sys.argv[1],'rb'))))",
      join(dir, "config.toml"),
    ],
    { encoding: "utf8" },
  );
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}

describe("one-command relay setup", () => {
  it("creates TLS/QAD, secret files and valid compose configuration; reruns preserve credentials", () => {
    const configured = configure([
      "--domain",
      "relay.example.com",
      "--email",
      "ops@example.com",
    ]);
    expect(configured.status, configured.stderr).toBe(0);
    const token = read("token").trim();
    expect(token).toMatch(/^[0-9a-f]{64}$/);
    expect(configured.stdout + configured.stderr).not.toContain(token);
    const config = toml();
    expect(config.access.shared_token).toEqual([token]);
    expect(config.enable_quic_addr_discovery).toBe(true);
    expect(config.tls).toMatchObject({
      cert_mode: "LetsEncrypt",
      hostname: "relay.example.com",
      quic_bind_addr: "0.0.0.0:7842",
    });
    const compose = JSON.parse(read("compose.json"));
    expect(compose.services.relay.ports).toEqual([
      "0.0.0.0:80:80/tcp",
      "0.0.0.0:443:443/tcp",
      "0.0.0.0:7842:7842/udp",
    ]);
    for (const name of [
      "token",
      "config.toml",
      "backend.env",
      "settings.json",
      "compose.json",
      "openvsmobile-relay.conf",
    ])
      expect(statSync(join(dir, name)).mode & 0o777).toBe(0o600);
    expect(statSync(dir).mode & 0o777).toBe(0o700);
    expect(read("openvsmobile-relay.conf")).toContain(
      `Environment="OPENVSMOBILE_IROH_RELAY_TOKEN=${token}"`,
    );
    const previous = read("config.toml");
    expect(configure().status).toBe(0);
    expect(read("config.toml")).toBe(previous);
    expect(read("token").trim()).toBe(token);
    const shell = spawnSync("bash", [
      "-c",
      'source "$1"; test "$OPENVSMOBILE_IROH_RELAY_URLS" = https://relay.example.com; test "$OPENVSMOBILE_IROH_RELAY_QUIC_PORT" = 7842',
      "bash",
      join(dir, "backend.env"),
    ]);
    expect(shell.status).toBe(0);
    // This validates against real Docker Compose when available, without a daemon.
    const version = spawnSync("docker", ["compose", "version"]);
    if (version.status === 0) {
      const checked = spawnSync(
        "docker",
        ["compose", "-f", join(dir, "compose.json"), "config", "--quiet"],
        { encoding: "utf8" },
      );
      expect(checked.status, checked.stderr).toBe(0);
    }
  });

  it("supports LAN HTTP and switching to HTTPS without changing the token", () => {
    const configured = configure([
      "--http",
      "--host",
      "10.20.0.5",
      "--port",
      "13340",
      "--bind",
      "127.0.0.1",
    ]);
    expect(configured.status, configured.stderr).toBe(0);
    expect(toml().tls).toBeUndefined();
    expect(toml().enable_quic_addr_discovery).toBe(false);
    expect(read("backend.env")).toContain(
      "OPENVSMOBILE_IROH_RELAY_QUIC_PORT=off",
    );
    expect(JSON.parse(read("compose.json")).services.relay.ports).toEqual([
      "127.0.0.1:13340:13340/tcp",
    ]);
    const token = read("token");
    expect(configure().status).toBe(0);
    expect(
      configure(["--domain", "relay.example.com", "--email", "ops@example.com"])
        .status,
    ).toBe(0);
    expect(toml().tls.hostname).toBe("relay.example.com");
    expect(read("token")).toBe(token);
  });

  it("uses custom HTTPS/QAD ports with supplied certificates and preserves renewal sources", () => {
    const cert = join(dir, "source fullchain.pem");
    const key = join(dir, "source privkey.pem");
    function issueCertificate() {
      const issued = spawnSync(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "ec",
          "-pkeyopt",
          "ec_paramgen_curve:P-256",
          "-nodes",
          "-keyout",
          key,
          "-out",
          cert,
          "-days",
          "1",
          "-subj",
          "/CN=relay.example.com",
          "-addext",
          "subjectAltName=DNS:relay.example.com",
        ],
        { encoding: "utf8" },
      );
      expect(issued.status, issued.stderr).toBe(0);
    }
    // Keep source certs outside the directory whose contents the installer owns.
    const stateDir = join(dir, "relay-state");
    const setup = (args: string[] = []) =>
      spawnSync(
        "python3",
        [SCRIPT, "--dir", stateDir, "--configure-only", ...args],
        { encoding: "utf8" },
      );
    const stateRead = (name: string) =>
      readFileSync(join(stateDir, name), "utf8");
    issueCertificate();
    const configured = setup([
      "--domain",
      "relay.example.com",
      "--https-port",
      "8443",
      "--quic-port",
      "9842",
      "--tls-cert",
      cert,
      "--tls-key",
      key,
    ]);
    expect(configured.status, configured.stderr).toBe(0);
    const compose = JSON.parse(stateRead("compose.json"));
    expect(compose.services.relay.ports).toEqual([
      "0.0.0.0:8443:443/tcp",
      "0.0.0.0:9842:7842/udp",
    ]);
    expect(stateRead("config.toml")).toContain('cert_mode = "Reloading"');
    expect(stateRead("backend.env")).toContain(
      "OPENVSMOBILE_IROH_RELAY_URLS=https://relay.example.com:8443",
    );
    expect(stateRead("backend.env")).toContain(
      "OPENVSMOBILE_IROH_RELAY_QUIC_PORT=9842",
    );
    expect(stateRead("certs/manual/fullchain.pem")).toBe(
      readFileSync(cert, "utf8"),
    );
    expect(
      statSync(join(stateDir, "certs/manual/privkey.pem")).mode & 0o777,
    ).toBe(0o600);
    const token = stateRead("token");
    const previous = stateRead("config.toml");
    const beforeRenewal = stateRead("certs/manual/fullchain.pem");
    issueCertificate();
    expect(setup().status).toBe(0);
    expect(stateRead("certs/manual/fullchain.pem")).not.toBe(beforeRenewal);
    expect(stateRead("certs/manual/fullchain.pem")).toBe(
      readFileSync(cert, "utf8"),
    );
    expect(stateRead("token")).toBe(token);
    expect(setup(["--tls-cert", cert]).status).not.toBe(0);
    expect(setup(["--https-port", "0"]).status).not.toBe(0);
    expect(setup(["--quic-port", "65536"]).status).not.toBe(0);
    writeFileSync(key, "invalid private key");
    const invalid = setup();
    expect(invalid.status).toBe(1);
    expect(invalid.stderr).not.toContain("invalid private key");
    expect(stateRead("config.toml")).toBe(previous);
  });

  it("rejects malformed inputs without overwriting working files or exposing secrets", () => {
    expect(configure(["--http", "--host", "localhost"]).status).toBe(0);
    const config = read("config.toml");
    for (const args of [
      [
        "--domain",
        "relay.example.com\nmalicious",
        "--email",
        "ops@example.com",
      ],
      ["--domain", "127.0.0.1", "--email", "ops@example.com"],
      ["--domain", "relay.example.com", "--email", "bad\nemail"],
      [
        "--domain",
        "relay.example.com",
        "--email",
        "ops@example.com",
        "--https-port",
        "8443",
      ],
      ["--port", "0"],
      ["--port", "65536"],
      ["--bind", "invalid"],
      ["--domain", "relay.example.com", "--http"],
    ]) {
      expect(configure(args).status).not.toBe(0);
      expect(read("config.toml")).toBe(config);
    }
    writeFileSync(join(dir, "token"), "not-a-valid-token");
    const invalid = configure();
    expect(invalid.status).toBe(1);
    expect(invalid.stderr).not.toContain("not-a-valid-token");
    expect(read("config.toml")).toBe(config);
  });
});
