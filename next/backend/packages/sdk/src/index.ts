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

// ---- StyleSlot tokens (Batch 1 — §4.3 cross-cutting principles) ----
//
// Plugin authors pick from a small named set instead of hard-coding
// numbers / hex colors. The Flutter host owns the pixel/color mapping; the
// SDK only exports the names so authors get autocomplete and the wire
// format is forward-compatible (the host can re-tune density without
// re-shipping plugins).
//
// `gap` / `size` on existing widgets continues to accept a raw number for
// one minor version — see the constructors below — but new code should
// prefer the named tokens.

/// Spacing scale shared by gap / padding / spacer.
export type SpacingToken = "none" | "xs" | "sm" | "md" | "lg" | "xl";
/// Corner radius scale.
export type RadiusToken = "none" | "sm" | "md" | "lg" | "pill";
/// Container background tier — see §4.3 cross-cutting principles.
export type SurfaceToken = "default" | "elevated" | "muted" | "inverse";
/// Semantic accent / brand color. `brand` resolves to the plugin's
/// `themeColor` if declared, falling back to the app brand.
export type AccentToken =
  | "brand"
  | "info"
  | "success"
  | "warning"
  | "danger"
  | "muted";
/// Icon / avatar / hit-target size buckets.
export type SizeToken = "xs" | "sm" | "md" | "lg" | "xl";

/// `StyleSlot` is the union of "raw pixel/color value" and "named token".
/// Numbers stay accepted for back-compat (existing `gap: 8` keeps working)
/// while new code can write `gap: "sm"`. Renderer resolves both.
export type StyleSlot<TToken extends string> = number | TToken;

export interface UiColumn {
  kind: "Column";
  id: string;
  children: UiNode[];
  gap?: StyleSlot<SpacingToken>;
}
export interface UiRow {
  kind: "Row";
  id: string;
  children: UiNode[];
  gap?: StyleSlot<SpacingToken>;
}
/// Container with three visual variants (Batch 2 — §4.3):
///   * `plain` (default) — no surface, just title + children stacked
///   * `card` — Material-flavor rounded card with subtle border
///   * `inset` — iOS Settings inset-grouped: one rounded surface with
///     dividers between rows; title rendered above in caption type
/// Omitted = plain so pre-Batch-2 callers keep rendering identically.
export type UiSectionVariant = "plain" | "card" | "inset";
export interface UiSection {
  kind: "Section";
  id: string;
  title?: string;
  variant?: UiSectionVariant;
  children: UiNode[];
}
/// Deprecated alias for `UiSection { variant: "card" }`. Kept for one
/// minor version so existing example plugins (clock / notes / sysinfo /
/// hello) keep rendering; new code should emit a Section directly.
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
  size?: StyleSlot<SpacingToken>;
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

// ---- Batch 1 new widgets (§4.3) ----

export interface UiIcon {
  kind: "Icon";
  id: string;
  /// Feather glyph name (see `next/app/lib/ui/icon_catalog.dart`). Unknown
  /// names render a placeholder so a typo never crashes the panel.
  name: string;
  size?: StyleSlot<SizeToken>;
  accent?: AccentToken;
}

export type UiBadgeVariant = "dot" | "pill";

export interface UiBadge {
  kind: "Badge";
  id: string;
  text?: string;
  count?: number;
  accent?: AccentToken;
  variant: UiBadgeVariant;
}

/// Plumbed-but-not-rendered in Batch 1 — Batch 4 lights this up.
/// Field shape mirrors the doc spec: `label` + `eventId`, optional
/// `icon` (Feather catalog name) + `accent`.
export interface UiSwipeAction {
  label: string;
  icon?: string;
  accent?: AccentToken;
  eventId: string;
}

export interface UiListTile {
  kind: "ListTile";
  id: string;
  title: string;
  subtitle?: string;
  leading?: UiNode;
  trailing?: UiNode;
  onTapEvent?: string;
  swipeActions?: UiSwipeAction[];
}

