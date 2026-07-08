#!/usr/bin/env node
// Install openvsmobile Stop hooks into local Claude Code and Codex configs.
//
// This is intentionally best-effort. The backend install must succeed even
// if an agent config file is absent, malformed, or owned by another tool.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLE_ROOT = dirname(HERE);
const VERSION = "1.0.0";
const MARKETPLACE = "openvsmobile-local";
const PLUGIN = "openvsmobile-notify";
const PLUGIN_ID = `${PLUGIN}@${MARKETPLACE}`;
const HOOK_SCRIPT = "openvsmobile-agent-hook-notify.mjs";

function log(line) {
  process.stderr.write(`[agent-hooks] ${line}\n`);
}

function parseArgs(argv) {
  return {
    check: argv.includes("--check"),
    json: argv.includes("--json"),
  };
}

function status(agent, state, message, { available = true, changed = false } = {}) {
  return { agent, state, message, available, changed };
}

function shellQuote(value) {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function atomicWrite(path, content, mode) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, content, { mode });
  renameSync(tmp, path);
}

function atomicWriteIfChanged(path, content, mode) {
  if (existsSync(path) && readText(path) === content) return false;
  atomicWrite(path, content, mode);
  return true;
}

function readText(path) {
  return readFileSync(path, "utf8");
}

function modeOf(path, fallback) {
  try {
    return statSync(path).mode & 0o777;
  } catch {
    return fallback;
  }
}

function hookCommand(agent) {
  const nodePath = join(BUNDLE_ROOT, "node", "bin", "node");
  const nodeBin = existsSync(nodePath) ? nodePath : process.execPath;
  const hookPath = join(HERE, HOOK_SCRIPT);
  return `${shellQuote(nodeBin)} ${shellQuote(hookPath)} --agent ${shellQuote(agent)}`;
}

function containsOpenvsmobileHook(value) {
  return JSON.stringify(value).includes(HOOK_SCRIPT);
}

function rewriteOpenvsmobileHookCommands(value, command) {
  let changed = false;
  const visit = (node) => {
    if (Array.isArray(node)) {
      for (const item of node) visit(item);
      return;
    }
    if (!node || typeof node !== "object") return;
    if (
      typeof node.command === "string" &&
      node.command.includes(HOOK_SCRIPT)
    ) {
      if (node.command !== command) {
        node.command = command;
        changed = true;
      }
    }
    for (const child of Object.values(node)) visit(child);
  };
  visit(value);
  return changed;
}

function ensureClaudeSettings(home, { check = false } = {}) {
  const claudeDir = join(home, ".claude");
  const settingsPath = join(claudeDir, "settings.json");
  if (!existsSync(claudeDir) && !existsSync(settingsPath)) {
    const message = "Claude Code config not found; skipping";
    log(message);
    return status("claude-code", "missing", message, { available: false });
  }

  let settings = {};
  if (existsSync(settingsPath)) {
    try {
      settings = JSON.parse(readText(settingsPath));
    } catch (err) {
      const message =
        `Claude Code settings are not valid JSON; skipping (${err.message})`;
      log(message);
      return status("claude-code", "error", message);
    }
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
      const message = "Claude Code settings root is not an object; skipping";
      log(message);
      return status("claude-code", "error", message);
    }
  }

  const hooks = settings.hooks ?? {};
  if (!hooks || typeof hooks !== "object" || Array.isArray(hooks)) {
    const message = "Claude Code settings hooks field is not an object; skipping";
    log(message);
    return status("claude-code", "error", message);
  }
  const stop = hooks.Stop ?? [];
  if (!Array.isArray(stop)) {
    const message = "Claude Code Stop hooks field is not an array; skipping";
    log(message);
    return status("claude-code", "error", message);
  }

  const command = hookCommand("claude-code");
  let found = false;
  let changed = false;
  let stale = false;
  for (const entry of stop) {
    if (!containsOpenvsmobileHook(entry)) continue;
    found = true;
    if (check && !JSON.stringify(entry).includes(command)) stale = true;
    if (check) continue;
    changed = rewriteOpenvsmobileHookCommands(entry, command) || changed;
  }

  if (check) {
    if (!found) {
      const message = "Claude Code Stop hook is not installed";
      log(message);
      return status("claude-code", "not-installed", message);
    }
    if (stale) {
      const message = "Claude Code Stop hook needs an update";
      log(message);
      return status("claude-code", "stale", message);
    }
    const message = "Claude Code Stop hook already current";
    log(message);
    return status("claude-code", "current", message);
  }

  if (!found) {
    stop.push({
      hooks: [{ type: "command", command }],
    });
    changed = true;
  }
  hooks.Stop = stop;
  settings.hooks = hooks;

  if (!changed) {
    const message = "Claude Code Stop hook already current";
    log(message);
    return status("claude-code", "current", message);
  }
  if (existsSync(settingsPath)) {
    const backupPath = `${settingsPath}.bak.openvsmobile`;
    if (!existsSync(backupPath)) copyFileSync(settingsPath, backupPath);
  }
  atomicWrite(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, modeOf(settingsPath, 0o600));
  const message = found
    ? `updated Claude Code Stop hook in ${settingsPath}`
    : `installed Claude Code Stop hook in ${settingsPath}`;
  log(message);
  return status("claude-code", found ? "updated" : "installed", message, {
    changed: true,
  });
}

