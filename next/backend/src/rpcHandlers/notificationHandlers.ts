// `notification.*` JSON-RPC handlers extracted out of rpc.ts. Pure move —
// no logic changes from the prior inline implementation. Registered via
// `register(methods)` from rpc.ts; the methods table itself stays private
// to rpc.ts.

import { randomUUID } from "node:crypto";
import type { ProcessState } from "../state.js";
import {
  asBag,
  optionalBool,
  optionalNonNegativeInt,
  optionalString,
  requireString,
  requireStringArray,
  requireSubscriber,
  RPC_ERR,
  RpcError,
  type MethodRegistry,
  type RpcContext,
} from "../rpc.js";

export const METHOD_NOTIFICATION_SUBSCRIBE = "notification.subscribe";
export const METHOD_NOTIFICATION_UNSUBSCRIBE = "notification.unsubscribe";
export const METHOD_NOTIFICATION_LIST = "notification.list";
export const METHOD_NOTIFICATION_MARK_READ = "notification.markRead";
export const METHOD_NOTIFICATION_DELETE = "notification.delete";
export const METHOD_NOTIFICATION_MARK_IMPORTANT = "notification.markImportant";

export function register(methods: MethodRegistry): void {
  methods.set(METHOD_NOTIFICATION_SUBSCRIBE, (ctx) => {
    const sub = requireSubscriber(ctx);
    sub.notificationsSubscribed = true;
    return { ok: true };
  });

  methods.set(METHOD_NOTIFICATION_UNSUBSCRIBE, (ctx) => {
    const sub = requireSubscriber(ctx);
    sub.notificationsSubscribed = false;
    return { ok: true };
  });

  methods.set(METHOD_NOTIFICATION_LIST, (ctx, params) => {
    const p = asBag(params);
    const since = optionalNonNegativeInt(p, "since");
    const source = optionalString(p, "source");
    const includeRead = optionalBool(p, "includeRead");
    const limitRaw = p.limit;
    let limit = 50;
    if (limitRaw !== undefined && limitRaw !== null) {
      if (
        typeof limitRaw !== "number" ||
        !Number.isInteger(limitRaw) ||
        limitRaw < 1 ||
        limitRaw > 500
      ) {
        throw new RpcError(
          RPC_ERR.invalidParams,
          "limit must be an integer in [1, 500]",
        );
      }
      limit = limitRaw;
    }
    const query: Parameters<ProcessState["notificationHub"]["list"]>[0] = {
      limit,
    };
    if (since !== undefined) query.since = since;
    if (source !== undefined) query.source = source;
    if (includeRead !== undefined) query.includeRead = includeRead;
    // Pass the caller's deviceId through so the store can apply
    // `includeRead=false` as a per-device filter. Subscriber is always
    // present on authenticated dispatch.
    const sub = ctx.subscriber;
    if (sub?.notificationDeviceId !== undefined) {
      query.deviceId = sub.notificationDeviceId;
    }
    return ctx.state.notificationHub.list(query);
  });

  methods.set(METHOD_NOTIFICATION_MARK_READ, (ctx: RpcContext, params) => {
    const p = asBag(params);
    const ids = requireStringArray(p, "ids");
    const sub = requireSubscriber(ctx);
    // Old clients that didn't supply client.deviceId on handshake get an
    // ephemeral id at subscription time so their reads still hit the DB.
    // Acceptable transition (see task brief §5).
    if (sub.notificationDeviceId === undefined) {
      sub.notificationDeviceId = `ephemeral-${randomUUID()}`;
    }
    ctx.state.notificationHub.markRead(ids, sub.notificationDeviceId);
    return { ok: true };
  });

  methods.set(METHOD_NOTIFICATION_DELETE, (ctx, params) => {
    const p = asBag(params);
    const ids = requireStringArray(p, "ids");
    ctx.state.notificationHub.delete(ids);
    return { ok: true };
  });

  methods.set(METHOD_NOTIFICATION_MARK_IMPORTANT, (ctx, params) => {
    const p = asBag(params);
    const id = requireString(p, "id");
    const importantRaw = p.important;
    if (typeof importantRaw !== "boolean") {
      throw new RpcError(RPC_ERR.invalidParams, "important must be a boolean");
    }
    // Symmetric with `notification.delete`: unknown ids are silently
    // swallowed (probably already GC'd or never existed on this backend).
    // Returning `{ ok: true }` lets clients fire-and-forget without needing
    // per-call error handling.
    ctx.state.notificationHub.markImportant(id, importantRaw);
    return { ok: true };
  });
}