/// Compact tile-corner badge for [UiAppTile]. The full [UiBadge] widget
/// is overkill for the launcher's corner indicator; the doc spec uses
/// this slimmed shape ({ count?, text? }) so plugins don't have to
/// declare a full badge node off the main tree.
export interface UiAppTileBadge {
  count?: number;
  text?: string;
}

export interface UiAppTile {
  id: string;
  name: string;
  /// Either a Feather catalog name or an opaque `{ uri }` reference.
  /// v0 renderer honors the catalog-name form; `{ uri }` is the
  /// controlled escape hatch for "every plugin gets a real-looking
  /// app icon on the launcher" (only valid on `UiAppGrid` tiles).
  icon: string | { uri: string };
  badge?: UiAppTileBadge;
  accent?: AccentToken;
}

export interface UiAppGrid {
  kind: "AppGrid";
  id: string;
  items: UiAppTile[];
  columns?: number;
  onLaunchEvent?: string;
}

// ---- Batch 2 new widgets (§4.3) ----

/// Two-state toggle. The plugin owns canonical state; the host fires
/// `onChangeEvent` with `payload: { value: boolean }` the instant the
/// user flips it. The renderer applies the new value optimistically so
/// the thumb follows the gesture; the plugin's next render is
/// authoritative.
export interface UiSwitch {
  kind: "Switch";
  id: string;
  label?: string;
  value: boolean;
  onChangeEvent?: string;
}

export interface UiSelectOption {
  value: string;
  label: string;
}

/// Single-choice picker. Always renders as a modal bottom-sheet picker
/// on mobile — no dropdown menus, by spec. The host fires
/// `onChangeEvent` with `payload: { value: string }` once the user
/// commits a pick.
export interface UiSelect {
  kind: "Select";
  id: string;
  label?: string;
  options: UiSelectOption[];
  value?: string;
  onChangeEvent?: string;
}

/// Accent for [UiInlineBanner] — narrower than the full [AccentToken]
/// union because `brand` / `muted` don't carry a "you should notice
/// this" meaning.
export type UiInlineBannerAccent = "info" | "success" | "warning" | "danger";
export interface UiInlineBannerAction {
  label: string;
  eventId: string;
}
export interface UiInlineBanner {
  kind: "Banner";
  id: string;
  title: string;
  body?: string;
  accent: UiInlineBannerAccent;
  action?: UiInlineBannerAction;
  /// Optional dismiss eventId. When set the renderer shows a close
  /// affordance and fires this event on tap; the plugin's next render
  /// removes the banner.
  dismissEventId?: string;
}

