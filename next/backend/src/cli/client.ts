import { EventEmitter } from "node:events";
import WebSocket from "ws";
import type { Host } from "./config.js";
import { IrohRpcSocket } from "../irohRpcSocket.js";
import { connectIroh } from "./iroh.js";

const REQUEST_TIMEOUT_MS = 10_000;
const HEARTBEAT_MS = 15_000;
export class ClientRpcError extends Error {
  constructor(
    public readonly code: number,
    message: string,
  ) {
    super(message);
  }
}

/** One connection attempt. The terminal controller owns reconnect and resync. */
export class RpcClient extends EventEmitter {
  private socket?: WebSocket | IrohRpcSocket;
  private readonly abort = new AbortController();
  private nextId = 0;
  private pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: NodeJS.Timeout;
    }
  >();

  async connect(host: Host): Promise<void> {
    const socket = host.iroh
      ? await connectIroh(host.iroh, this.abort.signal)
      : new WebSocket(host.url, { handshakeTimeout: REQUEST_TIMEOUT_MS });
    if (this.abort.signal.aborted) {
      socket.terminate();
      throw new Error("Connection cancelled");
    }
    this.socket = socket;
    let heartbeat: NodeJS.Timeout | undefined;
    let awaitingPong = false;
    if (socket instanceof WebSocket) {
      socket.on("pong", () => {
        awaitingPong = false;
      });
      socket.once("open", () => {
        // WebSocket control frames detect a silent network loss without polling
        // application state. A missing pong tears down this connection attempt.
        heartbeat = setInterval(() => {
          if (awaitingPong) {
            socket.terminate();
            return;
          }
          awaitingPong = true;
          socket.ping();
        }, HEARTBEAT_MS);
      });
    }
    socket.on("message", (raw) => {
      let message;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        socket.terminate();
        return;
      }
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        if (message.error)
          pending.reject(
            new ClientRpcError(message.error.code, message.error.message),
          );
        else pending.resolve(message.result);
      } else if (typeof message.method === "string") {
        this.emit("notification", message.method, message.params);
      }
    });
    socket.on("error", () => {
      /* Close rejects pending requests; never print transport credentials. */
    });
    socket.on("close", () => {
      clearInterval(heartbeat);
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Connection closed"));
      }
      this.pending.clear();
      this.emit("disconnected");
    });
    try {
      if (socket instanceof IrohRpcSocket) socket.start();
      else
        await new Promise<void>((resolve, reject) => {
          socket.once("open", resolve);
          socket.once("error", () =>
            reject(new Error("Cannot connect to server")),
          );
          socket.once("close", () => reject(new Error("Connection closed")));
        });
      await this.call("auth.handshake", {
        token: host.token,
        protocolVersion: "1.0",
        client: { name: "ovsm-cli" },
      });
      await this.call("terminal.unsubscribe");
    } catch (error) {
      this.close();
      throw error;
    }
  }

  call<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN)
      return Promise.reject(new Error("Not connected"));
    const id = ++this.nextId;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(`Request timed out: ${method}; outcome may be unknown`),
        );
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      });
      socket.send(
        JSON.stringify({ jsonrpc: "2.0", id, method, params }),
        (error) => {
          if (!error) return;
          this.pending.delete(id);
          clearTimeout(timer);
          reject(new Error("Request send failed; outcome may be unknown"));
        },
      );
    });
  }

  close(): void {
    this.abort.abort();
    this.socket?.terminate();
  }
}

export interface History {
  scrollbackBase64: string;
  scrollbackOffsetEnd: number;
  bytesDropped: number;
}
export interface OutputChunk {
  dataBase64: string;
  seqEnd: number;
}

/** Offsets are bytes, not JS string indices: preserve partial UTF-8 sequences. */
export class TerminalReplay {
  private offset = 0;
  snapshot(history: History): Buffer {
    // A lazy zellij reattach can reset the server's byte counter.
    this.offset = history.scrollbackOffsetEnd;
    return Buffer.from(history.scrollbackBase64, "base64");
  }
  chunk(chunk: OutputChunk): Buffer {
    const bytes = Buffer.from(chunk.dataBase64, "base64");
    const skip = Math.max(0, this.offset - (chunk.seqEnd - bytes.length));
    this.offset = Math.max(this.offset, chunk.seqEnd);
    return bytes.subarray(skip);
  }
}
