import { EventEmitter } from "node:events";

import { HeaderWebSocket } from "./websocket.js";

const REQUEST_TIMEOUT_MS = 30_000;

export class CodexRpcError extends Error {
  constructor(code, message, data = undefined) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export class CodexAppServerClient extends EventEmitter {
  constructor({
    endpoint,
    bearerToken = "",
    requestTimeoutMs = REQUEST_TIMEOUT_MS,
  }) {
    super();
    this.endpoint = endpoint;
    this.bearerToken = bearerToken;
    this.requestTimeoutMs = requestTimeoutMs;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.connected = false;
    this.closedByClient = false;
  }

  async connect() {
    const socket = new HeaderWebSocket(this.endpoint, {
      bearerToken: this.bearerToken,
    });
    this.socket = socket;
    socket.on("message", (text) => this.onMessage(text));
    socket.on("error", (err) => this.emit("error", err));
    socket.on("close", () => {
      this.connected = false;
      this.rejectPending(new Error("Codex app-server connection closed"));
      this.emit("close", { intentional: this.closedByClient });
    });
    await socket.connect();
    this.connected = true;
  }

  request(method, params = {}) {
    if (!this.connected || this.socket === null) {
      return Promise.reject(new Error("Codex app-server is not connected"));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex request timed out: ${method}`));
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      try {
        this.send({ method, id, params });
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err);
      }
    });
  }

  notify(method, params = {}) {
    this.send({ method, params });
  }

  respond(id, result) {
    this.send({ id, result });
  }

  respondError(id, code, message, data = undefined) {
    const error = { code, message };
    if (data !== undefined) error.data = data;
    this.send({ id, error });
  }

  close() {
    this.closedByClient = true;
    this.connected = false;
    this.socket?.close();
    this.rejectPending(new Error("Codex app-server client closed"));
  }

  send(message) {
    if (this.socket === null) throw new Error("Codex WebSocket is unavailable");
    this.socket.sendText(JSON.stringify(message));
  }

  onMessage(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.emit("error", new Error("Codex app-server sent invalid JSON"));
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message))
      return;

    if (message.method !== undefined) {
      if (typeof message.method !== "string") return;
      if (message.id !== undefined) this.emit("request", message);
      else this.emit("notification", message);
      return;
    }

    if (typeof message.id !== "number") return;
    const pending = this.pending.get(message.id);
    if (pending === undefined) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.error && typeof message.error === "object") {
      pending.reject(
        new CodexRpcError(
          typeof message.error.code === "number" ? message.error.code : -32603,
          typeof message.error.message === "string"
            ? message.error.message
            : `${pending.method} failed`,
          message.error.data,
        ),
      );
      return;
    }
    pending.resolve(message.result);
  }

  rejectPending(err) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(err);
    }
    this.pending.clear();
  }
}
