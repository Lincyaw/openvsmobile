// Default-on Iroh transport for the same frontend JSON-RPC protocol that
// also rides over /rpc WebSocket. Iroh handles peer reachability; the auth
// token and all workspace/terminal/plugin semantics stay unchanged.
//
// Disable with:
//   OPENVSMOBILE_IROH=0
//
// Relay selection (see resolveRelaySettings):
//   default                         n0 public relays + n0 DNS/pkarr discovery
//   OPENVSMOBILE_IROH_RELAY_URLS=…  only these relays; no n0 relay probing,
//                                   no n0 DNS/pkarr. Direct p2p stays on.
//   OPENVSMOBILE_IROH_RELAY_TOKEN=…  bearer token for relays that run
//                                   `access.shared_token`
//   OPENVSMOBILE_IROH_RELAY_MODE=disabled
//                                   no relays, no n0 discovery (LAN only)
// The resolved settings are published in runtime.json so the app builds
// its own endpoint the same way and never probes relays we don't use.
//
// Pairing data is surfaced through runtime.json and stderr as endpoint
// identity/ticket only. The bearer token is never embedded in Iroh tickets.

import { createRequire } from "node:module";
import { EventEmitter } from "node:events";
import type { WebSocket } from "ws";
import { loadIrohSecretKey, saveIrohSecretKey } from "./config.js";
import { Connection, type ConnectionDeps } from "./connection.js";

const require = createRequire(import.meta.url);
const DEFAULT_ALPN = "openvsmobile.rpc.v1";
const DEFAULT_FRAME_LIMIT = 1024 * 1024;
const DEFAULT_ONLINE_TIMEOUT_MS = 10_000;

type ByteArray = number[];

interface IrohModule {
  Endpoint: {
    builder(): IrohEndpointBuilder;
  };
  EndpointTicket: {
    fromAddr(addr: IrohEndpointAddr): { toString(): string };
  };
  RelayMap: {
    empty(): IrohRelayMap;
  };
  RelayMode: {
    disabled(): unknown;
    staging(): unknown;
    defaultMode(): unknown;
    custom(map: IrohRelayMap): unknown;
  };
  SecretKey: {
    generate(): IrohSecretKey;
    fromBytes(bytes: ByteArray): IrohSecretKey;
  };
}

interface IrohRelayMap {
  insert(config: IrohRelayEntry): void;
}

interface IrohSecretKey {
  toBytes(): ByteArray;
}

interface IrohEndpointBuilder {
  applyN0(): void;
  applyMinimal(): void;
  secretKey(bytes: ByteArray): void;
  alpns(alpns: ByteArray[]): void;
  relayMode(mode: unknown): void;
  bindAddr(addr: string): void;
  bind(): Promise<IrohEndpoint>;
}

interface IrohEndpoint {
  id(): { toString(): string };
  addr(): IrohEndpointAddr;
  online(): Promise<void>;
  acceptNext(): Promise<IrohIncoming | null>;
  close(): Promise<void>;
  isClosed(): boolean;
}

interface IrohEndpointAddr {
  id(): { toString(): string };
  relayUrl(): string | null;
  directAddresses(): string[];
}

interface IrohIncoming {
  accept(): Promise<IrohAccepting>;
  refuse(): Promise<void>;
}

interface IrohAccepting {
  connect(): Promise<IrohConnection>;
}

interface IrohConnection {
  acceptBi(): Promise<IrohBiStream>;
  remoteId(): { toString(): string };
  close(errorCode: bigint, reason: ByteArray): void;
  closed(): Promise<string>;
}

interface IrohBiStream {
  send: IrohSendStream;
  recv: IrohRecvStream;
}

interface IrohSendStream {
  writeAll(buf: ByteArray): Promise<void>;
  finish(): Promise<void>;
  reset(errorCode: bigint): Promise<void>;
}

interface IrohRecvStream {
  read(sizeLimit: number): Promise<ByteArray>;
}

/// One self-hosted relay. `quicPort` set means the relay also serves
/// QUIC address discovery (QAD), which lets endpoints learn their public
/// address and holepunch through NATs; unset means relay-forwarding only.
/// `authToken` is presented to relays configured with
/// `access.shared_token`, so only paired devices can use the relay.
export interface IrohRelayEntry {
  url: string;
  quicPort?: number;
  authToken?: string;
}

