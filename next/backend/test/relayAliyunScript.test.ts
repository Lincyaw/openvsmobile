import { afterEach, beforeEach, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const SCRIPT = resolve("pkg/relay-aliyun.py");
let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ovsm-aliyun-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});
function setup(args: string[] = []) {
  return spawnSync(
    "python3",
    [SCRIPT, "--dir", join(dir, "state"), "--configure-only", ...args],
    { encoding: "utf8" },
  );
}
it("prepares private Aliyun credentials and a custom-port certificate plan without contacting DNS", () => {
  const credentials = join(dir, "aliyun.env");
  writeFileSync(credentials, "Ali_Key=testKey\nAli_Secret=testSecret\n", {
    mode: 0o600,
  });
  const configured = setup([
    "--domain",
    "relay.example.com",
    "--email",
    "ops@example.com",
    "--credentials",
    credentials,
  ]);
  expect(configured.status, configured.stderr).toBe(0);
  expect(configured.stdout).toContain("no DNS changes");
  expect(configured.stdout + configured.stderr).not.toContain("testSecret");
  const state = join(dir, "state");
  const plan = readFileSync(join(state, "plan.json"), "utf8");
  expect(plan).not.toContain("testSecret");
  expect(JSON.parse(plan).relayCommand).toEqual(
    expect.arrayContaining([
      "relay.example.com",
      "8443",
      "9842",
      "--tls-cert",
      "--tls-key",
    ]),
  );
  for (const file of ["aliyun.env", "dns-settings.json", "plan.json"])
    expect(statSync(join(state, file)).mode & 0o777).toBe(0o600);
  expect(setup().status).toBe(0);
  expect(readFileSync(join(state, "plan.json"), "utf8")).toBe(plan);
  expect(setup(["--https-port", "65536"]).status).not.toBe(0);
  expect(readFileSync(join(state, "plan.json"), "utf8")).toBe(plan);
});
it("rejects public, missing or malformed credentials without echoing their contents", () => {
  const credentials = join(dir, "aliyun.env");
  writeFileSync(credentials, "Ali_Key=testKey\nAli_Secret=testSecret\n", {
    mode: 0o644,
  });
  const args = [
    "--domain",
    "relay.example.com",
    "--email",
    "ops@example.com",
    "--credentials",
    credentials,
  ];
  expect(setup(args).status).not.toBe(0);
  chmodSync(credentials, 0o600);
  writeFileSync(
    credentials,
    "Ali_Key=testKey\nAli_Secret=$(maliciousSecret)\n",
  );
  const invalid = setup(args);
  expect(invalid.status).toBe(1);
  expect(invalid.stderr).not.toContain("maliciousSecret");
});