function pluginFiles(command) {
  const hooksJson = {
    description: "openvsmobile Stop notifications",
    hooks: {
      Stop: [
        {
          hooks: [{ type: "command", command }],
        },
      ],
    },
  };
  const pluginJson = {
    name: PLUGIN,
    description: "Post an openvsmobile notification when Codex stops",
    version: VERSION,
    author: { name: "openvsmobile" },
  };
  return { hooksJson, pluginJson };
}

function writePluginRoot(pluginRoot, command) {
  const { hooksJson, pluginJson } = pluginFiles(command);
  mkdirSync(join(pluginRoot, ".claude-plugin"), { recursive: true });
  mkdirSync(join(pluginRoot, "hooks"), { recursive: true });
  const pluginChanged = atomicWriteIfChanged(
    join(pluginRoot, ".claude-plugin", "plugin.json"),
    `${JSON.stringify(pluginJson, null, 2)}\n`,
    0o644,
  );
  const hooksChanged = atomicWriteIfChanged(
    join(pluginRoot, "hooks", "hooks.json"),
    `${JSON.stringify(hooksJson, null, 2)}\n`,
    0o644,
  );
  return pluginChanged || hooksChanged;
}

function pluginRootCurrent(pluginRoot, command) {
  const { hooksJson, pluginJson } = pluginFiles(command);
  const pluginPath = join(pluginRoot, ".claude-plugin", "plugin.json");
  const hooksPath = join(pluginRoot, "hooks", "hooks.json");
  return (
    existsSync(pluginPath) &&
    existsSync(hooksPath) &&
    readText(pluginPath) === `${JSON.stringify(pluginJson, null, 2)}\n` &&
    readText(hooksPath) === `${JSON.stringify(hooksJson, null, 2)}\n`
  );
}

function writeCodexMarketplacePlugin(root, command) {
  return writePluginRoot(join(root, "plugins", PLUGIN), command);
}

function writeCodexCachePlugin(root, command) {
  return writePluginRoot(join(root, MARKETPLACE, PLUGIN, VERSION), command);
}

function ensureTomlTable(text, tableName, desiredLines) {
  const header = `[${tableName}]`;
  const lines = text.split(/\n/);
  const start = lines.findIndex((line) => line.trim() === header);
  if (start === -1) {
    const prefix = text.trimEnd();
    return `${prefix}${prefix.length > 0 ? "\n\n" : ""}${header}\n${desiredLines.join("\n")}\n`;
  }

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i])) {
      end = i;
      break;
    }
  }

  const block = lines.slice(start + 1, end);
  const nextBlock = [...block];
  for (const desired of desiredLines) {
    const key = desired.split("=", 1)[0].trim();
    const idx = nextBlock.findIndex((line) =>
      line.trimStart().startsWith(`${key} `) ||
      line.trimStart().startsWith(`${key}=`),
    );
    if (idx >= 0) nextBlock[idx] = desired;
    else nextBlock.push(desired);
  }
  const nextLines = [
    ...lines.slice(0, start + 1),
    ...nextBlock,
    ...lines.slice(end),
  ];
  return nextLines.join("\n").replace(/\n*$/, "\n");
}

