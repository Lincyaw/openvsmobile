// A Connection is an authenticated subscriber over a single WebSocket.
// It does NOT own workspaces or terminals — those live in the shared
// ProcessState. Closing the socket removes this subscriber but leaves all
// workspaces and PTYs running so the client can reattach on reconnect.
//
// This file is the ONLY one that knows WebSocket framing. The JSON-RPC
// method table + handler bodies live in rpc.ts; we just shuttle parsed
// requests into `dispatch()` and write the response back. See
// docs/conventions.md §1 "Method dispatch lives in rpc.ts".
//
// See docs/design/mobile-code-platform.md §5.1 (Session persistence).

import type { WebSocket } from "ws";
import {
  dispatch,
  METHOD_AUTH_HANDSHAKE,
  parseRequest,
  runAuthHandshake,
  RPC_ERR,
  RpcError,
  sendError,
  sendResult,
  type JsonRpcId,
  type RpcContext,
} from "./rpc.js";
import type { ProcessState, Subscriber } from "./state.js";

export interface ConnectionDeps {
  expectedToken: string;
  serverVersion: string;
  state: ProcessState;
}

export class Connection implements Subscriber {
  public readonly ws: WebSocket;
  /// Set during `auth.handshake` when the client supplies
  /// `client.deviceId`. Reads from `notification.markRead` use this as the
  /// reader id; absent clients get an ephemeral id at first markRead call.
  public notificationDeviceId?: string;
  /// Per-connection notification subscription. Off until the client calls
  /// `notification.subscribe`; fan-out helper in state.ts skips any
  /// subscriber where this is not strictly `true`.
  public notificationsSubscribed?: boolean;
  private readonly state: ProcessState;
  private readonly expectedToken: string;
  private readonly serverVersion: string;
  private authed = false;

  constructor(ws: WebSocket, deps: ConnectionDeps) {
    this.ws = ws;
    this.state = deps.state;
    this.expectedToken = deps.expectedToken;
    this.serverVersion = deps.serverVersion;

    ws.on("message", (raw) => {
      const text = typeof raw === "string" ? raw : raw.toString("utf8");
      void this.handleRaw(text);
    });
    // Critical: socket close does NOT dispose any state. PTYs and workspaces
    // keep running. We just unhook our notification fan-out target.
    ws.on("close", () => {
      this.state.removeSubscriber(this);
    });
    ws.on("error", () => {
      this.state.removeSubscriber(this);
    });
  }

  private context(): RpcContext {
    return {
      state: this.state,
      expectedToken: this.expectedToken,
      serverVersion: this.serverVersion,
      ws: this.ws,
      markAuthenticated: () => {
        if (this.authed) return;
        this.authed = true;
        // Register as a subscriber only after auth succeeds; pre-auth sockets
        // must never receive notifications.
        this.state.addSubscriber(this);
      },
      // The Connection itself implements Subscriber, so handlers can update
      // per-connection notification flags (subscribed / deviceId) by mutating
      // this object directly. Only visible to authenticated dispatch — pre-
      // auth handshake doesn't surface subscriber state to handlers.
      subscriber: this,
    };
  }

  private async handleRaw(raw: string): Promise<void> {
    const parsed = parseRequest(raw);
    if (parsed.kind === "error") {
      const code =
        parsed.reason === "parse" ? RPC_ERR.parse : RPC_ERR.invalidRequest;
      sendError(this.ws, null, code, parsed.reason);
      return;
    }
    const { id, method, params } = parsed.req;
    const ctx = this.context();
    if (method === METHOD_AUTH_HANDSHAKE) {
      await this.handleAuthHandshake(ctx, id, params);
      return;
    }
    if (!this.authed) {
      sendError(this.ws, id, RPC_ERR.unauthorized, "handshake required");
      return;
    }
    try {
      const result = await dispatch(ctx, parsed.req);
      sendResult(this.ws, id, result);
    } catch (err) {
      this.replyError(id, err);
    }
  }

  /// Handshake has one wrinkle the regular dispatch path lacks: a bad token
  /// must both reply with the error AND tear the socket down (the client has
  /// no recoverable path forward). We send the error first, then close once
  /// the frame has been flushed.
  private async handleAuthHandshake(
    ctx: RpcContext,
    id: JsonRpcId,
    params: unknown,
  ): Promise<void> {
    try {
      const result = runAuthHandshake(ctx, params);
      sendResult(this.ws, id, result);
    } catch (err) {
      if (err instanceof RpcError && err.code === RPC_ERR.unauthorized) {
        // Reply with the auth error, then close after the send completes so
        // the client sees the error frame instead of a bare 1008.
        if (this.ws.readyState === this.ws.OPEN) {
          const msg = JSON.stringify({
            jsonrpc: "2.0",
            id,
            error: { code: err.code, message: err.message },
          });
          this.ws.send(msg, () => {
            try {
              this.ws.close(1008, "auth");
            } catch {
              // Already closing.
            }
          });
        }
        return;
      }
      this.replyError(id, err);
    }
  }

  private replyError(id: JsonRpcId, err: unknown): void {
    if (err instanceof RpcError) {
      sendError(this.ws, id, err.code, err.message, err.data);
      return;
    }
    const message = err instanceof Error ? err.message : String(err);
    sendError(this.ws, id, RPC_ERR.internal, message);
  }
}