/// Which relays (and with them, which discovery services) an endpoint
/// uses. Both sides of a connection should agree, so this travels to the
/// app via runtime.json / pairing. Anything other than "n0" / "staging"
/// means "never contact n0 infrastructure".
export type IrohRelaySettings =
  | { mode: "n0" }
  | { mode: "staging" }
  | { mode: "disabled" }
  | { mode: "custom"; relays: IrohRelayEntry[] };

export interface IrohRuntimeInfo {
  endpointId: string;
  ticket: string;
  alpn: string;
  relayUrl: string | null;
  directAddresses: string[];
  relay: IrohRelaySettings;
}

const DEFAULT_RELAY_QUIC_PORT = 7842;

export interface IrohRpcServer {
  info: IrohRuntimeInfo;
  close(): Promise<void>;
}

export function irohEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env.OPENVSMOBILE_IROH;
  if (raw === undefined || raw.length === 0) return true;
  return !["0", "false", "off", "no"].includes(raw.trim().toLowerCase());
}

export async function startIrohRpcServer(
  deps: ConnectionDeps,
): Promise<IrohRpcServer | null> {
  if (!irohEnabled()) return null;

  const relay = resolveRelaySettings();
  const iroh = loadIrohModule();
  const alpn = process.env.OPENVSMOBILE_IROH_ALPN || DEFAULT_ALPN;
  const alpnBytes = bytes(alpn);
  const builder = iroh.Endpoint.builder();
  if (relay.mode === "n0" || relay.mode === "staging") {
    builder.applyN0();
  } else {
    // Minimal = crypto provider only: no n0 relay map, no pkarr
    // publishing to dns.iroh.link, no DNS address lookups.
    builder.applyMinimal();
  }
  builder.secretKey(resolveSecretKey(iroh));
  builder.alpns([alpnBytes]);

  const bindAddr = process.env.OPENVSMOBILE_IROH_BIND_ADDR;
  if (bindAddr !== undefined && bindAddr.trim().length > 0) {
    builder.bindAddr(bindAddr.trim());
  }

  builder.relayMode(relayModeFor(iroh, relay));
  const endpoint = await builder.bind();
  if (relay.mode !== "disabled") {
    const timeoutMs = parsePositiveInt(
      process.env.OPENVSMOBILE_IROH_ONLINE_TIMEOUT_MS,
      DEFAULT_ONLINE_TIMEOUT_MS,
    );
    const online = await waitForOnline(endpoint, timeoutMs);
    if (!online) {
      console.error(
        `[openvsmobile-next] Iroh: endpoint did not reach a relay within ${timeoutMs}ms; continuing with local/direct addresses`,
      );
    }
  }

  const addr = endpoint.addr();
  const info: IrohRuntimeInfo = {
    endpointId: endpoint.id().toString(),
    ticket: iroh.EndpointTicket.fromAddr(addr).toString(),
    alpn,
    relayUrl: addr.relayUrl(),
    directAddresses: addr.directAddresses(),
    relay,
  };

  let closed = false;
  const acceptTask = acceptLoop(endpoint, deps);
  acceptTask.catch((err) => {
    if (!closed) {
      console.error("[openvsmobile-next] Iroh accept loop failed:", err);
    }
  });

  return {
    info,
    close: async () => {
      closed = true;
      await endpoint.close();
      await acceptTask.catch(() => {});
    },
  };
}

function loadIrohModule(): IrohModule {
  try {
    return require("@number0/iroh") as IrohModule;
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    throw new Error(
      `Iroh is enabled but @number0/iroh could not be loaded: ${detail}`,
    );
  }
}

function resolveSecretKey(iroh: IrohModule): ByteArray {
  const fromEnv = process.env.OPENVSMOBILE_IROH_SECRET_KEY;
  const encoded =
    fromEnv !== undefined && fromEnv.trim().length > 0
      ? fromEnv.trim()
      : loadIrohSecretKey();
  if (encoded !== null) {
    return iroh.SecretKey.fromBytes(decodeSecretKey(encoded)).toBytes();
  }
  const key = iroh.SecretKey.generate();
  const raw = key.toBytes();
  saveIrohSecretKey(Buffer.from(raw).toString("base64url"));
  return raw;
}

