#!/usr/bin/env node
// mobile-notify — CLI for posting one notification to a running
// openvsmobile-next backend.
//
// Single self-contained ESM file. No external deps; uses node:util parseArgs
// and the built-in fetch. Bundled into the release tarball under bin/ by
// pkg/build-tarball.sh.
//
// Behavior:
//   * Args parsed with node:util parseArgs.
//   * Config resolution: explicit flags > env vars > config.json > error.
//   * HTTP POST /notify, Bearer token. 10-second timeout.
//   * Exit codes: 0 ok / 1 internal / 2 args / 3 network / 4 auth / 5 server error.
//
// Reference: docs/design/mobile-code-platform.md §4.5.

import { parseArgs } from "node:util";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const EXIT_OK = 0;
const EXIT_INTERNAL = 1;
const EXIT_ARGS = 2;
const EXIT_NETWORK = 3;
const EXIT_AUTH = 4;
const EXIT_SERVER = 5;
/// 403 — token is valid but its source-prefix doesn't permit this `source`.
/// Surface as a distinct code so callers (CI scripts, claude code hooks)
/// can tell a token-scope problem apart from an outright auth failure.
const EXIT_FORBIDDEN = 6;
/// 429 — per-publish-token rate limit exhausted. Distinguished from
/// EXIT_NETWORK so retry-with-backoff loops can recognize a server-side
/// throttle without re-running connectivity checks.
const EXIT_RATE_LIMITED = 7;

const REQUEST_TIMEOUT_MS = 10_000;
const VALID_LEVELS = new Set(["info", "success", "warning", "error"]);
const MANAGED_ZELLIJ_PREFIX = "ovsm-";

function die(code, message) {
  process.stderr.write(`mobile-notify: ${message}\n`);
  process.exit(code);
}

function readConfigFile() {
  const path = join(homedir(), ".config", "openvsmobile-next", "config.json");
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function readRuntimeInfo() {
  // The backend writes ~/.local/state/openvsmobile-next/runtime.json on
  // startup (mode 0600). Local invocations prefer it over config.json
  // because it carries the bound port (config.json only has the token).
  const override = process.env.OPENVSMOBILE_RUNTIME_INFO_PATH;
  const path =
    override && override.length > 0
      ? override
      : join(homedir(), ".local", "state", "openvsmobile-next", "runtime.json");
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function parseServerUrl(raw) {
  // Accept "host:port" or "http(s)://host:port". Reject bare host (port is
  // not optional — we don't guess).
  if (!raw || typeof raw !== "string") {
    die(EXIT_ARGS, "server must be host:port or http(s)://host:port");
  }
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    return raw.replace(/\/+$/, "");
  }
  if (!/^[^/:\s]+:\d+$/.test(raw)) {
    die(EXIT_ARGS, `invalid server: ${raw} (want host:port)`);
  }
  return `http://${raw}`;
}

function parseKv(raw, flag) {
  const eq = raw.indexOf("=");
  if (eq < 1 || eq === raw.length - 1) {
    die(EXIT_ARGS, `--${flag} expects key=value, got: ${raw}`);
  }
  return { key: raw.slice(0, eq), value: raw.slice(eq + 1) };
}

function parseAction(raw) {
  // Action grammar:
  //   "open-url:<url>" | "copy:<text>" | "open-workspace:<id>" |
  //   "open-terminal:<sessionId>"
  // The text after the kind is everything to the right of the FIRST colon —
  // copy: text may contain colons.
  const colon = raw.indexOf(":");
  if (colon < 1) {
    die(EXIT_ARGS, `--action: expected kind:value, got ${raw}`);
  }
  const kind = raw.slice(0, colon);
  const rest = raw.slice(colon + 1);
  if (kind === "open-url") return { kind: "open-url", url: rest };
  if (kind === "copy") return { kind: "copy", text: rest };
  if (kind === "open-workspace") return { kind: "open-workspace", workspaceId: rest };
  if (kind === "open-terminal") return { kind: "open-terminal", sessionId: rest };
  die(EXIT_ARGS, `--action kind must be open-url|copy|open-workspace|open-terminal, got: ${kind}`);
}

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", (err) => reject(err));
  });
}

