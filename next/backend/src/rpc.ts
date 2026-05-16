// Minimal JSON-RPC 2.0 framing on top of a WebSocket.

import type { WebSocket } from "ws";

export type JsonRpcId = string | number;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface JsonRpcSuccess {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result: unknown;
}

export interface JsonRpcError {
  jsonrpc: "2.0";
  id: JsonRpcId | null;
  error: { code: number; message: string; data?: unknown };
}

export const RPC_ERR = {
  parse: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internal: -32603,
  // Custom range
  capabilityDenied: -32001,
  unauthorized: -32002,
  notReady: -32003,
} as const;

export class RpcError extends Error {
  public readonly code: number;
  public readonly data: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export function sendNotification(
  ws: WebSocket,
  method: string,
  params: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcNotification = { jsonrpc: "2.0", method, params };
  ws.send(JSON.stringify(msg));
}

export function sendResult(
  ws: WebSocket,
  id: JsonRpcId,
  result: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcSuccess = { jsonrpc: "2.0", id, result };
  ws.send(JSON.stringify(msg));
}

export function sendError(
  ws: WebSocket,
  id: JsonRpcId | null,
  code: number,
  message: string,
  data?: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcError = {
    jsonrpc: "2.0",
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  };
  ws.send(JSON.stringify(msg));
}

export function parseRequest(
  raw: string,
): { kind: "request"; req: JsonRpcRequest } | { kind: "error"; reason: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { kind: "error", reason: "parse" };
  }
  if (
    !parsed ||
    typeof parsed !== "object" ||
    (parsed as { jsonrpc?: unknown }).jsonrpc !== "2.0"
  ) {
    return { kind: "error", reason: "invalidRequest" };
  }
  const obj = parsed as Record<string, unknown>;
  if (typeof obj.method !== "string") {
    return { kind: "error", reason: "invalidRequest" };
  }
  if (obj.id === undefined) {
    // Notification from client — we don't accept any in v0, but parse cleanly.
    return {
      kind: "request",
      req: {
        jsonrpc: "2.0",
        id: 0,
        method: obj.method,
        params: obj.params,
      },
    };
  }
  if (typeof obj.id !== "string" && typeof obj.id !== "number") {
    return { kind: "error", reason: "invalidRequest" };
  }
  return {
    kind: "request",
    req: {
      jsonrpc: "2.0",
      id: obj.id,
      method: obj.method,
      params: obj.params,
    },
  };
}