function decodeSecretKey(encoded: string): ByteArray {
  const trimmed = encoded.trim();
  const buf =
    /^[0-9a-fA-F]{64}$/.test(trimmed)
      ? Buffer.from(trimmed, "hex")
      : Buffer.from(trimmed, "base64url");
  if (buf.length !== 32) {
    throw new Error(
      `OPENVSMOBILE_IROH_SECRET_KEY must decode to 32 bytes, got ${buf.length}`,
    );
  }
  return Array.from(buf);
}

/// Parse the relay env vars. Pure; throws on malformed config so a typo
/// fails the boot loudly instead of silently falling back to n0.
export function resolveRelaySettings(
  env: NodeJS.ProcessEnv = process.env,
): IrohRelaySettings {
  const urls = parseCsv(env.OPENVSMOBILE_IROH_RELAY_URLS);
  if (urls.length > 0) {
    const quicPort = parseQuicPort(env.OPENVSMOBILE_IROH_RELAY_QUIC_PORT);
    const authToken = env.OPENVSMOBILE_IROH_RELAY_TOKEN?.trim();
    return {
      mode: "custom",
      relays: urls.map((raw) => {
        const url = parseRelayUrl(raw);
        const entry: IrohRelayEntry = { url: url.toString() };
        // QAD needs TLS on the relay, so a plain-http relay never gets a
        // QUIC port: probing one would only send packets that cannot be
        // answered.
        if (url.protocol === "https:" && quicPort !== null) {
          entry.quicPort = quicPort;
        }
        if (authToken) entry.authToken = authToken;
        return entry;
      }),
    };
  }

  const mode = env.OPENVSMOBILE_IROH_RELAY_MODE?.trim().toLowerCase() || "default";
  switch (mode) {
    case "disabled":
    case "off":
    case "none":
      return { mode: "disabled" };
    case "staging":
      return { mode: "staging" };
    case "default":
    case "n0":
      return { mode: "n0" };
    default:
      throw new Error(
        `invalid OPENVSMOBILE_IROH_RELAY_MODE=${mode}; expected default, staging, or disabled`,
      );
  }
}

function parseRelayUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`invalid relay URL in OPENVSMOBILE_IROH_RELAY_URLS: ${raw}`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(
      `relay URL must be http:// or https://, got ${raw} in OPENVSMOBILE_IROH_RELAY_URLS`,
    );
  }
  return url;
}

/// Unset → iroh's default QAD port; "0"/"off" → no QAD.
function parseQuicPort(raw: string | undefined): number | null {
  if (raw === undefined || raw.trim().length === 0) return DEFAULT_RELAY_QUIC_PORT;
  const trimmed = raw.trim().toLowerCase();
  if (trimmed === "0" || trimmed === "off" || trimmed === "none") return null;
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`invalid OPENVSMOBILE_IROH_RELAY_QUIC_PORT=${raw}`);
  }
  return n;
}

function relayModeFor(iroh: IrohModule, relay: IrohRelaySettings): unknown {
  switch (relay.mode) {
    case "n0":
      return iroh.RelayMode.defaultMode();
    case "staging":
      return iroh.RelayMode.staging();
    case "disabled":
      return iroh.RelayMode.disabled();
    case "custom": {
      const map = iroh.RelayMap.empty();
      for (const entry of relay.relays) map.insert(entry);
      return iroh.RelayMode.custom(map);
    }
  }
}

function parseCsv(raw: string | undefined): string[] {
  if (raw === undefined || raw.trim().length === 0) return [];
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

async function waitForOnline(
  endpoint: IrohEndpoint,
  timeoutMs: number,
): Promise<boolean> {
  let timer: NodeJS.Timeout | null = null;
  try {
    return await Promise.race([
      endpoint.online().then(() => true),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), timeoutMs);
      }),
    ]);
  } catch {
    return false;
  } finally {
    if (timer !== null) clearTimeout(timer);
  }
}

async function acceptLoop(
  endpoint: IrohEndpoint,
  deps: ConnectionDeps,
): Promise<void> {
  while (!endpoint.isClosed()) {
    const incoming = await endpoint.acceptNext();
    if (incoming === null) return;
    void handleIncoming(incoming, deps);
  }
}

