// Runtime info file: written atomically on successful listen, unlinked on
// shutdown. This is the disclosure channel for the bound port + token so
// that the install.sh wrapper (and an SSH bootstrap) can emit a single
// JSON line to its caller after `systemctl --user start openvsmobile`.
//
// Location:
//   $OPENVSMOBILE_RUNTIME_INFO_PATH       (if set)
//   ~/.local/state/openvsmobile-next/runtime.json   (otherwise)
//
// Mode 0600 — file is the only place the auto-generated token reaches disk
// in a form the local user can read directly.

import {
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface RuntimeInfo {
  schema: 1;
  pid: number;
  port: number;
  token: string;
  startedAt: string;
  version: string;
  iroh?: {
    endpointId: string;
    ticket: string;
    alpn: string;
    relayUrl: string | null;
    directAddresses: string[];
  };
}

export function runtimeInfoPath(): string {
  const override = process.env.OPENVSMOBILE_RUNTIME_INFO_PATH;
  if (override && override.length > 0) return override;
  return join(homedir(), ".local", "state", "openvsmobile-next", "runtime.json");
}

export function writeRuntimeInfo(info: RuntimeInfo): string {
  const path = runtimeInfoPath();
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp.${process.pid}`;
  // mode 0600 on the temp file so we never have a window where another
  // user could read the token between write and rename.
  writeFileSync(tmp, JSON.stringify(info, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
  return path;
}

export function unlinkRuntimeInfo(): void {
  const path = runtimeInfoPath();
  // Only unlink if the file we'd delete is OURS. Two backends pointed at
  // the same OPENVSMOBILE_RUNTIME_INFO_PATH (e.g. a dev tsx process and a
  // systemd unit started in parallel by mistake) would otherwise have the
  // second one to exit delete the survivor's disclosure file. Read the
  // pid out and compare; bail on any read/parse error.
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    // Already gone, never written, or unreadable. Nothing to do.
    return;
  }
  let parsedPid: unknown;
  try {
    parsedPid = (JSON.parse(raw) as { pid?: unknown }).pid;
  } catch {
    // Corrupt file — leave it alone; whoever wrote it can clean up.
    return;
  }
  if (parsedPid !== process.pid) {
    // Not ours. Another process owns this disclosure file.
    return;
  }
  try {
    unlinkSync(path);
  } catch {
    // Best-effort: file vanished between read and unlink. Shutdown
    // continues regardless.
  }
}