function tomlString(value) {
  return JSON.stringify(value);
}

function ensureCodexConfig(home, { check = false } = {}) {
  const codexDir = join(home, ".codex");
  const configPath = join(codexDir, "config.toml");
  if (!existsSync(codexDir) && !existsSync(configPath)) {
    const message = "Codex config not found; skipping";
    log(message);
    return status("codex", "missing", message, { available: false });
  }

  const command = hookCommand("codex");
  const marketplaceRoot = join(codexDir, ".tmp", "marketplaces", MARKETPLACE);
  if (check) {
    let text = existsSync(configPath) ? readText(configPath) : "";
    let expected = ensureTomlTable(text, `marketplaces.${MARKETPLACE}`, [
      `last_updated = ${tomlString(new Date(0).toISOString())}`,
      `source_type = "local"`,
      `source = ${tomlString(marketplaceRoot)}`,
    ]);
    expected = ensureTomlTable(expected, `plugins."${PLUGIN_ID}"`, [
      `enabled = true`,
    ]);
    if (expected !== text) {
      const message = "Codex Stop hook plugin is not enabled";
      log(message);
      return status("codex", "not-installed", message);
    }
    const marketplaceCurrent = pluginRootCurrent(
      join(marketplaceRoot, "plugins", PLUGIN),
      command,
    );
    const cacheCurrent = pluginRootCurrent(
      join(codexDir, "plugins", "cache", MARKETPLACE, PLUGIN, VERSION),
      command,
    );
    if (!marketplaceCurrent || !cacheCurrent) {
      const message = "Codex Stop hook plugin files need an update";
      log(message);
      return status("codex", "stale", message);
    }
    const message = "Codex Stop hook plugin already current";
    log(message);
    return status("codex", "current", message);
  }

  const marketplacePluginChanged = writeCodexMarketplacePlugin(
    marketplaceRoot,
    command,
  );
  const cachePluginChanged = writeCodexCachePlugin(
    join(codexDir, "plugins", "cache"),
    command,
  );
  const pluginChanged = marketplacePluginChanged || cachePluginChanged;

  let text = existsSync(configPath) ? readText(configPath) : "";
  const before = text;
  text = ensureTomlTable(text, `marketplaces.${MARKETPLACE}`, [
    `last_updated = ${tomlString(new Date(0).toISOString())}`,
    `source_type = "local"`,
    `source = ${tomlString(marketplaceRoot)}`,
  ]);
  text = ensureTomlTable(text, `plugins."${PLUGIN_ID}"`, [`enabled = true`]);

  if (text !== before) {
    if (existsSync(configPath)) {
      const backupPath = `${configPath}.bak.openvsmobile`;
      if (!existsSync(backupPath)) copyFileSync(configPath, backupPath);
    }
    atomicWrite(configPath, text, modeOf(configPath, 0o600));
    const message = `enabled Codex Stop hook plugin in ${configPath}`;
    log(message);
    return status("codex", "installed", message, { changed: true });
  }
  if (pluginChanged) {
    const message = "refreshed Codex Stop hook plugin files";
    log(message);
    return status("codex", "updated", message, { changed: true });
  }
  const message = "Codex Stop hook plugin already current";
  log(message);
  return status("codex", "current", message);
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const home = process.env.OPENVSMOBILE_AGENT_HOOK_HOME || homedir();
  const results = {
    claude: ensureClaudeSettings(home, { check: opts.check }),
    codex: ensureCodexConfig(home, { check: opts.check }),
  };
  const verb = opts.check ? "checked" : "done";
  log(`${verb} (changed: claude=${results.claude.changed}, codex=${results.codex.changed})`);
  if (opts.json) {
    process.stdout.write(`${JSON.stringify({ ok: true, results })}\n`);
  }
}

main();