function truncate(s, max) {
  if (typeof s !== "string") return s;
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function truncateUtf8(s, maxBytes) {
  if (typeof s !== "string") return s;
  if (Buffer.byteLength(s, "utf8") <= maxBytes) return s;
  const ellipsis = "…";
  const ellipsisBytes = Buffer.byteLength(ellipsis, "utf8");
  let out = "";
  let used = 0;
  for (const ch of s) {
    const n = Buffer.byteLength(ch, "utf8");
    if (used + n + ellipsisBytes > maxBytes) break;
    out += ch;
    used += n;
  }
  return out + ellipsis;
}

function firstNonEmptyLine(text) {
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length > 0) return trimmed;
  }
  return "";
}

function agentLabelForSource(source) {
  if (source === "codex") return "Codex";
  if (source === "claude-code") return "Claude";
  return "Agent";
}

function stopTitleForSource(source) {
  return `${agentLabelForSource(source)} finished`;
}

function stringField(obj, key) {
  if (!obj || typeof obj !== "object") return undefined;
  const value = obj[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function textFromContent(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    return value
      .map((item) => textFromContent(item))
      .filter((s) => s.trim().length > 0)
      .join("\n");
  }
  if (value && typeof value === "object") {
    if (typeof value.text === "string") return value.text;
    if (typeof value.message === "string") return value.message;
    if (value.content !== undefined) return textFromContent(value.content);
  }
  return "";
}

function assistantTextFromRecord(record) {
  if (!record || typeof record !== "object") return "";
  const role =
    record.role ??
    (record.message && typeof record.message === "object"
      ? record.message.role
      : undefined);
  const type = record.type;
  const isAssistant =
    role === "assistant" ||
    type === "assistant" ||
    type === "agent_message" ||
    type === "assistant_message";
  if (!isAssistant) return "";

  const candidates = [
    record.content,
    record.text,
    record.message,
    record.output,
    record.response,
  ];
  for (const candidate of candidates) {
    const text = textFromContent(candidate).trim();
    if (text.length > 0) return text;
  }
  return "";
}

function lastAssistantTextFromTranscript(path) {
  if (typeof path !== "string" || path.length === 0) return undefined;
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
  let last;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    let record;
    try {
      record = JSON.parse(trimmed);
    } catch {
      continue;
    }
    const text = assistantTextFromRecord(record).trim();
    if (text.length > 0) last = text;
  }
  return last;
}

function lastAgentMessageFromHook(event) {
  const direct =
    stringField(event, "last_message") ??
    stringField(event, "lastMessage") ??
    stringField(event, "final_message") ??
    stringField(event, "finalMessage") ??
    stringField(event, "assistant_message") ??
    stringField(event, "assistantMessage");
  if (direct !== undefined) return direct;
  return lastAssistantTextFromTranscript(
    stringField(event, "transcript_path") ??
      stringField(event, "transcriptPath"),
  );
}

