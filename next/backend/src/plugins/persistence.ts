// Disabled-plugin persistence. The host loads the set on boot so a user's
// `plugin.disable` survives a backend restart; it writes back synchronously
// after every change. The format is intentionally trivial — `{ disabled:
// string[] }` — so a human can hand-edit the file if needed and so a future
// schema bump can detect "this is v0" without a version field.
//
// Path: `~/.local/state/openvsmobile-next/plugin-state.json`, overridable via
// `OPENVSMOBILE_PLUGIN_STATE_FILE` so tests don't touch the user's real state.

import {
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const DEFAULT_STATE_FILE_REL = [
  ".local",
  "state",
  "openvsmobile-next",
  "plugin-state.json",
];

export interface PluginStateFile {
  disabled: string[];
}

export function resolveDefaultStateFile(): string {
  const override = process.env.OPENVSMOBILE_PLUGIN_STATE_FILE;
  if (override !== undefined && override.length > 0) return override;
  return join(homedir(), ...DEFAULT_STATE_FILE_REL);
}

/// Read the disabled-set from disk. Missing file, parse errors, or wrong
/// shape are all treated as "no plugins disabled". The host logs the parse
/// failure but doesn't refuse to boot — the user's plugins should keep
/// working past a corrupted state file.
export function loadPluginState(
  path: string,
  logger: (line: string) => void,
): Set<string> {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      logger(`[plugins] cannot read state file ${path}: ${(err as Error).message}`);
    }
    return new Set();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    logger(`[plugins] state file ${path} is not valid JSON: ${(err as Error).message}`);
    return new Set();
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    logger(`[plugins] state file ${path} is not an object; ignoring`);
    return new Set();
  }
  const disabled = (parsed as Record<string, unknown>).disabled;
  if (!Array.isArray(disabled)) return new Set();
  const out = new Set<string>();
  for (const item of disabled) {
    if (typeof item === "string" && item.length > 0) out.add(item);
  }
  return out;
}

/// Atomically rewrite the state file. We mkdir -p the parent and write
/// through a `.tmp` neighbour + rename — same belt-and-braces pattern the
/// runtime-info file uses so a crashed write never leaves a half-written
/// file behind.
export function savePluginState(path: string, disabled: Set<string>): void {
  mkdirSync(dirname(path), { recursive: true });
  const body: PluginStateFile = { disabled: [...disabled].sort() };
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(body, null, 2), { mode: 0o600 });
  // `renameSync` is atomic on POSIX filesystems.
  renameSync(tmp, path);
}
