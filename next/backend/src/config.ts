// Token and recents persistence. Config dir is
// ~/.config/openvsmobile-next/ with two files:
//   - config.json: { token: string }
//   - state.json:  { recents: string[] }
// Anything missing/corrupt is re-initialized.

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

const CONFIG_DIR = join(homedir(), ".config", "openvsmobile-next");
const CONFIG_FILE = join(CONFIG_DIR, "config.json");
const STATE_FILE = join(CONFIG_DIR, "state.json");
const RECENTS_CAP = 10;

function ensureDir(): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
}

function generateToken(): string {
  return randomBytes(24).toString("hex");
}

export interface ResolvedToken {
  token: string;
  source: "env" | "config" | "generated";
}

export function resolveToken(): ResolvedToken {
  const fromEnv = process.env.OPENVSMOBILE_TOKEN;
  if (fromEnv && fromEnv.trim().length > 0) {
    return { token: fromEnv.trim(), source: "env" };
  }
  ensureDir();
  if (existsSync(CONFIG_FILE)) {
    try {
      const raw = readFileSync(CONFIG_FILE, "utf8");
      const parsed = JSON.parse(raw) as { token?: unknown };
      if (typeof parsed.token === "string" && parsed.token.length > 0) {
        return { token: parsed.token, source: "config" };
      }
    } catch {
      // fall through to regenerate
    }
  }
  const token = generateToken();
  writeFileSync(
    CONFIG_FILE,
    JSON.stringify({ token }, null, 2) + "\n",
    { mode: 0o600 },
  );
  return { token, source: "generated" };
}

export function loadRecents(): string[] {
  ensureDir();
  if (!existsSync(STATE_FILE)) return [];
  try {
    const raw = readFileSync(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw) as { recents?: unknown };
    if (!Array.isArray(parsed.recents)) return [];
    const out: string[] = [];
    for (const item of parsed.recents) {
      if (typeof item === "string" && item.length > 0) out.push(item);
    }
    return out.slice(0, RECENTS_CAP);
  } catch {
    return [];
  }
}

export function saveRecents(recents: string[]): void {
  ensureDir();
  const trimmed = recents.slice(0, RECENTS_CAP);
  writeFileSync(
    STATE_FILE,
    JSON.stringify({ recents: trimmed }, null, 2) + "\n",
    { mode: 0o600 },
  );
}

export function pushRecent(recents: string[], path: string): string[] {
  const filtered = recents.filter((p) => p !== path);
  filtered.unshift(path);
  return filtered.slice(0, RECENTS_CAP);
}