function zellijSessionNameFromEnv(env = process.env) {
  const keys = [
    "OPENVSMOBILE_ZELLIJ_SESSION_NAME",
    "ZELLIJ_SESSION_NAME",
  ];
  for (const key of keys) {
    const value = env[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

function terminalActionFromHook(event, env = process.env) {
  const explicitSessionId =
    stringField(event, "openvsmobile_terminal_session_id") ??
    stringField(event, "terminal_session_id");
  const externalSessionId =
    stringField(event, "openvsmobile_external_session_id") ??
    zellijSessionNameFromEnv(env);

  if (explicitSessionId !== undefined) {
    const action = { kind: "open-terminal", sessionId: explicitSessionId };
    if (externalSessionId !== undefined) action.externalSessionId = externalSessionId;
    return action;
  }

  if (
    externalSessionId !== undefined &&
    externalSessionId.startsWith(MANAGED_ZELLIJ_PREFIX)
  ) {
    const sessionId = externalSessionId.slice(MANAGED_ZELLIJ_PREFIX.length);
    if (/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      return {
        kind: "open-terminal",
        sessionId,
        externalSessionId,
      };
    }
  }
  return undefined;
}

/// Translate an agent hook envelope to a Notification payload. Claude Code
/// and Codex hooks both send JSON envelopes; fields vary by version, so this
/// parser prefers explicit "last message" fields and falls back to the JSONL
/// transcript when present.
function agentHookToNotification(ev, { source = "claude-code" } = {}) {
  const event = typeof ev === "object" && ev !== null ? ev : {};
  const eventName =
    typeof event.hook_event_name === "string"
      ? event.hook_event_name
      : "Hook";
  const session =
    typeof event.session_id === "string" ? event.session_id : undefined;
  // groupKey: collapse repeated events from one session into one card.
  // Without this a long session produces N "Stop" notifications.
  const groupKey = session ? `${source}:${session}` : undefined;
  // Default title is the event name + a hint of context (tool name for
  // PreToolUse / PostToolUse; message body for Notification).
  let title = eventName;
  let body;
  let level = "info";
  if (eventName === "Notification" && typeof event.message === "string") {
    title = truncate(event.message.split(/\r?\n/)[0] ?? eventName, 80);
    body = event.message;
    level = "warning"; // Notification events usually mean Claude wants attention.
  } else if (
    (eventName === "PreToolUse" || eventName === "PostToolUse") &&
    typeof event.tool_name === "string"
  ) {
    title = truncate(`${eventName}: ${event.tool_name}`, 80);
    if (event.tool_input !== undefined) {
      try {
        body = JSON.stringify(event.tool_input, null, 2);
      } catch {
        body = String(event.tool_input);
      }
    }
  } else if (eventName === "Stop" || eventName === "SubagentStop") {
    const lastMessage = lastAgentMessageFromHook(event);
    if (lastMessage !== undefined && lastMessage.trim().length > 0) {
      const firstLine = firstNonEmptyLine(lastMessage);
      const prefix =
        eventName === "Stop" ? agentLabelForSource(source) : "Subagent";
      title = truncate(`${prefix}: ${firstLine}`, 80);
      body = truncateUtf8(lastMessage, 16_000);
    } else {
      title =
        eventName === "Stop" ? stopTitleForSource(source) : "Subagent finished";
    }
  } else if (eventName === "UserPromptSubmit" && typeof event.prompt === "string") {
    title = truncate(`Prompt: ${event.prompt.split(/\r?\n/)[0] ?? ""}`, 80);
    body = event.prompt;
  }
  const out = {
    source,
    level,
    title,
  };
  if (body !== undefined) out.body = truncateUtf8(body, 16_000);
  if (groupKey !== undefined) out.groupKey = groupKey;
  const action = terminalActionFromHook(event);
  if (action !== undefined) out.action = action;
  const fields = [];
  if (typeof event.cwd === "string") fields.push({ key: "cwd", value: event.cwd });
  if (session) fields.push({ key: "session", value: session });
  const transcriptPath =
    stringField(event, "transcript_path") ?? stringField(event, "transcriptPath");
  if (transcriptPath !== undefined) {
    fields.push({ key: "transcript", value: transcriptPath });
  }
  if (action?.externalSessionId !== undefined) {
    fields.push({ key: "zellij", value: action.externalSessionId });
  }
  if (fields.length > 0) out.fields = fields;
  return out;
}

async function main() {
  const opts = {
    server: { type: "string" },
    token: { type: "string" },
    source: { type: "string" },
    level: { type: "string" },
    title: { type: "string" },
    body: { type: "string" },
    field: { type: "string", multiple: true },
    link: { type: "string", multiple: true },
    action: { type: "string" },
    "group-key": { type: "string" },
    supersedes: { type: "string" },
    important: { type: "boolean" },
    ttl: { type: "string" },
    "from-json": { type: "string" },
    "from-claude-hook": { type: "boolean" },
    quiet: { type: "boolean" },
    help: { type: "boolean", short: "h" },
  };
  let parsed;
  try {
    parsed = parseArgs({ options: opts, allowPositionals: false });
  } catch (err) {
    die(EXIT_ARGS, err && err.message ? err.message : "argument error");
  }
  const { values } = parsed;

  if (values.help) {
    process.stdout.write(usage());
    process.exit(EXIT_OK);
  }

  // --- resolve server + token (flags > env > runtime.json > config.json) ---
  const cfg = readConfigFile();
  const runtime = readRuntimeInfo();

  let serverUrl;
  if (values.server) {
    serverUrl = parseServerUrl(values.server);
  } else if (process.env.OPENVSMOBILE_SERVER) {
    serverUrl = parseServerUrl(process.env.OPENVSMOBILE_SERVER);
  } else if (typeof runtime.port === "number") {
    serverUrl = `http://127.0.0.1:${runtime.port}`;
  } else if (typeof cfg.server === "string") {
    serverUrl = parseServerUrl(cfg.server);
  } else {
    die(
      EXIT_ARGS,
      "no server configured (set --server, OPENVSMOBILE_SERVER, or start the backend so runtime.json exists)",
    );
  }

  // Token never accepted on stdin or positionally — only flag / env / config
  // file. This is a safety invariant from the task brief.
  let token;
  if (values.token) {
    token = values.token;
  } else if (process.env.OPENVSMOBILE_TOKEN) {
    token = process.env.OPENVSMOBILE_TOKEN;
  } else if (typeof runtime.token === "string") {
    token = runtime.token;
  } else if (typeof cfg.token === "string") {
    token = cfg.token;
  } else {
    die(EXIT_ARGS, "no token configured (set --token, OPENVSMOBILE_TOKEN, or ensure config.json carries one)");
  }

  // --- assemble payload ---
  let payload;
  if (values["from-claude-hook"] === true) {
    // Claude Code fires hook scripts with a JSON envelope on stdin (see
    // https://docs.claude.com/en/docs/claude-code/hooks). We translate
    // that envelope into our Notification shape so a user's hook config
    // is a one-liner like:
    //
    //     "Stop": [{ "hooks": [{ "type": "command",
    //                            "command": "mobile-notify --from-claude-hook" }] }]
    let rawText;
    try {
      rawText = await readStdin();
    } catch (err) {
      die(EXIT_INTERNAL, `failed to read stdin: ${err.message}`);
    }
    let hookEvent;
    try {
      hookEvent = JSON.parse(rawText);
    } catch (err) {
      die(EXIT_ARGS, `--from-claude-hook: invalid JSON on stdin: ${err.message}`);
    }
    const source = values.source || "claude-code";
    payload = agentHookToNotification(hookEvent, { source });
    // Optional flag overrides on top of the derived payload (same as
    // --from-json).
    if (values.level) payload.level = values.level;
    if (values.title) payload.title = values.title;
    if (values.body) payload.body = values.body;
    if (values["group-key"] !== undefined) payload.groupKey = values["group-key"];
    if (values.important === true) payload.important = true;
  } else if (values["from-json"] !== undefined) {
    if (values["from-json"] !== "-") {
      die(EXIT_ARGS, "--from-json only accepts '-' (stdin) in v0");
    }
    let raw;
    try {
      raw = await readStdin();
    } catch (err) {
      die(EXIT_INTERNAL, `failed to read stdin: ${err.message}`);
    }
    try {
      payload = JSON.parse(raw);
    } catch (err) {
      die(EXIT_ARGS, `--from-json: invalid JSON on stdin: ${err.message}`);
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      die(EXIT_ARGS, "--from-json: payload must be a JSON object");
    }
    // Allow flag overrides on top of the JSON payload — useful for tweaking
    // one field without re-emitting the whole blob. Every assemble-mode flag
    // is honored as an override; sender supplies whichever it wants to
    // override and leaves the rest unset.
    if (values.source) payload.source = values.source;
    if (values.level) payload.level = values.level;
    if (values.title) payload.title = values.title;
    if (values.body) payload.body = values.body;
    if (values.field && values.field.length > 0) {
      payload.fields = values.field.map((s) => parseKv(s, "field"));
    }
    if (values.link && values.link.length > 0) {
      payload.links = values.link.map((s) => {
        const kv = parseKv(s, "link");
        return { title: kv.key, url: kv.value };
      });
    }
    if (values.action !== undefined) payload.action = parseAction(values.action);
    if (values["group-key"] !== undefined) payload.groupKey = values["group-key"];
    if (values.supersedes !== undefined) payload.supersedes = values.supersedes;
    if (values.important === true) payload.important = true;
    if (values.ttl !== undefined) {
      const n = Number(values.ttl);
      if (!Number.isFinite(n) || n < 0) {
        die(EXIT_ARGS, `--ttl must be a non-negative number of seconds: ${values.ttl}`);
      }
      payload.ttl = n;
    }
  } else {
    if (!values.source) die(EXIT_ARGS, "--source required");
    if (!values.title) die(EXIT_ARGS, "--title required");
    payload = {
      source: values.source,
      level: values.level || "info",
      title: values.title,
    };
    if (values.body !== undefined) payload.body = values.body;
    if (values.field && values.field.length > 0) {
      payload.fields = values.field.map((s) => parseKv(s, "field"));
    }
    if (values.link && values.link.length > 0) {
      payload.links = values.link.map((s) => {
        const kv = parseKv(s, "link");
        return { title: kv.key, url: kv.value };
      });
    }
    if (values.action !== undefined) payload.action = parseAction(values.action);
    if (values["group-key"] !== undefined) payload.groupKey = values["group-key"];
    if (values.supersedes !== undefined) payload.supersedes = values.supersedes;
    if (values.important === true) payload.important = true;
    if (values.ttl !== undefined) {
      const n = Number(values.ttl);
      if (!Number.isFinite(n) || n < 0) {
        die(EXIT_ARGS, `--ttl must be a non-negative number of seconds: ${values.ttl}`);
      }
      payload.ttl = n;
    }
  }

  if (payload.level !== undefined && !VALID_LEVELS.has(payload.level)) {
    die(EXIT_ARGS, `--level must be one of info|success|warning|error (got ${payload.level})`);
  }

  // --- POST /notify ---
  const url = `${serverUrl}/notify`;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), REQUEST_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
      signal: ac.signal,
    });
  } catch (err) {
    if (err && err.name === "AbortError") {
      die(EXIT_NETWORK, `request timed out after ${REQUEST_TIMEOUT_MS}ms: ${url}`);
    }
    die(EXIT_NETWORK, `network error: ${err && err.message ? err.message : err}`);
  } finally {
    clearTimeout(timer);
  }

  if (response.status === 401) {
    die(EXIT_AUTH, `auth rejected by ${serverUrl} (HTTP 401)`);
  }
  if (response.status === 403) {
    const text = await response.text().catch(() => "");
    die(
      EXIT_FORBIDDEN,
      `forbidden by token source-prefix (HTTP 403): ${text}`,
    );
  }
  if (response.status === 429) {
    const retry = response.headers.get("retry-after") || "?";
    const text = await response.text().catch(() => "");
    die(
      EXIT_RATE_LIMITED,
      `rate limited (HTTP 429, retry-after=${retry}s): ${text}`,
    );
  }
  if (response.status >= 500) {
    const text = await response.text().catch(() => "");
    die(EXIT_SERVER, `server error ${response.status}: ${text}`);
  }
  if (response.status >= 400) {
    const text = await response.text().catch(() => "");
    // 4xx other than 401 means the payload didn't validate — that's args.
    die(EXIT_ARGS, `server rejected payload (HTTP ${response.status}): ${text}`);
  }

  let result;
  try {
    result = await response.json();
  } catch (err) {
    die(EXIT_SERVER, `server returned non-JSON response: ${err.message}`);
  }
  if (!result || typeof result.id !== "string") {
    die(EXIT_SERVER, `server response missing id field: ${JSON.stringify(result)}`);
  }
  if (!values.quiet) {
    process.stdout.write(result.id + "\n");
  }
  process.exit(EXIT_OK);
}

