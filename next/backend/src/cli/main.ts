#!/usr/bin/env node
import { parseArgs } from "node:util";
import { createInterface } from "node:readline/promises";
import { stdin, stderr } from "node:process";
import { attach } from "./attach.js";
import { ClientRpcError, RpcClient, type History } from "./client.js";
import {
  configPath,
  loadConfig,
  normalizeUrl,
  saveConfig,
  type Host,
  importHost,
  validateHost,
} from "./config.js";

const HELP = `Usage: ovsm [--host NAME] [--json] COMMAND

  connect [SESSION]                  Pick a machine/session, then attach
  host add NAME URL|iroh:TICKET [--token-stdin]  Save a machine; token from OPENVSMOBILE_TOKEN
  host import NAME                  Import Iroh pairing/runtime JSON from stdin
  host list                         List machines (never prints tokens)
  host remove NAME                  Remove a saved machine
  workspace list                    List active workspaces and recents
  session list [--workspace ID]      List backend terminal sessions
  session external                  List discoverable zellij sessions
  session create [--workspace ID]    Create a session; returns its ID
  session adopt NAME [--workspace ID] Adopt an existing zellij session
  session attach [SESSION]          Attach by exact ID or unique ID prefix
  session history SESSION           Read bounded terminal history
  session send SESSION [--enter]     Send stdin bytes; --enter adds carriage return

With no command, opens the interactive picker. Ctrl-] leaves attach without killing
the remote session. Ctrl-C is forwarded to the remote terminal.
--json gives structured stdout/errors for scripts and skills; attach is TTY-only.
Credentials: client.json (0600); override with OPENVSMOBILE_CLIENT_CONFIG.
URL/token overrides: OPENVSMOBILE_URL / OPENVSMOBILE_TOKEN.
Use SSH port forwarding for machines without a reachable WebSocket endpoint.
`;

interface Session {
  id: string;
  title: string | null;
  cwd: string;
  workspaceRoot: string | null;
  externalSessionId: string | null;
}
interface Workspace {
  id: string;
  label: string;
  root: string;
}

function display(value: unknown): void {
  process.stdout.write(JSON.stringify(value, null, 2) + "\n");
}
async function readStdin(): Promise<Buffer> {
  if (stdin.isTTY) throw new Error("Redirect or pipe stdin for this command");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of stdin) {
    const bytes = Buffer.from(chunk);
    size += bytes.length;
    if (size > 1024 * 1024) throw new Error("Input exceeds 1 MiB");
    chunks.push(bytes);
  }
  return Buffer.concat(chunks);
}
async function pick<T>(
  items: T[],
  label: (item: T) => string,
  noun: string,
): Promise<T> {
  if (!items.length) throw new Error(`No ${noun} available`);
  if (items.length === 1) return items[0];
  if (!stdin.isTTY || !process.stdout.isTTY || jsonMode)
    throw new Error(`Select ${noun} explicitly in non-interactive mode`);
  items.forEach((item, index) =>
    stderr.write(`${index + 1}. ${label(item)}\n`),
  );
  const prompt = createInterface({ input: stdin, output: stderr });
  try {
    const answer = await prompt.question(
      `Choose ${noun} [1-${items.length}]: `,
    );
    const index = Number(answer) - 1;
    if (!Number.isInteger(index) || index < 0 || index >= items.length)
      throw new Error("Invalid selection");
    return items[index];
  } finally {
    prompt.close();
  }
}

