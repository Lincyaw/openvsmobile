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
//   * Exit codes: 0 ok / 2 args / 3 network / 4 auth / 5 server error.
//
// Reference: docs/design/mobile-code-platform.md §4.5.

import { parseArgs } from "node:util";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const EXIT_OK = 0;
const EXIT_ARGS = 2;
const EXIT_NETWORK = 3;
const EXIT_AUTH = 4;
const EXIT_SERVER = 5;

const REQUEST_TIMEOUT_MS = 10_000;
const VALID_LEVELS = new Set(["info", "success", "warning", "error"]);

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
  // Action grammar: "open-url:<url>" | "copy:<text>" | "open-workspace:<id>".
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
  die(EXIT_ARGS, `--action kind must be open-url|copy|open-workspace, got: ${kind}`);
}

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", (err) => reject(err));
  });
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
  if (values["from-json"] !== undefined) {
    if (values["from-json"] !== "-") {
      die(EXIT_ARGS, "--from-json only accepts '-' (stdin) in v0");
    }
    let raw;
    try {
      raw = await readStdin();
    } catch (err) {
      die(EXIT_NETWORK, `failed to read stdin: ${err.message}`);
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
    // one field without re-emitting the whole blob. Source remains required.
    if (values.source) payload.source = values.source;
    if (values.level) payload.level = values.level;
    if (values.title) payload.title = values.title;
    if (values.body) payload.body = values.body;
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
  --action open-url:URL | copy:TEXT | open-workspace:ID
  --group-key <key>
  --supersedes <id>
  --important
  --ttl <seconds>
  --from-json -                read full payload from stdin (overrides above)
  --quiet                      suppress success output (id still returned via exit 0)

Exit codes:
  0  success
  2  argument error / 4xx payload rejection
  3  network error / timeout
  4  authentication rejected
  5  server error
`;
}

main().catch((err) => {
  process.stderr.write(`mobile-notify: ${err && err.stack ? err.stack : err}\n`);
  process.exit(EXIT_SERVER);
});
