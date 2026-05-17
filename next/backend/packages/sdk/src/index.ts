// @openvsmobile/sdk — node-side helper for plugin authors.
//
// Per CLAUDE.md, node plugins may only import `@openvsmobile/sdk` and
// Node built-ins. This package's job is to make that import enough: it
// wraps the stdio JSON-RPC framing and exports typed constructors for
// the §4.3 UI widget vocabulary so a plugin's `index.js` reads as
// business logic rather than wire-protocol glue.
//
// Wire-shape decisions worth knowing:
//
//   * Outbound framing is newline-delimited JSON. The backend's
//     FrameCodec auto-detects on the first non-whitespace byte; emitting
//     a single character of NDJSON pins us into newline mode for the
//     lifetime of the channel. Content-Length framing is an option for
//     binary-kind plugins that want it; node plugins gain nothing from
//     it.
//   * Host → plugin requests we honor: `command.invoke` (per §3.6
//     activation handoff) and `ui.event` (per §4.3 user-interaction
//     fan-in). Anything else gets a `methodNotFound` reply so a future
//     host RPC can't fail silently on the plugin side.
//   * Plugin → host requests we issue: `host.log` (always allowed),
//     `ui.render` (gated by manifest `capabilities.ui`),
//     `plugin.invokeCommand` (gated by the host as a cross-plugin call,
//     wired here so the SDK contract stands even though no test
//     exercises that path yet).
//   * `run()` does not block. It wires stdin listeners, kicks off
//     `onActivate` as a microtask, and returns. The plugin's process
//     stays alive because of the stdin `data` listener; when the host
//     closes stdin the event loop drains and the plugin exits.

import { randomUUID } from "node:crypto";
import { Buffer } from "node:buffer";

// ---------------------------------------------------------------------
// Widget vocabulary — mirrors `next/backend/src/plugins/ui.ts` so a
// tree built with these constructors validates cleanly on the host
// side. Field names are passed through verbatim; nothing the host
// rejects can be encoded here.
// ---------------------------------------------------------------------

export type UiTextStyle = "body" | "title" | "caption" | "mono";
export type UiButtonStyle = "primary" | "secondary" | "danger";

export interface UiColumn {
  kind: "Column";
  id: string;
  children: UiNode[];
  gap?: number;
}
export interface UiRow {
  kind: "Row";
  id: string;
  children: UiNode[];
  gap?: number;
}
export interface UiSection {
  kind: "Section";
  id: string;
  title?: string;
  children: UiNode[];
}
export interface UiCard {
  kind: "Card";
  id: string;
  children: UiNode[];
}
export interface UiList {
  kind: "List";
  id: string;
  items: UiNode[];
}
export interface UiText {
  kind: "Text";
  id: string;
  text: string;
  style?: UiTextStyle;
}
export interface UiSpacer {
  kind: "Spacer";
  id: string;
  size?: number;
}
export interface UiTextField {
  kind: "TextField";
  id: string;
  label?: string;
  value?: string;
  placeholder?: string;
}
export interface UiButton {
  kind: "Button";
  id: string;
  label: string;
  style?: UiButtonStyle;
}

export type UiNode =
  | UiColumn
  | UiRow
  | UiSection
  | UiCard
  | UiList
  | UiText
  | UiSpacer
  | UiTextField
  | UiButton;

