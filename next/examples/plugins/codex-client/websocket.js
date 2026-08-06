// Small RFC 6455 client for Codex app-server.
//
// Node's browser-compatible global WebSocket does not expose handshake
// headers, while Codex remote listeners expect `Authorization: Bearer ...`.
// Keeping this implementation here lets the plugin stay within the platform's
// "SDK + Node built-ins only" rule without weakening remote authentication.

import { createHash, randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import http from "node:http";
import https from "node:https";
import { Buffer } from "node:buffer";

const CONNECT_TIMEOUT_MS = 10_000;
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const RFC_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function encodeClientFrame(opcode, payload = Buffer.alloc(0)) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const mask = randomBytes(4);
  let header;
  if (body.length < 126) {
    header = Buffer.allocUnsafe(2);
    header[1] = 0x80 | body.length;
  } else if (body.length <= 0xffff) {
    header = Buffer.allocUnsafe(4);
    header[1] = 0x80 | 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.allocUnsafe(10);
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  header[0] = 0x80 | opcode;
  const masked = Buffer.allocUnsafe(body.length);
  for (let i = 0; i < body.length; i += 1) {
    masked[i] = body[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function websocketAccept(key) {
  return createHash("sha1").update(`${key}${RFC_GUID}`).digest("base64");
}

export class HeaderWebSocket extends EventEmitter {
  constructor(
    url,
    { bearerToken = "", connectTimeoutMs = CONNECT_TIMEOUT_MS } = {},
  ) {
    super();
    this.url = new URL(url);
    this.bearerToken = bearerToken;
    this.connectTimeoutMs = connectTimeoutMs;
    this.request = null;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentBytes = 0;
    this.fragmentOpcode = null;
    this.open = false;
    this.closed = false;
    this.closeEmitted = false;
  }

  connect() {
    if (this.url.protocol !== "ws:" && this.url.protocol !== "wss:") {
      return Promise.reject(
        new Error("Codex endpoint must use ws:// or wss://"),
      );
    }
    if (this.request !== null || this.socket !== null) {
      return Promise.reject(new Error("WebSocket client already used"));
    }

    return new Promise((resolve, reject) => {
      const key = randomBytes(16).toString("base64");
      const transport = this.url.protocol === "wss:" ? https : http;
      const requestUrl = new URL(this.url);
      requestUrl.protocol = this.url.protocol === "wss:" ? "https:" : "http:";
      const headers = {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Key": key,
        "Sec-WebSocket-Version": "13",
      };
      if (this.bearerToken) {
        headers.Authorization = `Bearer ${this.bearerToken}`;
      }

      let settled = false;
      const finishReject = (err) => {
        if (!settled) {
          settled = true;
          reject(err);
        }
      };
      const req = transport.request(requestUrl, {
        method: "GET",
        headers,
      });
      this.request = req;
      req.setTimeout(this.connectTimeoutMs, () => {
        req.destroy(new Error("Codex WebSocket connection timed out"));
      });
      req.once("error", (err) => {
        finishReject(err);
        this.fail(err);
      });
      req.once("response", (response) => {
        response.resume();
        const err = new Error(
          `Codex WebSocket upgrade failed with HTTP ${response.statusCode ?? "unknown"}`,
        );
        finishReject(err);
        this.fail(err);
      });
      req.once("upgrade", (response, socket, head) => {
        if (
          response.statusCode !== 101 ||
          String(response.headers.upgrade ?? "").toLowerCase() !== "websocket"
        ) {
          const err = new Error(
            "Codex WebSocket handshake did not switch protocols",
          );
          socket.destroy();
          finishReject(err);
          this.fail(err);
          return;
        }
        const accept = response.headers["sec-websocket-accept"];
        if (accept !== websocketAccept(key)) {
          const err = new Error(
            "Codex WebSocket handshake returned an invalid accept key",
          );
          socket.destroy();
          finishReject(err);
          this.fail(err);
          return;
        }
        this.socket = socket;
        this.open = true;
        socket.on("data", (chunk) => this.feed(chunk));
        socket.once("error", (err) => this.fail(err));
        socket.once("close", () => this.emitClose());
        if (head.length > 0) this.feed(head);
        if (!settled) {
          settled = true;
          resolve();
        }
        this.emit("open");
      });
      req.end();
    });
  }

  sendText(text) {
    if (!this.open || this.socket === null || this.closed) {
      throw new Error("Codex WebSocket is not open");
    }
    this.socket.write(encodeClientFrame(0x1, Buffer.from(text, "utf8")));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.open = false;
    if (this.socket !== null && !this.socket.destroyed) {
      this.socket.write(encodeClientFrame(0x8));
      this.socket.end();
    } else {
      this.request?.destroy();
      this.emitClose();
    }
  }

  fail(err) {
    if (!this.closed) this.emit("error", err);
    this.closed = true;
    this.open = false;
    this.request?.destroy();
    this.socket?.destroy();
    this.emitClose();
  }

  emitClose() {
    if (this.closeEmitted) return;
    this.closeEmitted = true;
    this.open = false;
    this.closed = true;
    this.emit("close");
  }

  feed(chunk) {
    if (this.closed) return;
    this.buffer =
      this.buffer.length === 0
        ? Buffer.from(chunk)
        : Buffer.concat([this.buffer, chunk]);
    try {
      while (this.consumeFrame()) {
        // Drain every complete frame already buffered.
      }
    } catch (err) {
      this.fail(err instanceof Error ? err : new Error(String(err)));
    }
  }

  consumeFrame() {
    if (this.buffer.length < 2) return false;
    const first = this.buffer[0];
    const second = this.buffer[1];
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    if ((first & 0x70) !== 0)
      throw new Error("unsupported WebSocket extension bits");
    if (masked) throw new Error("Codex WebSocket server sent a masked frame");

    let length = second & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (this.buffer.length < 4) return false;
      length = this.buffer.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (this.buffer.length < 10) return false;
      const wide = this.buffer.readBigUInt64BE(2);
      if (wide > BigInt(MAX_MESSAGE_BYTES)) {
        throw new Error("Codex WebSocket message exceeds 16 MiB");
      }
      length = Number(wide);
      offset = 10;
    }
    if (
      length > MAX_MESSAGE_BYTES ||
      this.fragmentBytes + length > MAX_MESSAGE_BYTES
    ) {
      throw new Error("Codex WebSocket message exceeds 16 MiB");
    }
    if (this.buffer.length < offset + length) return false;
    const payload = this.buffer.subarray(offset, offset + length);
    this.buffer = this.buffer.subarray(offset + length);

    if (opcode >= 0x8) {
      if (!fin || length > 125)
        throw new Error("invalid WebSocket control frame");
      if (opcode === 0x8) {
        if (!this.closed && this.socket !== null) {
          this.socket.write(encodeClientFrame(0x8, payload));
        }
        this.socket?.end();
        this.emitClose();
      } else if (opcode === 0x9) {
        this.socket?.write(encodeClientFrame(0xa, payload));
      }
      return true;
    }

    if (opcode === 0x1 || opcode === 0x2) {
      if (this.fragmentOpcode !== null) {
        throw new Error(
          "received a new WebSocket message before continuation completed",
        );
      }
      if (fin) {
        this.emitMessage(opcode, payload);
      } else {
        this.fragmentOpcode = opcode;
        this.fragments = [Buffer.from(payload)];
        this.fragmentBytes = payload.length;
      }
      return true;
    }

    if (opcode === 0x0) {
      if (this.fragmentOpcode === null)
        throw new Error("unexpected WebSocket continuation");
      this.fragments.push(Buffer.from(payload));
      this.fragmentBytes += payload.length;
      if (fin) {
        const messageOpcode = this.fragmentOpcode;
        const message = Buffer.concat(this.fragments, this.fragmentBytes);
        this.fragmentOpcode = null;
        this.fragments = [];
        this.fragmentBytes = 0;
        this.emitMessage(messageOpcode, message);
      }
      return true;
    }

    throw new Error(`unsupported WebSocket opcode ${opcode}`);
  }

  emitMessage(opcode, payload) {
    if (opcode !== 0x1) {
      throw new Error("Codex WebSocket sent a non-text message");
    }
    this.emit("message", payload.toString("utf8"));
  }
}
