// `auth.publishTokens.*` admin RPCs. All four require an authenticated WS
// connection (which can only be reached via the `auth` token from
// config.json — publish tokens never authenticate on /rpc). Surfaces the
// TokenStore mutators to the Flutter Settings UI.
//
// See docs/design/mobile-code-platform.md §4.5 ("Auth and publish tokens").

import {
  asBag,
  optionalString,
  optionalPositiveInt,
  requireString,
  RPC_ERR,
  RpcError,
  type MethodRegistry,
} from "../rpc.js";
import { TokenError } from "../tokenStore.js";

export const METHOD_PUBLISH_TOKENS_LIST = "auth.publishTokens.list";
export const METHOD_PUBLISH_TOKENS_CREATE = "auth.publishTokens.create";
export const METHOD_PUBLISH_TOKENS_REVOKE = "auth.publishTokens.revoke";
export const METHOD_PUBLISH_TOKENS_RELABEL = "auth.publishTokens.relabel";

function wrapTokenError(err: unknown): never {
  if (err instanceof TokenError) {
    // All `invalid-args` paths surface as JSON-RPC invalidParams. Other
    // codes only ever come from sender endpoints (lookup/source/rate),
    // not from admin RPCs.
    if (err.code === "invalid-args") {
      throw new RpcError(RPC_ERR.invalidParams, err.message);
    }
  }
  throw err;
}

export function register(methods: MethodRegistry): void {
  methods.set(METHOD_PUBLISH_TOKENS_LIST, (ctx, params) => {
    const p = asBag(params);
    const includeRevoked = p.includeRevoked === true;
    const items = ctx.state.tokenStore.list({ includeRevoked });
    return { items };
  });

  methods.set(METHOD_PUBLISH_TOKENS_CREATE, (ctx, params) => {
    const p = asBag(params);
    const label = requireString(p, "label");
    const sourcePrefix = optionalString(p, "sourcePrefix");
    const rateLimitPerMin = optionalPositiveInt(p, "rateLimitPerMin");
    const rateLimitPerHour = optionalPositiveInt(p, "rateLimitPerHour");
    try {
      const mintOpts: Parameters<typeof ctx.state.tokenStore.mint>[0] = {
        label,
      };
      if (sourcePrefix !== undefined) mintOpts.sourcePrefix = sourcePrefix;
      if (rateLimitPerMin !== undefined) {
        mintOpts.rateLimitPerMin = rateLimitPerMin;
      }
      if (rateLimitPerHour !== undefined) {
        mintOpts.rateLimitPerHour = rateLimitPerHour;
      }
      const { id, token } = ctx.state.tokenStore.mint(mintOpts);
      // Read the freshly-inserted row so the caller gets the same shape
      // `list()` returns and can append it to a cached UI list without
      // re-fetching. `secret` is the only field returned exactly once.
      const record = ctx.state.tokenStore
        .list({ includeRevoked: false })
        .find((r) => r.id === id);
      return { record, secret: token };
    } catch (err) {
      wrapTokenError(err);
    }
  });

  methods.set(METHOD_PUBLISH_TOKENS_REVOKE, (ctx, params) => {
    const p = asBag(params);
    const id = requireString(p, "id");
    const revoked = ctx.state.tokenStore.revoke(id);
    return { revoked };
  });

  methods.set(METHOD_PUBLISH_TOKENS_RELABEL, (ctx, params) => {
    const p = asBag(params);
    const id = requireString(p, "id");
    const label = requireString(p, "label");
    try {
      const ok = ctx.state.tokenStore.relabel(id, label);
      return { ok };
    } catch (err) {
      wrapTokenError(err);
    }
  });
}