/// Constructors mirroring the §4.3 widget vocabulary. IDs may be
/// omitted; an omitted id is replaced with `crypto.randomUUID()` so the
/// host's "every node must have a unique id" validation always
/// succeeds. When the plugin author supplies an id it is passed through
/// verbatim — that is the only way to keep focus / scroll state alive
/// across re-renders.
export const ui = {
  column(p: { id?: string; gap?: number; children: UiNode[] }): UiColumn {
    const out: UiColumn = {
      kind: "Column",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.gap !== undefined) out.gap = p.gap;
    return out;
  },
  row(p: { id?: string; gap?: number; children: UiNode[] }): UiRow {
    const out: UiRow = {
      kind: "Row",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.gap !== undefined) out.gap = p.gap;
    return out;
  },
  section(p: {
    id?: string;
    title?: string;
    children: UiNode[];
  }): UiSection {
    const out: UiSection = {
      kind: "Section",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.title !== undefined) out.title = p.title;
    return out;
  },
  card(p: { id?: string; children: UiNode[] }): UiCard {
    return { kind: "Card", id: ensureId(p.id), children: p.children };
  },
  list(p: { id?: string; items: UiNode[] }): UiList {
    return { kind: "List", id: ensureId(p.id), items: p.items };
  },
  text(p: { id?: string; text: string; style?: UiTextStyle }): UiText {
    const out: UiText = { kind: "Text", id: ensureId(p.id), text: p.text };
    if (p.style !== undefined) out.style = p.style;
    return out;
  },
  spacer(p: { id?: string; size?: number } = {}): UiSpacer {
    const out: UiSpacer = { kind: "Spacer", id: ensureId(p.id) };
    if (p.size !== undefined) out.size = p.size;
    return out;
  },
  textField(
    p: {
      id?: string;
      label?: string;
      value?: string;
      placeholder?: string;
    } = {},
  ): UiTextField {
    const out: UiTextField = { kind: "TextField", id: ensureId(p.id) };
    if (p.label !== undefined) out.label = p.label;
    if (p.value !== undefined) out.value = p.value;
    if (p.placeholder !== undefined) out.placeholder = p.placeholder;
    return out;
  },
  button(p: {
    id?: string;
    label: string;
    style?: UiButtonStyle;
  }): UiButton {
    const out: UiButton = {
      kind: "Button",
      id: ensureId(p.id),
      label: p.label,
    };
    if (p.style !== undefined) out.style = p.style;
    return out;
  },
};

function ensureId(id: string | undefined): string {
  if (id !== undefined && id.length > 0) return id;
  return randomUUID();
}

// ---------------------------------------------------------------------
// Plugin runtime
// ---------------------------------------------------------------------

export type LogLevel = "info" | "warn" | "error";

export interface UiEventInput {
  panelId: string;
  nodeId: string;
  type: string;
  payload?: unknown;
}

export interface PluginContext {
  /// Send a `host.log` notification. Always allowed regardless of the
  /// manifest's capability set — the host log is the universal smoke
  /// signal for plugin debugging.
  log(level: LogLevel, msg: string): void;
  /// Replace the panel's tree with `tree`. Round-trips into a
  /// `ui.render` request on the host side. Requires the `ui` capability
  /// in the manifest; without it the host returns `-32011
  /// capabilityNotDeclared` and the call's promise (when the SDK uses
  /// the response path) would reject — today this is a fire-and-forget
  /// notification-shaped request, so the rejection surfaces on the next
  /// `ui.event` round-trip.
  renderPanel(panelId: string, tree: UiNode): void;
  /// Invoke a command on another plugin via the host. Returns the
  /// other plugin's result (or rejects with the host's JSON-RPC error).
  /// The host gates cross-plugin invocation; nothing in v0 wires the
  /// receiving side of `plugin.invokeCommand` from a plugin caller, so
  /// this method exists for API completeness — calling it today will
  /// likely reject with `methodNotFound` until the host adds dispatch.
  invokeCommand(
    targetPluginId: string,
    commandId: string,
    args?: unknown,
  ): Promise<unknown>;
}

export interface PluginConfig {
  /// Called once after the SDK has wired stdio. The activation hook is
  /// the canonical place to emit the plugin's first `ui.render`.
  onActivate?(ctx: PluginContext): void | Promise<void>;
  /// Invoked when the host dispatches `command.invoke`. Return value is
  /// echoed back in the JSON-RPC response so the caller can read it.
  onCommand?(
    ctx: PluginContext,
    commandId: string,
    args: unknown,
  ): unknown | Promise<unknown>;
  /// Invoked when the app pushes a `ui.event` at one of this plugin's
  /// panels. The host has already validated the event's plugin id and
  /// capability declaration; the SDK only adds field-shape checks.
  onUiEvent?(
    ctx: PluginContext,
    event: UiEventInput,
  ): void | Promise<void>;
}