function usage() {
  return `\
mobile-notify — post one notification to an openvsmobile-next backend

Usage:
  mobile-notify --source <s> --title <t> [options]
  mobile-notify --from-json -                (read full payload from stdin)

Connection:
  --server host:port           (else $OPENVSMOBILE_SERVER, runtime.json, config.json)
  --token <token>              (else $OPENVSMOBILE_TOKEN or config.json)

Payload:
  --source <s>                 required
  --level info|success|warning|error    default info
  --title <t>                  required unless --from-json
  --body <body>
  --field key=value            repeatable
  --link title=url             repeatable
  --action open-url:URL | copy:TEXT | open-workspace:ID | open-terminal:ID
  --group-key <key>
  --supersedes <id>
  --important
  --ttl <seconds>
  --from-json -                read full payload from stdin (overrides above)
  --from-claude-hook           read an agent hook envelope from stdin
                               and translate it; --source/--level/etc.
                               still apply as overrides.
  --quiet                      suppress success output (id still returned via exit 0)

Tokens:
  Both the single auth bearer (config.json) and publish tokens minted via
  auth.publishTokens.create are accepted. Publish tokens use the wire form
  "<id>.<secret>" — paste the full string into --token or $OPENVSMOBILE_TOKEN.

Exit codes:
  0  success
  1  internal CLI error (uncaught exception, stdin read failure)
  2  argument error / 4xx payload rejection
  3  network error / timeout
  4  authentication rejected (401)
  5  server error (5xx response)
  6  forbidden by token source-prefix (403)
  7  rate limited (429)
`;
}

main().catch((err) => {
  // Uncaught bug in the CLI itself — distinct from EXIT_SERVER (5), which is
  // reserved for actual 5xx responses from the backend.
  process.stderr.write(`mobile-notify: ${err && err.stack ? err.stack : err}\n`);
  process.exit(EXIT_INTERNAL);
});
