import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

type ConfigModule = typeof import("../src/config.js");

const tempHomes: string[] = [];

async function importConfigForHome(home: string): Promise<ConfigModule> {
  const oldHome = process.env.HOME;
  const oldToken = process.env.OPENVSMOBILE_TOKEN;
  process.env.HOME = home;
  delete process.env.OPENVSMOBILE_TOKEN;
  try {
    vi.resetModules();
    return (await import("../src/config.js")) as ConfigModule;
  } finally {
    if (oldHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = oldHome;
    }
    if (oldToken === undefined) {
      delete process.env.OPENVSMOBILE_TOKEN;
    } else {
      process.env.OPENVSMOBILE_TOKEN = oldToken;
    }
  }
}

function makeHome(): string {
  const home = mkdtempSync(join(tmpdir(), "openvsmobile-config-test-"));
  tempHomes.push(home);
  return home;
}

function configPath(home: string): string {
  return join(home, ".config", "openvsmobile-next", "config.json");
}

function writeConfig(home: string, config: unknown): void {
  const path = configPath(home);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
}

function readConfig(home: string): Record<string, unknown> {
  return JSON.parse(readFileSync(configPath(home), "utf8")) as Record<
    string,
    unknown
  >;
}

afterEach(() => {
  for (const home of tempHomes.splice(0)) {
    rmSync(home, { recursive: true, force: true });
  }
});

describe("config persistence", () => {
  it("preserves an existing Iroh secret when generating a missing token", async () => {
    const home = makeHome();
    writeConfig(home, { irohSecretKey: "secret-key" });
    const config = await importConfigForHome(home);

    const resolved = config.resolveToken();

    expect(resolved.source).toBe("generated");
    expect(resolved.token).toHaveLength(48);
    expect(readConfig(home)).toMatchObject({
      token: resolved.token,
      irohSecretKey: "secret-key",
    });
  });

  it("preserves an existing token when saving an Iroh secret", async () => {
    const home = makeHome();
    writeConfig(home, { token: "auth-token" });
    const config = await importConfigForHome(home);

    config.saveIrohSecretKey("secret-key");

    expect(readConfig(home)).toMatchObject({
      token: "auth-token",
      irohSecretKey: "secret-key",
    });
  });
});
