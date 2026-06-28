import { describe, expect, it } from "vitest";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = join(HERE, "..");
const INSTALLER = join(BACKEND_DIR, "bin", "install-agent-hooks.mjs");
const HOOK_NOTIFY = join(BACKEND_DIR, "bin", "openvsmobile-agent-hook-notify.mjs");

function withTmpHome<T>(fn: (home: string) => T): T {
  const home = mkdtempSync(join(tmpdir(), "ovsm-agent-hooks-"));
  try {
    return fn(home);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

function runInstaller(home: string) {
  return spawnSync(process.execPath, [INSTALLER], {
    env: {
      ...process.env,
      OPENVSMOBILE_AGENT_HOOK_HOME: home,
    },
    encoding: "utf8",
  });
}

describe("install-agent-hooks", () => {
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
        "--from-claude-hook",
        "--source",
        "codex",
        "--title",
        "Codex finished",
        "--quiet",
        "--group-key",
        "codex:codex-session",
      ]);
      expect(JSON.parse(record.stdin).cwd).toBe("/tmp/repo");
    });
  });
});