async function handleIncoming(
  incoming: IrohIncoming,
  deps: ConnectionDeps,
): Promise<void> {
  let conn: IrohConnection | null = null;
  try {
    const accepting = await incoming.accept();
    conn = await accepting.connect();
    const bi = await conn.acceptBi();
    const socket = new IrohRpcSocket(bi, conn);
    new Connection(socket as unknown as WebSocket, deps);
    socket.start();
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error(`[openvsmobile-next] Iroh incoming connection failed: ${detail}`);
    try {
      if (conn !== null) {
        conn.close(1n, bytes("openvsmobile: connection failed"));
      } else {
        await incoming.refuse();
      }
    } catch {
      // Already gone.
    }
  }
}

class IrohRpcSocket extends EventEmitter {
  public readonly OPEN = 1;
  public readonly CLOSING = 2;
  public readonly CLOSED = 3;
  public readyState = this.OPEN;
  public bufferedAmount = 0;
  private pending = "";
  private writeChain: Promise<void> = Promise.resolve();
  private readonly maxFrameBytes: number;

  constructor(
    private readonly stream: IrohBiStream,
    private readonly conn: IrohConnection,
  ) {
    super();
    this.maxFrameBytes = parsePositiveInt(
      process.env.OPENVSMOBILE_IROH_MAX_FRAME_BYTES,
      DEFAULT_FRAME_LIMIT,
    );
  }

  public start(): void {
    void this.readLoop();
    void this.conn.closed().then(
      () => this.finishClose(),
      () => this.finishClose(),
    );
  }

  public send(msg: string, cb?: (err?: Error) => void): void {
    if (this.readyState !== this.OPEN) {
      cb?.(new Error("Iroh stream is closed"));
      return;
    }
    const payload = Buffer.from(`${msg}\n`, "utf8");
    this.bufferedAmount += payload.length;
    this.writeChain = this.writeChain
      .then(async () => {
        await this.stream.send.writeAll(Array.from(payload));
      })
      .then(
        () => cb?.(),
        (err: unknown) => {
          const error = err instanceof Error ? err : new Error(String(err));
          cb?.(error);
          this.emit("error", error);
          this.finishClose();
        },
      )
      .finally(() => {
        this.bufferedAmount = Math.max(0, this.bufferedAmount - payload.length);
      });
  }

  public close(code = 0, reason = ""): void {
    if (this.readyState !== this.OPEN) return;
    this.readyState = this.CLOSING;
    this.writeChain
      .then(() => this.stream.send.finish())
      .catch(() => {})
      .finally(() => {
        try {
          this.conn.close(BigInt(code), bytes(String(reason).slice(0, 256)));
        } catch {
          // Already closed.
        }
        this.finishClose();
      });
  }

  public terminate(): void {
    if (this.readyState === this.CLOSED) return;
    this.readyState = this.CLOSING;
    try {
      this.stream.send.reset(1n).catch(() => {});
    } catch {
      // Already gone.
    }
    try {
      this.conn.close(1n, bytes("terminated"));
    } catch {
      // Already gone.
    }
    this.finishClose();
  }

  private async readLoop(): Promise<void> {
    try {
      while (this.readyState === this.OPEN) {
        const chunk = await this.stream.recv.read(16 * 1024);
        if (chunk.length === 0) break;
        this.acceptBytes(Buffer.from(chunk).toString("utf8"));
      }
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      this.emit("error", error);
    } finally {
      this.finishClose();
    }
  }

  private acceptBytes(text: string): void {
    this.pending += text;
    if (Buffer.byteLength(this.pending, "utf8") > this.maxFrameBytes) {
      this.emit("error", new Error("Iroh JSON-RPC frame too large"));
      this.terminate();
      return;
    }
    for (;;) {
      const idx = this.pending.indexOf("\n");
      if (idx < 0) return;
      const frame = this.pending.slice(0, idx).trimEnd();
      this.pending = this.pending.slice(idx + 1);
      if (frame.length > 0) {
        this.emit("message", frame);
      }
    }
  }

  private finishClose(): void {
    if (this.readyState === this.CLOSED) return;
    this.readyState = this.CLOSED;
    this.emit("close");
  }
}

function bytes(s: string): ByteArray {
  return Array.from(Buffer.from(s, "utf8"));
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.length === 0) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) return fallback;
  return n;
}