let jsonMode = process.argv.includes("--json");
let redactedToken = process.env.OPENVSMOBILE_TOKEN;
async function main(): Promise<void> {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      host: { type: "string" },
      json: { type: "boolean" },
      help: { type: "boolean", short: "h" },
      workspace: { type: "string" },
      "token-stdin": { type: "boolean" },
      enter: { type: "boolean" },
    },
  });
  jsonMode = values.json ?? false;
  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  const [group = "connect", action, target, ...extra] = positionals;
  const commands: Record<string, number> = {
    "host add": 4,
    "host list": 2,
    "host import": 3,
    "host remove": 3,
    "workspace list": 2,
    "session list": 2,
    "session external": 2,
    "session create": 2,
    "session adopt": 3,
    "session attach": 2,
    "session history": 3,
    "session send": 3,
  };
  const key = `${group} ${action}`;
  if (group === "connect") {
    if (positionals.length > 2) throw new Error("Usage: connect [SESSION]");
  } else if (
    !(key in commands) ||
    positionals.length > (key === "session attach" ? 3 : commands[key]) ||
    positionals.length < commands[key]
  ) {
    throw new Error("Unknown command or missing arguments; see --help");
  }
  if (values["token-stdin"] && key !== "host add")
    throw new Error("--token-stdin is only valid with host add");
  if (values.enter && key !== "session send")
    throw new Error("--enter is only valid with session send");
  if (
    values.workspace &&
    !["session list", "session create", "session adopt"].includes(key)
  )
    throw new Error("--workspace is only valid with session list/create/adopt");
  const config = loadConfig();
  if (group === "host") {
    if (action === "list") {
      display({
        hosts: Object.entries(config.hosts).map(([name, host]) => ({
          name,
          ...(host.iroh
            ? { transport: "iroh" }
            : { transport: "websocket", url: host.url }),
        })),
      });
      return;
    }
    if (action === "remove") {
      if (!Object.hasOwn(config.hosts, target))
        throw new Error("Unknown machine alias");
      delete config.hosts[target];
    } else {
      if (!/^[a-zA-Z0-9_-]+$/.test(target))
        throw new Error("Machine alias must contain letters, numbers, _ or -");
      if (action === "import") {
        config.hosts[target] = importHost((await readStdin()).toString("utf8"));
      } else {
        const token = values["token-stdin"]
          ? (await readStdin()).toString("utf8").trim()
          : process.env.OPENVSMOBILE_TOKEN;
        if (!token)
          throw new Error("Supply OPENVSMOBILE_TOKEN or --token-stdin");
        redactedToken = token;
        config.hosts[target] = extra[0].startsWith("iroh:")
          ? validateHost({ token, iroh: { ticket: extra[0].slice(5) } })
          : { url: normalizeUrl(extra[0]), token };
      }
    }
    saveConfig(config);
    display({ ok: true, configPath: configPath() });
    return;
  }
  let host: Host;
  if (process.env.OPENVSMOBILE_URL) {
    if (values.host)
      throw new Error("Use --host or OPENVSMOBILE_URL, not both");
    if (!process.env.OPENVSMOBILE_TOKEN)
      throw new Error("OPENVSMOBILE_URL requires OPENVSMOBILE_TOKEN");
    host = {
      url: normalizeUrl(process.env.OPENVSMOBILE_URL),
      token: process.env.OPENVSMOBILE_TOKEN,
    };
  } else {
    const name =
      values.host ??
      (await pick(Object.keys(config.hosts), (name) => name, "machine"));
    if (!Object.hasOwn(config.hosts, name))
      throw new Error("Unknown machine alias");
    host = config.hosts[name];
  }
  redactedToken = host.token;
  const interactive = group === "connect" || key === "session attach";
  if (interactive && (jsonMode || !stdin.isTTY || !process.stdout.isTTY))
    throw new Error(
      "attach requires a TTY without --json; use session list/history/send for scripts",
    );
  const client = new RpcClient();
  try {
    await client.connect(host);
    if (key === "workspace list") {
      display(await client.call("workspace.list"));
      return;
    }
    const params = values.workspace ? { workspaceId: values.workspace } : {};
    if (key === "session external") {
      display(await client.call("terminal.listExternalSessions"));
      return;
    }
    if (key === "session create" || key === "session adopt") {
      const size = {
        cols: process.stdout.columns || 80,
        rows: process.stdout.rows || 24,
      };
      display(
        await client.call(
          key === "session create"
            ? "terminal.create"
            : "terminal.adoptExternalSession",
          {
            ...params,
            ...size,
            ...(key === "session adopt" ? { sessionName: target } : {}),
          },
        ),
      );
      return;
    }
    const { sessions } = await client.call<{ sessions: Session[] }>(
      "terminal.list",
      params,
    );
    if (key === "session list") {
      if (jsonMode) display({ sessions });
      else
        for (const session of sessions)
          process.stdout.write(
            `${session.id}\t${session.title ?? session.externalSessionId ?? "shell"}\t${session.cwd}\n`,
          );
      return;
    }
    const wanted = group === "connect" ? action : target;
    let session: Session;
    if (wanted) {
      const exact = sessions.find((session) => session.id === wanted);
      const matches = exact
        ? [exact]
        : sessions.filter((session) => session.id.startsWith(wanted));
      if (matches.length !== 1)
        throw new Error(
          matches.length
            ? "Ambiguous session prefix; use full ID"
            : "Session not found",
        );
      session = matches[0];
    } else {
      // Include workspace context without activating it for other clients.
      const { active } = await client.call<{ active: Workspace[] }>(
        "workspace.list",
      );
      session = await pick(
        sessions,
        (session) => {
          const workspace = active.find(
            (workspace) => workspace.root === session.workspaceRoot,
          );
          return `${session.title ?? session.externalSessionId ?? "shell"} · ${workspace?.label ?? session.cwd} · ${session.id}`;
        },
        "session",
      );
    }
    if (key === "session history") {
      const history = await client.call<History>("terminal.history", {
        sessionId: session.id,
      });
      if (jsonMode) display({ sessionId: session.id, ...history });
      else
        process.stdout.write(Buffer.from(history.scrollbackBase64, "base64"));
    } else if (key === "session send") {
      const data = await readStdin();
      const bytes = values.enter
        ? Buffer.concat([data, Buffer.from("\r")])
        : data;
      if (!bytes.length) throw new Error("No input bytes supplied");
      display(
        await client.call("terminal.write", {
          sessionId: session.id,
          dataBase64: bytes.toString("base64"),
        }),
      );
    } else {
      client.close();
      await attach(host, session.id);
    }
  } finally {
    client.close();
  }
}

void main().catch((error: Error) => {
  // RPC errors can include user-controlled text. Do not disclose the bearer token.
  const message = redactedToken
    ? error.message.split(redactedToken).join("[REDACTED]")
    : error.message;
  const code = error instanceof ClientRpcError ? error.code : "CLI_ERROR";
  if (jsonMode)
    stderr.write(JSON.stringify({ error: { code, message } }) + "\n");
  else stderr.write(`ovsm: ${message}\n`);
  process.exitCode = 1;
});
