import { describe, expect, it } from "vitest";
import {
  mkdirSync,
  mkdtempSync,
  existsSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { getAgentHookStatus, installAgentHooks } from "../src/agentHooks.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = join(HERE, "..");
const INSTALLER = join(BACKEND_DIR, "bin", "install-agent-hooks.mjs");
const HOOK_NOTIFY = join(BACKEND_DIR, "bin", "openvsmobile-agent-hook-notify.mjs");
const MOBILE_NOTIFY = join(BACKEND_DIR, "bin", "mobile-notify.mjs");

function withTmpHome<T>(fn: (home: string) => T): T {
  const home = mkdtempSync(join(tmpdir(), "ovsm-agent-hooks-"));
  try {
    return fn(home);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

function runInstaller(home: string, args: string[] = []) {
  return spawnSync(process.execPath, [INSTALLER, ...args], {
    env: {
      ...process.env,
      OPENVSMOBILE_AGENT_HOOK_HOME: home,
    },
    encoding: "utf8",
  });
}

describe("install-agent-hooks", () => {
  it("emits structured JSON for the Settings surface", () => {
    withTmpHome((home) => {
      const settingsPath = join(home, ".claude", "settings.json");
      const codexConfigPath = join(home, ".codex", "config.toml");
      mkdirSync(dirname(settingsPath), { recursive: true });
      mkdirSync(dirname(codexConfigPath), { recursive: true });
      writeFileSync(settingsPath, JSON.stringify({ hooks: {} }, null, 2), {
        mode: 0o600,
      });
      writeFileSync(codexConfigPath, 'model = "gpt-5.5"\n', { mode: 0o600 });

      const res = spawnSync(process.execPath, [INSTALLER, "--json"], {
        env: {
          ...process.env,
          OPENVSMOBILE_AGENT_HOOK_HOME: home,
        },
        encoding: "utf8",
      });
      expect(res.status).toBe(0);
      const payload = JSON.parse(res.stdout) as {
        ok: boolean;
        results: {
          claude: { agent: string; changed: boolean; state: string };
          codex: { agent: string; changed: boolean; state: string };
        };
      };
      expect(payload.ok).toBe(true);
      expect(payload.results.claude.agent).toBe("claude-code");
      expect(payload.results.claude.changed).toBe(true);
      expect(payload.results.claude.state).toBe("installed");
      expect(payload.results.codex.agent).toBe("codex");
      expect(payload.results.codex.changed).toBe(true);
      expect(payload.results.codex.state).toBe("installed");
    });
  });

  it("checks hook status without writing agent config", () => {
    withTmpHome((home) => {
      const settingsPath = join(home, ".claude", "settings.json");
      const codexConfigPath = join(home, ".codex", "config.toml");
      mkdirSync(dirname(settingsPath), { recursive: true });
      mkdirSync(dirname(codexConfigPath), { recursive: true });
      writeFileSync(settingsPath, JSON.stringify({ hooks: {} }, null, 2), {
        mode: 0o600,
      });
      writeFileSync(codexConfigPath, 'model = "gpt-5.5"\n', { mode: 0o600 });

      const res = runInstaller(home, ["--json", "--check"]);
      expect(res.status).toBe(0);
      const payload = JSON.parse(res.stdout) as {
        ok: boolean;
        results: {
          claude: { state: string; changed: boolean };
          codex: { state: string; changed: boolean };
        };
      };
      expect(payload.ok).toBe(true);
      expect(payload.results.claude.state).toBe("not-installed");
      expect(payload.results.codex.state).toBe("not-installed");
      expect(payload.results.claude.changed).toBe(false);
      expect(payload.results.codex.changed).toBe(false);
      expect(readFileSync(settingsPath, "utf8")).toBe(
        JSON.stringify({ hooks: {} }, null, 2),
      );
      expect(readFileSync(codexConfigPath, "utf8")).toBe('model = "gpt-5.5"\n');
    });
  });

  it("agent hook runner parses installer statuses", async () => {
    const home = mkdtempSync(join(tmpdir(), "ovsm-agent-hooks-runner-"));
    try {
      const settingsPath = join(home, ".claude", "settings.json");
      mkdirSync(dirname(settingsPath), { recursive: true });
      writeFileSync(settingsPath, JSON.stringify({ hooks: {} }, null, 2), {
        mode: 0o600,
      });
      const result = await installAgentHooks({
        backendRoot: BACKEND_DIR,
        env: {
          ...process.env,
          OPENVSMOBILE_AGENT_HOOK_HOME: home,
        },
      });
      expect(result.ok).toBe(true);
      expect(result.statuses.map((s) => s.agent)).toContain("claude-code");
      expect(result.statuses.find((s) => s.agent === "claude-code")?.changed)
        .toBe(true);
      expect(result.statuses.find((s) => s.agent === "codex")?.available)
        .toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("agent hook status runner uses the read-only check path", async () => {
    const home = mkdtempSync(join(tmpdir(), "ovsm-agent-hooks-status-"));
    try {
      const settingsPath = join(home, ".claude", "settings.json");
      mkdirSync(dirname(settingsPath), { recursive: true });
      writeFileSync(settingsPath, JSON.stringify({ hooks: {} }, null, 2), {
        mode: 0o600,
      });
      const result = await getAgentHookStatus({
        backendRoot: BACKEND_DIR,
        env: {
          ...process.env,
          OPENVSMOBILE_AGENT_HOOK_HOME: home,
        },
      });
      expect(result.ok).toBe(true);
      expect(result.statuses.find((s) => s.agent === "claude-code")?.state)
        .toBe("not-installed");
      expect(result.statuses.find((s) => s.agent === "claude-code")?.changed)
        .toBe(false);
      expect(readFileSync(settingsPath, "utf8")).toBe(
        JSON.stringify({ hooks: {} }, null, 2),
      );
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("appends a Claude Code Stop hook without removing existing hooks", () => {
    withTmpHome((home) => {
      const settingsPath = join(home, ".claude", "settings.json");
      mkdirSync(dirname(settingsPath), { recursive: true });
      writeFileSync(
        settingsPath,
        JSON.stringify(
          {
            env: { EXISTING: "1" },
            hooks: {
              Stop: [{ hooks: [{ type: "command", command: "echo existing" }] }],
            },
          },
          null,
          2,
        ),
        { mode: 0o600 },
      );

      const first = runInstaller(home);
      expect(first.status).toBe(0);
      const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(settings.env.EXISTING).toBe("1");
      expect(settings.hooks.Stop).toHaveLength(2);
      expect(settings.hooks.Stop[0].hooks[0].command).toBe("echo existing");
      expect(settings.hooks.Stop[1].hooks[0].command).toContain(
        "openvsmobile-agent-hook-notify.mjs",
      );
      expect(settings.hooks.Stop[1].hooks[0].command).toContain("claude-code");
      expect(statSync(`${settingsPath}.bak.openvsmobile`).mode & 0o777).toBe(0o600);

      const second = runInstaller(home);
      expect(second.status).toBe(0);
      const after = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(after.hooks.Stop).toHaveLength(2);
    });
  });

  it("writes an executable Node binary for the current backend layout", () => {
    withTmpHome((home) => {
      const settingsPath = join(home, ".claude", "settings.json");
      const codexDir = join(home, ".codex");
      const codexConfigPath = join(codexDir, "config.toml");
      mkdirSync(dirname(settingsPath), { recursive: true });
      mkdirSync(codexDir, { recursive: true });
      writeFileSync(settingsPath, JSON.stringify({ hooks: {} }, null, 2), {
        mode: 0o600,
      });
      writeFileSync(codexConfigPath, 'model = "gpt-5.5"\n', { mode: 0o600 });

      const bundledNode = join(BACKEND_DIR, "node", "bin", "node");
      const expectedNode = existsSync(bundledNode)
        ? bundledNode
        : process.execPath;

      const first = runInstaller(home);
      expect(first.status).toBe(0);

      const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      const claudeCommand = settings.hooks.Stop[0].hooks[0].command as string;
      expect(claudeCommand).toContain(expectedNode);
      expect(claudeCommand).toContain("openvsmobile-agent-hook-notify.mjs");

      const codexHooksPath = join(
        codexDir,
        ".tmp",
        "marketplaces",
        "openvsmobile-local",
        "plugins",
        "openvsmobile-notify",
        "hooks",
        "hooks.json",
      );
      const codexHooks = JSON.parse(readFileSync(codexHooksPath, "utf8"));
      const codexCommand = codexHooks.hooks.Stop[0].hooks[0].command as string;
      expect(codexCommand).toContain(expectedNode);
      expect(codexCommand).toContain("openvsmobile-agent-hook-notify.mjs");
    });
  });

  it("updates an existing Claude Code Stop hook from an older bundle path", () => {
    withTmpHome((home) => {
      const settingsPath = join(home, ".claude", "settings.json");
      mkdirSync(dirname(settingsPath), { recursive: true });
      writeFileSync(
        settingsPath,
        JSON.stringify(
          {
            hooks: {
              Stop: [
                {
                  hooks: [
                    {
                      type: "command",
                      command:
                        "'/home/u/.local/share/openvsmobile/v0.4.0/openvsmobile-backend/node/bin/node' " +
                        "'/home/u/.local/share/openvsmobile/v0.4.0/openvsmobile-backend/bin/openvsmobile-agent-hook-notify.mjs' " +
                        "--agent 'claude-code'",
                    },
                  ],
                },
              ],
            },
          },
          null,
          2,
        ),
        { mode: 0o600 },
      );

      const first = runInstaller(home);
      expect(first.status).toBe(0);
      const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(settings.hooks.Stop).toHaveLength(1);
      const command = settings.hooks.Stop[0].hooks[0].command as string;
      expect(command).toContain("openvsmobile-agent-hook-notify.mjs");
      expect(command).toContain("claude-code");
      expect(command).not.toContain("v0.4.0");
      expect(command).toContain(BACKEND_DIR);

      const second = runInstaller(home);
      expect(second.status).toBe(0);
      const after = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(after.hooks.Stop).toHaveLength(1);
    });
  });

  it("creates and enables a local Codex Stop hook plugin", () => {
    withTmpHome((home) => {
      const codexDir = join(home, ".codex");
      const configPath = join(codexDir, "config.toml");
      mkdirSync(codexDir, { recursive: true });
      writeFileSync(configPath, 'model = "gpt-5.5"\n', { mode: 0o600 });

      const first = runInstaller(home);
      expect(first.status).toBe(0);
      const config = readFileSync(configPath, "utf8");
      expect(config).toContain("[marketplaces.openvsmobile-local]");
      expect(config).toContain('[plugins."openvsmobile-notify@openvsmobile-local"]');
      expect(config).toContain("enabled = true");

      const hookPath = join(
        codexDir,
        ".tmp",
        "marketplaces",
        "openvsmobile-local",
        "plugins",
        "openvsmobile-notify",
        "hooks",
        "hooks.json",
      );
      const hooks = JSON.parse(readFileSync(hookPath, "utf8"));
      expect(hooks.hooks.Stop[0].hooks[0].command).toContain(
        "openvsmobile-agent-hook-notify.mjs",
      );
      expect(hooks.hooks.Stop[0].hooks[0].command).toContain("codex");
      expect(
        readFileSync(
          join(
            codexDir,
            "plugins",
            "cache",
            "openvsmobile-local",
            "openvsmobile-notify",
            "1.0.0",
            "hooks",
            "hooks.json",
          ),
          "utf8",
        ),
      ).toContain("openvsmobile-agent-hook-notify.mjs");

      const second = runInstaller(home);
      expect(second.status).toBe(0);
      const after = readFileSync(configPath, "utf8");
      expect(
        after.match(/\[plugins\."openvsmobile-notify@openvsmobile-local"\]/g),
      ).toHaveLength(1);
    });
  });

  it("refreshes Codex Stop hook plugin files from an older bundle path", () => {
    withTmpHome((home) => {
      const codexDir = join(home, ".codex");
      const configPath = join(codexDir, "config.toml");
      mkdirSync(codexDir, { recursive: true });
      writeFileSync(
        configPath,
        [
          "[marketplaces.openvsmobile-local]",
          `source = "${join(codexDir, ".tmp", "marketplaces", "openvsmobile-local")}"`,
          'source_type = "local"',
          'last_updated = "1970-01-01T00:00:00.000Z"',
          "",
          '[plugins."openvsmobile-notify@openvsmobile-local"]',
          "enabled = true",
          "",
        ].join("\n"),
        { mode: 0o600 },
      );
      const oldHooks = JSON.stringify(
        {
          hooks: {
            Stop: [
              {
                hooks: [
                  {
                    type: "command",
                    command:
                      "'/home/u/.local/share/openvsmobile/v0.4.3/openvsmobile-backend/node/bin/node' " +
                      "'/home/u/.local/share/openvsmobile/v0.4.3/openvsmobile-backend/bin/openvsmobile-agent-hook-notify.mjs' " +
                      "--agent 'codex'",
                  },
                ],
              },
            ],
          },
        },
        null,
        2,
      );
      const marketplaceHookPath = join(
        codexDir,
        ".tmp",
        "marketplaces",
        "openvsmobile-local",
        "plugins",
        "openvsmobile-notify",
        "hooks",
        "hooks.json",
      );
      const cacheHookPath = join(
        codexDir,
        "plugins",
        "cache",
        "openvsmobile-local",
        "openvsmobile-notify",
        "1.0.0",
        "hooks",
        "hooks.json",
      );
      mkdirSync(dirname(marketplaceHookPath), { recursive: true });
      mkdirSync(dirname(cacheHookPath), { recursive: true });
      writeFileSync(marketplaceHookPath, oldHooks);
      writeFileSync(cacheHookPath, oldHooks);

      const first = runInstaller(home);
      expect(first.status).toBe(0);
      for (const hookPath of [marketplaceHookPath, cacheHookPath]) {
        const hooks = JSON.parse(readFileSync(hookPath, "utf8"));
        const command = hooks.hooks.Stop[0].hooks[0].command as string;
        expect(command).toContain("openvsmobile-agent-hook-notify.mjs");
        expect(command).toContain("codex");
        expect(command).not.toContain("v0.4.3");
        expect(command).toContain(BACKEND_DIR);
      }
    });
  });

  it("skips active Stop-hook recursion without invoking mobile-notify", () => {
    withTmpHome((home) => {
      const fakeNotify = join(home, "mobile-notify.mjs");
      writeFileSync(fakeNotify, "#!/usr/bin/env node\nprocess.exit(42);\n");
      const input = JSON.stringify({
        hook_event_name: "Stop",
        stop_hook_active: true,
      });
      const res = spawnSync(process.execPath, [HOOK_NOTIFY, "--agent", "codex"], {
        input,
        env: {
          ...process.env,
          OPENVSMOBILE_HOOK_MOBILE_NOTIFY: fakeNotify,
          OPENVSMOBILE_HOOK_NOTIFY_STRICT: "1",
        },
        encoding: "utf8",
      });
      expect(res.status).toBe(0);
    });
  });

  it("forwards Codex Stop hooks with Codex notification metadata", () => {
    withTmpHome((home) => {
      const fakeNotify = join(home, "mobile-notify.mjs");
      const recordPath = join(home, "record.json");
      writeFileSync(
        fakeNotify,
        [
          'import { writeFileSync } from "node:fs";',
          "const chunks = [];",
          'process.stdin.on("data", (chunk) => chunks.push(chunk));',
          'process.stdin.on("end", () => {',
          "  writeFileSync(process.env.RECORD_PATH, JSON.stringify({",
          "    argv: process.argv.slice(2),",
          "    stdin: Buffer.concat(chunks).toString('utf8'),",
          "  }, null, 2));",
          "});",
          "",
        ].join("\n"),
      );
      const input = JSON.stringify({
        hook_event_name: "Stop",
        session_id: "codex-session",
        cwd: "/tmp/repo",
      });
      const res = spawnSync(process.execPath, [HOOK_NOTIFY, "--agent", "codex"], {
        input,
        env: {
          ...process.env,
          OPENVSMOBILE_HOOK_MOBILE_NOTIFY: fakeNotify,
          OPENVSMOBILE_HOOK_NOTIFY_STRICT: "1",
          RECORD_PATH: recordPath,
        },
        encoding: "utf8",
      });
      expect(res.status).toBe(0);

      const record = JSON.parse(readFileSync(recordPath, "utf8")) as {
        argv: string[];
        stdin: string;
      };
      expect(record.argv).toEqual([
        "--from-agent-hook",
        "--source",
        "codex",
        "--quiet",
        "--group-key",
        "codex:codex-session",
      ]);
      expect(JSON.parse(record.stdin).cwd).toBe("/tmp/repo");
    });
  });

  it("mobile-notify accepts the generic agent hook flag", () => {
    const res = spawnSync(
      process.execPath,
      [
        MOBILE_NOTIFY,
        "--server",
        "127.0.0.1:1",
        "--token",
        "test-token",
        "--from-agent-hook",
      ],
      {
        input: "{",
        encoding: "utf8",
      },
    );
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("--from-agent-hook: invalid JSON on stdin");
    expect(res.stderr).not.toContain("Unknown option");
  });
});
