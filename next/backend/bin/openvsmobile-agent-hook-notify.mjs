#!/usr/bin/env node
// Hook bridge for Claude Code / Codex Stop events.
//
// Hook commands receive the agent's JSON envelope on stdin. This wrapper
// keeps the hook cheap and non-fatal: it forwards the envelope to
// mobile-notify's existing agent-hook translator, but exits 0 even if the
// notification backend is unavailable. Agent work should never fail because
// the user's phone notification could not be posted.

import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_MOBILE_NOTIFY = join(HERE, "mobile-notify.mjs");

function parseArgs(argv) {
  let agent = "agent";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--agent" && i + 1 < argv.length) {
      agent = argv[++i];
      continue;
    }
    if (arg.startsWith("--agent=")) {
      agent = arg.slice("--agent=".length);
    }
  }
  return { agent };
}

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => {
      resolve(Buffer.concat(chunks).toString("utf8"));
    });
    process.stdin.on("error", reject);
  });
}

function sourceFor(agent) {
  switch (agent) {
    case "codex":
      return "codex";
    case "claude-code":
      return "claude-code";
    default:
      return "agent";
  }
}

function sessionIdFor(event) {
  return event && typeof event === "object" && typeof event.session_id === "string"
    ? event.session_id
    : undefined;
}

async function main() {
  const { agent } = parseArgs(process.argv.slice(2));
  const input = await readStdin();
  let parsed;
  try {
    parsed = JSON.parse(input);
    if (
      parsed &&
      typeof parsed === "object" &&
      parsed.hook_event_name === "Stop" &&
      parsed.stop_hook_active === true
    ) {
      return;
    }
  } catch {
    // If the hook envelope is malformed, let mobile-notify report it. In
    // non-strict mode we still swallow the failure below.
  }

  const mobileNotify =
    process.env.OPENVSMOBILE_HOOK_MOBILE_NOTIFY ?? DEFAULT_MOBILE_NOTIFY;
  const source = sourceFor(agent);
  const args = [
    mobileNotify,
    "--from-agent-hook",
    "--source",
    source,
    "--quiet",
  ];
  const sessionId = sessionIdFor(parsed);
  if (sessionId !== undefined) {
    args.push("--group-key", `${source}:${sessionId}`);
  }
  const child = spawn(
    process.execPath,
    args,
    { stdio: ["pipe", "ignore", "ignore"] },
  );
  child.stdin.end(input);
  const code = await new Promise((resolve) => {
    child.on("error", () => resolve(1));
    child.on("close", (status) => resolve(status ?? 1));
  });
  if (process.env.OPENVSMOBILE_HOOK_NOTIFY_STRICT === "1" && code !== 0) {
    process.exit(code);
  }
}

main().catch((err) => {
  if (process.env.OPENVSMOBILE_HOOK_NOTIFY_STRICT === "1") {
    process.stderr.write(
      `openvsmobile-agent-hook-notify: ${err?.stack ?? err}\n`,
    );
    process.exit(1);
  }
});