export interface PluginRunOptions {
  /// Override the inbound stream. Defaults to `process.stdin`. Tests
  /// substitute a `PassThrough` so they can drive the SDK without
  /// forking a child process.
  stdin?: NodeJS.ReadableStream;
  /// Override the outbound stream. Defaults to `process.stdout`.
  stdout?: NodeJS.WritableStream;
}

export interface PluginRunner {
  run(opts?: PluginRunOptions): void;
}

/// Internal JSON-RPC message shape — exposed only for type-narrowing
/// inside the SDK; not exported.
interface JsonRpcMessage {
  jsonrpc: "2.0";
  id?: string | number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

const RPC_ERR_METHOD_NOT_FOUND = -32601;
const RPC_ERR_INVALID_PARAMS = -32602;
const RPC_ERR_INTERNAL = -32603;

/// Build a plugin runner from author-supplied lifecycle callbacks.
///
/// The runner is intentionally a thin layer over JSON-RPC: it knows
/// how to frame outbound messages, how to demux inbound requests vs.
/// responses, and which inbound methods map to which callback. It does
/// NOT try to be a UI reconciler or a state manager — re-renders are
/// the plugin author's job, exactly as the design doc spells out (§4.3,
/// "v0 full re-render reconciled by node id").
export function createPlugin(config: PluginConfig): PluginRunner {
  return {
    run(opts?: PluginRunOptions): void {
      const stdin = opts?.stdin ?? process.stdin;
      const stdout = opts?.stdout ?? process.stdout;

      let nextOutboundId = 1;
      const pendingInvokes = new Map<
        number,
        { resolve: (v: unknown) => void; reject: (e: Error) => void }
      >();

      function writeMessage(msg: JsonRpcMessage): void {
        stdout.write(JSON.stringify(msg) + "\n");
      }

      const ctx: PluginContext = {
        log(level, msg): void {
          // `host.log` is technically a notification per the wire
          // contract, but the host accepts a request id too — it just
          // replies `{}`. We omit the id to keep the channel quiet.
          writeMessage({
            jsonrpc: "2.0",
            method: "host.log",
            params: { level, msg },
          });
        },
        renderPanel(panelId, tree): void {
          // `ui.render` is request-shaped on the host side (the host
          // emits a response); but the plugin doesn't actually need
          // that response to function, so we drop the id and let the
          // host treat it as fire-and-forget.
          writeMessage({
            jsonrpc: "2.0",
            method: "ui.render",
            params: { panelId, tree },
          });
        },
        invokeCommand(targetPluginId, commandId, args): Promise<unknown> {
          return new Promise<unknown>((resolve, reject) => {
            const id = nextOutboundId++;
            pendingInvokes.set(id, { resolve, reject });
            writeMessage({
              jsonrpc: "2.0",
              id,
              method: "plugin.invokeCommand",
              params: { id: targetPluginId, commandId, args },
            });
          });
        },
      };

      // Inbound: newline-delimited JSON. The host's FrameCodec
      // auto-detects on our first byte, so as long as our first frame
      // is NDJSON every subsequent frame the host sends back will use
      // newline framing too.
      // Typed as `Buffer<ArrayBufferLike>` so chunks coming off
      // `stream.on("data")` — which are also `Buffer<ArrayBufferLike>` —
      // can be concatenated without TypeScript's recent
      // `ArrayBuffer` vs `ArrayBufferLike` narrowing kicking in.
      let buffer: Buffer<ArrayBufferLike> = Buffer.alloc(0);
      function feed(chunk: Buffer<ArrayBufferLike>): void {
        buffer =
          buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
        while (true) {
          const nl = buffer.indexOf(0x0a);
          if (nl === -1) return;
          let line = buffer.subarray(0, nl);
          buffer = buffer.subarray(nl + 1);
          if (line.length > 0 && line[line.length - 1] === 0x0d) {
            line = line.subarray(0, line.length - 1);
          }
          if (line.length === 0) continue;
          let parsed: unknown;
          try {
            parsed = JSON.parse(line.toString("utf8"));
          } catch {
            // Malformed frame — drop. The host's logger will surface
            // its own framing errors; we don't have a back-channel to
            // complain on without echoing stderr noise into the host's
            // captured log.
            continue;
          }
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            continue;
          }
          void handleInbound(parsed as JsonRpcMessage);
        }
      }

      async function handleInbound(msg: JsonRpcMessage): Promise<void> {
        // Response to a request we issued.
        if (msg.method === undefined) {
          if (typeof msg.id !== "number") return;
          const pending = pendingInvokes.get(msg.id);
          if (pending === undefined) return;
          pendingInvokes.delete(msg.id);
          if (msg.error !== undefined) {
            pending.reject(
              new Error(msg.error.message ?? "host returned error"),
            );
            return;
          }
          pending.resolve(msg.result);
          return;
        }

        // Host-initiated request.
        if (msg.method === "command.invoke") {
          if (config.onCommand === undefined) {
            respond(msg.id, {
              code: RPC_ERR_METHOD_NOT_FOUND,
              message: "plugin has no onCommand handler",
            });
            return;
          }
          const params = (msg.params ?? {}) as {
            id?: unknown;
            args?: unknown;
          };
          if (typeof params.id !== "string") {
            respond(msg.id, {
              code: RPC_ERR_INVALID_PARAMS,
              message: "command.invoke params.id must be a string",
            });
            return;
          }
          try {
            const result = await config.onCommand(ctx, params.id, params.args);
            respond(msg.id, undefined, result ?? {});
          } catch (err) {
            respond(msg.id, {
              code: RPC_ERR_INTERNAL,
              message: (err as Error).message,
            });
          }
          return;
        }

        if (msg.method === "ui.event") {
          // The host has already gated this on `capabilities.ui`. We
          // only add shape checks so a malformed payload surfaces as
          // `-32602` instead of crashing the callback.
          const params = (msg.params ?? {}) as Partial<UiEventInput>;
          if (
            typeof params.panelId !== "string" ||
            typeof params.nodeId !== "string" ||
            typeof params.type !== "string"
          ) {
            respond(msg.id, {
              code: RPC_ERR_INVALID_PARAMS,
              message:
                "ui.event params must include string panelId/nodeId/type",
            });
            return;
          }
          const event: UiEventInput = {
            panelId: params.panelId,
            nodeId: params.nodeId,
            type: params.type,
          };
          if (params.payload !== undefined) event.payload = params.payload;
          if (config.onUiEvent === undefined) {
            respond(msg.id, undefined, {});
            return;
          }
          try {
            await config.onUiEvent(ctx, event);
            respond(msg.id, undefined, {});
          } catch (err) {
            respond(msg.id, {
              code: RPC_ERR_INTERNAL,
              message: (err as Error).message,
            });
          }
          return;
        }

        // Any other inbound method — methodNotFound so the host knows
        // we deliberately don't handle it (vs. silently swallowing).
        respond(msg.id, {
          code: RPC_ERR_METHOD_NOT_FOUND,
          message: `plugin SDK does not handle method "${msg.method}"`,
        });
      }

      function respond(
        id: string | number | undefined,
        error?: { code: number; message: string },
        result?: unknown,
      ): void {
        if (id === undefined) return; // notification — no reply expected
        if (error !== undefined) {
          writeMessage({ jsonrpc: "2.0", id, error });
        } else {
          writeMessage({ jsonrpc: "2.0", id, result: result ?? {} });
        }
      }

      stdin.on("data", (chunk: Buffer | string) => {
        feed(
          typeof chunk === "string" ? Buffer.from(chunk, "utf8") : chunk,
        );
      });

      // Kick activation as a microtask so the caller's synchronous
      // `plugin.run()` returns first. This matches "fire and forget"
      // expectations from a typical plugin author.
      if (config.onActivate !== undefined) {
        const activate = config.onActivate;
        queueMicrotask(() => {
          void Promise.resolve()
            .then(() => activate(ctx))
            .catch((err: unknown) => {
              ctx.log(
                "error",
                `onActivate threw: ${(err as Error).message ?? String(err)}`,
              );
            });
        });
      }
    },
  };
}