export type UiDividerOrientation = "horizontal" | "vertical";
/// Explicit divider. The inset section variant already paints its own
/// internal separators; this widget is for outside that context.
export interface UiDivider {
  kind: "Divider";
  id: string;
  orientation?: UiDividerOrientation;
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
  | UiButton
  | UiIcon
  | UiBadge
  | UiListTile
  | UiAppGrid
  | UiSwitch
  | UiSelect
  | UiInlineBanner
  | UiDivider;

/// Constructors mirroring the §4.3 widget vocabulary. IDs may be
/// omitted; an omitted id is replaced with `crypto.randomUUID()` so the
/// host's "every node must have a unique id" validation always
/// succeeds. When the plugin author supplies an id it is passed through
/// verbatim — that is the only way to keep focus / scroll state alive
/// across re-renders.
export const ui = {
  column(p: {
    id?: string;
    gap?: StyleSlot<SpacingToken>;
    children: UiNode[];
  }): UiColumn {
    const out: UiColumn = {
      kind: "Column",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.gap !== undefined) out.gap = p.gap;
    return out;
  },
  row(p: {
    id?: string;
    gap?: StyleSlot<SpacingToken>;
    children: UiNode[];
  }): UiRow {
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
    variant?: UiSectionVariant;
    children: UiNode[];
  }): UiSection {
    const out: UiSection = {
      kind: "Section",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.title !== undefined) out.title = p.title;
    if (p.variant !== undefined) out.variant = p.variant;
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
  spacer(p: { id?: string; size?: StyleSlot<SpacingToken> } = {}): UiSpacer {
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
  icon(p: {
    id?: string;
    name: string;
    size?: StyleSlot<SizeToken>;
    accent?: AccentToken;
  }): UiIcon {
    const out: UiIcon = { kind: "Icon", id: ensureId(p.id), name: p.name };
    if (p.size !== undefined) out.size = p.size;
    if (p.accent !== undefined) out.accent = p.accent;
    return out;
  },
  badge(p: {
    id?: string;
    text?: string;
    count?: number;
    accent?: AccentToken;
    variant?: UiBadgeVariant;
  }): UiBadge {
    const out: UiBadge = {
      kind: "Badge",
      id: ensureId(p.id),
      variant: p.variant ?? "pill",
    };
    if (p.text !== undefined) out.text = p.text;
    if (p.count !== undefined) out.count = p.count;
    if (p.accent !== undefined) out.accent = p.accent;
    return out;
  },
  listTile(p: {
    id?: string;
    title: string;
    subtitle?: string;
    leading?: UiNode;
    trailing?: UiNode;
    onTapEvent?: string;
    swipeActions?: UiSwipeAction[];
  }): UiListTile {
    const out: UiListTile = {
      kind: "ListTile",
      id: ensureId(p.id),
      title: p.title,
    };
    if (p.subtitle !== undefined) out.subtitle = p.subtitle;
    if (p.leading !== undefined) out.leading = p.leading;
    if (p.trailing !== undefined) out.trailing = p.trailing;
    if (p.onTapEvent !== undefined) out.onTapEvent = p.onTapEvent;
    if (p.swipeActions !== undefined) out.swipeActions = p.swipeActions;
    return out;
  },
  appGrid(p: {
    id?: string;
    items: UiAppTile[];
    columns?: number;
    onLaunchEvent?: string;
  }): UiAppGrid {
    const out: UiAppGrid = {
      kind: "AppGrid",
      id: ensureId(p.id),
      items: p.items,
    };
    if (p.columns !== undefined) out.columns = p.columns;
    if (p.onLaunchEvent !== undefined) out.onLaunchEvent = p.onLaunchEvent;
    return out;
  },
  // `switch` is a TS reserved word — `toggle` is the natural alternative
  // and matches the doc-spec aside ("was UiToggle"). Plugins read
  // `ui.toggle({ ... })`; the wire kind stays `Switch`.
  toggle(p: {
    id?: string;
    label?: string;
    value: boolean;
    onChangeEvent?: string;
  }): UiSwitch {
    const out: UiSwitch = {
      kind: "Switch",
      id: ensureId(p.id),
      value: p.value,
    };
    if (p.label !== undefined) out.label = p.label;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  select(p: {
    id?: string;
    label?: string;
    options: UiSelectOption[];
    value?: string;
    onChangeEvent?: string;
  }): UiSelect {
    const out: UiSelect = {
      kind: "Select",
      id: ensureId(p.id),
      options: p.options,
    };
    if (p.label !== undefined) out.label = p.label;
    if (p.value !== undefined) out.value = p.value;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  banner(p: {
    id?: string;
    title: string;
    body?: string;
    accent: UiInlineBannerAccent;
    action?: UiInlineBannerAction;
    dismissEventId?: string;
  }): UiInlineBanner {
    const out: UiInlineBanner = {
      kind: "Banner",
      id: ensureId(p.id),
      title: p.title,
      accent: p.accent,
    };
    if (p.body !== undefined) out.body = p.body;
    if (p.action !== undefined) out.action = p.action;
    if (p.dismissEventId !== undefined) out.dismissEventId = p.dismissEventId;
    return out;
  },
  divider(p: { id?: string; orientation?: UiDividerOrientation } = {}): UiDivider {
    const out: UiDivider = { kind: "Divider", id: ensureId(p.id) };
    if (p.orientation !== undefined) out.orientation = p.orientation;
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
