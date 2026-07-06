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
  const hookPath = join(HERE, HOOK_SCRIPT);
  return `${shellQuote(nodePath)} ${shellQuote(hookPath)} --agent ${shellQuote(agent)}`;
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

function ensureClaudeSettings(home) {
  const claudeDir = join(home, ".claude");
  const settingsPath = join(claudeDir, "settings.json");
  if (!existsSync(claudeDir) && !existsSync(settingsPath)) {
    log("Claude Code config not found; skipping");
    return false;
  }

  let settings = {};
  if (existsSync(settingsPath)) {
    try {
      settings = JSON.parse(readText(settingsPath));
    } catch (err) {
      log(`Claude Code settings are not valid JSON; skipping (${err.message})`);
      return false;
    }
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
      log("Claude Code settings root is not an object; skipping");
      return false;
    }
  }

  const hooks = settings.hooks ?? {};
  if (!hooks || typeof hooks !== "object" || Array.isArray(hooks)) {
    log("Claude Code settings hooks field is not an object; skipping");
    return false;
  }
  const stop = hooks.Stop ?? [];
  if (!Array.isArray(stop)) {
    log("Claude Code Stop hooks field is not an array; skipping");
    return false;
  }

  const command = hookCommand("claude-code");
  let found = false;
  let changed = false;
  for (const entry of stop) {
    if (!containsOpenvsmobileHook(entry)) continue;
    found = true;
    changed = rewriteOpenvsmobileHookCommands(entry, command) || changed;
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
    log("Claude Code Stop hook already current");
    return false;
  }
  if (existsSync(settingsPath)) {
    const backupPath = `${settingsPath}.bak.openvsmobile`;
    if (!existsSync(backupPath)) copyFileSync(settingsPath, backupPath);
  }
  atomicWrite(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, modeOf(settingsPath, 0o600));
  log(
    found
      ? `updated Claude Code Stop hook in ${settingsPath}`
      : `installed Claude Code Stop hook in ${settingsPath}`,
  );
  return true;
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

function ensureCodexConfig(home) {
  const codexDir = join(home, ".codex");
  const configPath = join(codexDir, "config.toml");
  if (!existsSync(codexDir) && !existsSync(configPath)) {
    log("Codex config not found; skipping");
    return false;
  }

  const command = hookCommand("codex");
  const marketplaceRoot = join(codexDir, ".tmp", "marketplaces", MARKETPLACE);
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
    log(`enabled Codex Stop hook plugin in ${configPath}`);
    return true;
  }
  if (pluginChanged) {
    log("refreshed Codex Stop hook plugin files");
    return true;
  }
  log("Codex Stop hook plugin already current");
  return false;
}

function main() {
  const home = process.env.OPENVSMOBILE_AGENT_HOOK_HOME || homedir();
  const changed = {
    claude: ensureClaudeSettings(home),
    codex: ensureCodexConfig(home),
  };
  log(`done (changed: claude=${changed.claude}, codex=${changed.codex})`);
}

main();
