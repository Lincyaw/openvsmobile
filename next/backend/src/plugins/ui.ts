// UI descriptor protocol (issue #59, design §4.3).
//
// Plugins describe their UI as a typed widget tree (`UiNode`). The host
// keeps a per-(pluginId, panelId) cache of the latest tree + a monotonic
// version counter; subscribed clients receive a `ui.tree` push whenever
// the cache changes.
//
// Decisions worth knowing before reading further:
//
//   * The version counter is scoped to a single (pluginId, panelId) pair.
//     Two panels live on independent counters; one panel's retire / re-
//     render cycle does not perturb another's stream.
//   * `retirePlugin` is called by the host on plugin exit / disable. It
//     emits one final `ui.tree` push per panel with `tree: null` so the
//     app drops its cached UI, then deletes the panel — there's no
//     auto-restart so the panel is gone for good.
//   * Subscriptions are a flat set of WebSockets. v0 fans out every
//     `ui.tree` push to every subscriber; per-panel subscription scopes
//     are reserved for the Plugins-tab work in C4.
//   * Validation is strict on what plugins send (mandatory unique ids,
//     known `kind` values, type-checked fields) — a malformed tree is a
//     plugin-author bug and surfaces as `-32602 invalidParams` per the
//     issue spec rather than getting silently rendered as garbage.

import type { WebSocket } from "ws";

export type UiTextStyle = "body" | "title" | "caption" | "mono";
export type UiButtonStyle = "primary" | "secondary" | "danger";

// ---- StyleSlot tokens (Batch 1 — §4.3 cross-cutting principles) ----
//
// Mirrored on the SDK side as exported string-literal unions so plugin
// authors get autocomplete. The host accepts either a token name or a
// raw number for the back-compat one-minor-version window.

export type SpacingToken = "none" | "xs" | "sm" | "md" | "lg" | "xl";
export type RadiusToken = "none" | "sm" | "md" | "lg" | "pill";
export type SurfaceToken = "default" | "elevated" | "muted" | "inverse";
export type AccentToken =
  | "brand"
  | "info"
  | "success"
  | "warning"
  | "danger"
  | "muted";
export type SizeToken = "xs" | "sm" | "md" | "lg" | "xl";

export type StyleSlot<TToken extends string> = number | TToken;

const SPACING_TOKENS: ReadonlySet<string> = new Set([
  "none",
  "xs",
  "sm",
  "md",
  "lg",
  "xl",
]);
const SIZE_TOKENS: ReadonlySet<string> = new Set([
  "xs",
  "sm",
  "md",
  "lg",
  "xl",
]);
const ACCENT_TOKENS: ReadonlySet<string> = new Set([
  "brand",
  "info",
  "success",
  "warning",
  "danger",
  "muted",
]);
const BADGE_VARIANTS: ReadonlySet<string> = new Set(["dot", "pill"]);

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

// ---- Batch 1 new widgets ----

export interface UiIcon {
  kind: "Icon";
  id: string;
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

/// Doc-spec shape: `label` + `eventId`, optional `icon` (Feather name)
/// + `accent`. Plumbed-but-not-rendered in Batch 1; Batch 4 lights up
/// the gesture.
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

/// Compact tile-corner badge for [UiAppTile] — slim `{ count?, text? }`
/// shape from the doc spec, not the full [UiBadge] widget. Plain object
/// (no `kind`, no required `id`) because it lives off the main
/// reconciliation tree.
export interface UiAppTileBadge {
  count?: number;
  text?: string;
}

export interface UiAppTile {
  id: string;
  name: string;
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
  | UiAppGrid;

/// Thrown by `validateUiTree` for any structural problem (unknown kind,
/// missing required field, duplicate id). The host translates this into
/// an `-32602 invalidParams` JSON-RPC error.
export class UiValidationError extends Error {}

/// Walks `raw` recursively, checks every node against its kind's shape,
/// and asserts that every `id` is unique across the entire tree. Returns
/// the typed tree on success; throws `UiValidationError` on the first
/// problem (no batched diagnostics — the plugin author needs *some* error
/// to start from, and listing every problem at once would obscure the root
/// cause behind cascading errors).
export function validateUiTree(raw: unknown): UiNode {
  const seen = new Set<string>();
  return parseNode(raw, seen, "$");
}

function parseNode(raw: unknown, seen: Set<string>, path: string): UiNode {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError(`${path}: node must be an object`);
  }
  const r = raw as Record<string, unknown>;
  const id = r.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new UiValidationError(`${path}: id must be a non-empty string`);
  }
  if (seen.has(id)) {
    throw new UiValidationError(`duplicate node id "${id}"`);
  }
  seen.add(id);
  const kind = r.kind;
  switch (kind) {
    case "Column":
    case "Row":
      return parseFlex(r, seen, path, id, kind);
    case "Section":
      return parseSection(r, seen, path, id);
    case "Card":
      return parseCard(r, seen, path, id);
    case "List":
      return parseList(r, seen, path, id);
    case "Text":
      return parseText(r, path, id);
    case "Spacer":
      return parseSpacer(r, path, id);
    case "TextField":
      return parseTextField(r, path, id);
    case "Button":
      return parseButton(r, path, id);
    case "Icon":
      return parseIcon(r, path, id);
    case "Badge":
      return parseBadge(r, path, id);
    case "ListTile":
      return parseListTile(r, seen, path, id);
    case "AppGrid":
      return parseAppGrid(r, path, id);
    default:
      throw new UiValidationError(
        `${path}: unknown node kind ${JSON.stringify(kind)}`,
      );
  }
}

function parseChildren(
  raw: unknown,
  seen: Set<string>,
  path: string,
  key: string,
): UiNode[] {
  if (!Array.isArray(raw)) {
    throw new UiValidationError(`${path}.${key}: must be an array`);
  }
  const out: UiNode[] = [];
  for (let i = 0; i < raw.length; i++) {
    out.push(parseNode(raw[i], seen, `${path}.${key}[${i}]`));
  }
  return out;
}

function parseFlex(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
  kind: "Column" | "Row",
): UiColumn | UiRow {
  const children = parseChildren(r.children, seen, path, "children");
  const out = { kind, id, children } as UiColumn | UiRow;
  const gap = optSpacing(r.gap, path, "gap");
  if (gap !== undefined) out.gap = gap;
  return out;
}

function parseSection(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiSection {
  const children = parseChildren(r.children, seen, path, "children");
  const out: UiSection = { kind: "Section", id, children };
  const title = optString(r.title, path, "title");
  if (title !== undefined) out.title = title;
  return out;
}

function parseCard(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiCard {
  const children = parseChildren(r.children, seen, path, "children");
  return { kind: "Card", id, children };
}

function parseList(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiList {
  const items = parseChildren(r.items, seen, path, "items");
  return { kind: "List", id, items };
}

function parseText(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiText {
  const text = r.text;
  if (typeof text !== "string") {
    throw new UiValidationError(`${path}.text: must be a string`);
  }
  const out: UiText = { kind: "Text", id, text };
  const style = r.style;
  if (style !== undefined && style !== null) {
    if (
      style !== "body" &&
      style !== "title" &&
      style !== "caption" &&
      style !== "mono"
    ) {
      throw new UiValidationError(
        `${path}.style: must be "body" | "title" | "caption" | "mono"`,
      );
    }
    out.style = style;
  }
  return out;
}

function parseSpacer(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSpacer {
  const out: UiSpacer = { kind: "Spacer", id };
  const size = optSpacing(r.size, path, "size");
  if (size !== undefined) out.size = size;
  return out;
}

function parseTextField(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiTextField {
  const out: UiTextField = { kind: "TextField", id };
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const value = optString(r.value, path, "value");
  if (value !== undefined) out.value = value;
  const placeholder = optString(r.placeholder, path, "placeholder");
  if (placeholder !== undefined) out.placeholder = placeholder;
  return out;
}

function parseButton(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiButton {
  const label = r.label;
  if (typeof label !== "string" || label.length === 0) {
    throw new UiValidationError(`${path}.label: must be a non-empty string`);
  }
  const out: UiButton = { kind: "Button", id, label };
  const style = r.style;
  if (style !== undefined && style !== null) {
    if (style !== "primary" && style !== "secondary" && style !== "danger") {
      throw new UiValidationError(
        `${path}.style: must be "primary" | "secondary" | "danger"`,
      );
    }
    out.style = style;
  }
  return out;
}

function parseIcon(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiIcon {
  const name = r.name;
  if (typeof name !== "string" || name.length === 0) {
    throw new UiValidationError(`${path}.name: must be a non-empty string`);
  }
  const out: UiIcon = { kind: "Icon", id, name };
  const size = optSize(r.size, path, "size");
  if (size !== undefined) out.size = size;
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function parseBadge(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiBadge {
  const variantRaw = r.variant;
  if (typeof variantRaw !== "string" || !BADGE_VARIANTS.has(variantRaw)) {
    throw new UiValidationError(
      `${path}.variant: must be "dot" | "pill"`,
    );
  }
  const out: UiBadge = { kind: "Badge", id, variant: variantRaw as UiBadgeVariant };
  const text = optString(r.text, path, "text");
  if (text !== undefined) out.text = text;
  const count = optNumber(r.count, path, "count");
  if (count !== undefined) {
    if (!Number.isInteger(count) || count < 0) {
      throw new UiValidationError(
        `${path}.count: must be a non-negative integer when provided`,
      );
    }
    out.count = count;
  }
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function parseListTile(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiListTile {
  const title = r.title;
  if (typeof title !== "string" || title.length === 0) {
    throw new UiValidationError(`${path}.title: must be a non-empty string`);
  }
  const out: UiListTile = { kind: "ListTile", id, title };
  const subtitle = optString(r.subtitle, path, "subtitle");
  if (subtitle !== undefined) out.subtitle = subtitle;
  if (r.leading !== undefined && r.leading !== null) {
    out.leading = parseNode(r.leading, seen, `${path}.leading`);
  }
  if (r.trailing !== undefined && r.trailing !== null) {
    out.trailing = parseNode(r.trailing, seen, `${path}.trailing`);
  }
  const onTapEvent = optString(r.onTapEvent, path, "onTapEvent");
  if (onTapEvent !== undefined) out.onTapEvent = onTapEvent;
  if (r.swipeActions !== undefined && r.swipeActions !== null) {
    if (!Array.isArray(r.swipeActions)) {
      throw new UiValidationError(
        `${path}.swipeActions: must be an array when provided`,
      );
    }
    out.swipeActions = r.swipeActions.map((raw, i) =>
      parseSwipeAction(raw, `${path}.swipeActions[${i}]`),
    );
  }
  return out;
}

function parseSwipeAction(raw: unknown, path: string): UiSwipeAction {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError(`${path}: must be an object`);
  }
  const r = raw as Record<string, unknown>;
  const label = r.label;
  if (typeof label !== "string" || label.length === 0) {
    throw new UiValidationError(`${path}.label: must be a non-empty string`);
  }
  const eventId = r.eventId;
  if (typeof eventId !== "string" || eventId.length === 0) {
    throw new UiValidationError(`${path}.eventId: must be a non-empty string`);
  }
  const out: UiSwipeAction = { label, eventId };
  const icon = optString(r.icon, path, "icon");
  if (icon !== undefined) out.icon = icon;
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function parseAppGrid(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiAppGrid {
  const rawItems = r.items;
  if (!Array.isArray(rawItems)) {
    throw new UiValidationError(`${path}.items: must be an array`);
  }
  const items: UiAppTile[] = [];
  const seenTileIds = new Set<string>();
  for (let i = 0; i < rawItems.length; i++) {
    const tile = parseAppTile(rawItems[i], `${path}.items[${i}]`);
    if (seenTileIds.has(tile.id)) {
      throw new UiValidationError(
        `${path}.items[${i}]: duplicate tile id "${tile.id}"`,
      );
    }
    seenTileIds.add(tile.id);
    items.push(tile);
  }
  const out: UiAppGrid = { kind: "AppGrid", id, items };
  const columns = optNumber(r.columns, path, "columns");
  if (columns !== undefined) {
    if (!Number.isInteger(columns) || columns < 1) {
      throw new UiValidationError(
        `${path}.columns: must be a positive integer when provided`,
      );
    }
    out.columns = columns;
  }
  const onLaunchEvent = optString(r.onLaunchEvent, path, "onLaunchEvent");
  if (onLaunchEvent !== undefined) out.onLaunchEvent = onLaunchEvent;
  return out;
}

function parseAppTile(raw: unknown, path: string): UiAppTile {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError(`${path}: must be an object`);
  }
  const r = raw as Record<string, unknown>;
  const id = r.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new UiValidationError(`${path}.id: must be a non-empty string`);
  }
  const name = r.name;
  if (typeof name !== "string" || name.length === 0) {
    throw new UiValidationError(`${path}.name: must be a non-empty string`);
  }
  let icon: string | { uri: string };
  if (typeof r.icon === "string" && r.icon.length > 0) {
    icon = r.icon;
  } else if (
    r.icon &&
    typeof r.icon === "object" &&
    !Array.isArray(r.icon) &&
    typeof (r.icon as Record<string, unknown>).uri === "string" &&
    ((r.icon as Record<string, unknown>).uri as string).length > 0
  ) {
    icon = { uri: (r.icon as { uri: string }).uri };
  } else {
    throw new UiValidationError(
      `${path}.icon: must be a non-empty string or { uri: string }`,
    );
  }
  const out: UiAppTile = { id, name, icon };
  if (r.badge !== undefined && r.badge !== null) {
    if (typeof r.badge !== "object" || Array.isArray(r.badge)) {
      throw new UiValidationError(
        `${path}.badge: must be a { count?, text? } object`,
      );
    }
    const bag = r.badge as Record<string, unknown>;
    const badge: UiAppTileBadge = {};
    const count = optNumber(bag.count, path, "badge.count");
    if (count !== undefined) {
      if (!Number.isInteger(count) || count < 0) {
        throw new UiValidationError(
          `${path}.badge.count: must be a non-negative integer when provided`,
        );
      }
      badge.count = count;
    }
    const text = optString(bag.text, path, "badge.text");
    if (text !== undefined) badge.text = text;
    out.badge = badge;
  }
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function optSpacing(
  v: unknown,
  path: string,
  key: string,
): StyleSlot<SpacingToken> | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      throw new UiValidationError(
        `${path}.${key}: must be a finite number when provided`,
      );
    }
    return v;
  }
  if (typeof v === "string" && SPACING_TOKENS.has(v)) {
    return v as SpacingToken;
  }
  throw new UiValidationError(
    `${path}.${key}: must be a number or one of ${[...SPACING_TOKENS].map((t) => `"${t}"`).join(" | ")}`,
  );
}

function optSize(
  v: unknown,
  path: string,
  key: string,
): StyleSlot<SizeToken> | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "number") {
    if (!Number.isFinite(v) || v < 0) {
      throw new UiValidationError(
        `${path}.${key}: must be a non-negative finite number when provided`,
      );
    }
    return v;
  }
  if (typeof v === "string" && SIZE_TOKENS.has(v)) {
    return v as SizeToken;
  }
  throw new UiValidationError(
    `${path}.${key}: must be a number or one of ${[...SIZE_TOKENS].map((t) => `"${t}"`).join(" | ")}`,
  );
}

function optAccent(
  v: unknown,
  path: string,
  key: string,
): AccentToken | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "string" && ACCENT_TOKENS.has(v)) {
    return v as AccentToken;
  }
  throw new UiValidationError(
    `${path}.${key}: must be one of ${[...ACCENT_TOKENS].map((t) => `"${t}"`).join(" | ")}`,
  );
}

function optString(
  v: unknown,
  path: string,
  key: string,
): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") {
    throw new UiValidationError(`${path}.${key}: must be a string when provided`);
  }
  return v;
}

function optNumber(
  v: unknown,
  path: string,
  key: string,
): number | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new UiValidationError(
      `${path}.${key}: must be a finite number when provided`,
    );
  }
  return v;
}

// ----- Registry + fan-out -----

/// Snapshot delivered to subscribers via `ui.tree`. `tree` is `null` for
/// the retirement push the host emits on plugin exit / disable. `version`
/// is monotonic per (pluginId, panelId); the client uses it to drop late
/// / reordered pushes.
export interface UiPanelSnapshot {
  pluginId: string;
  panelId: string;
  tree: UiNode | null;
  version: number;
}

interface PanelEntry {
  pluginId: string;
  panelId: string;
  tree: UiNode;
  version: number;
}

export type UiNotifier = (
  ws: WebSocket,
  method: string,
  params: unknown,
) => void;

/// Per-plugin per-panel cache of the latest tree, with a monotonic
/// version stream. Owns its subscriber set; the host registers / unregisters
/// WebSockets via `subscribe` / `unsubscribe` from the `ui.subscribe` RPC
/// path and from `state.removeSubscriber` on socket close.
export class UiPanelRegistry {
  /// key = `${pluginId} ${panelId}` — null byte is illegal in either id
  /// component, so the concatenation is unambiguous without escaping.
  private readonly panels = new Map<string, PanelEntry>();
  /// The version counter survives panel deletion. A plugin that re-emits a
  /// panel after retirement gets a strictly-larger version, which keeps the
  /// monotonic-version contract intact for any client that saw the
  /// retirement push.
  private readonly versions = new Map<string, number>();
  private readonly subscribers = new Set<WebSocket>();
  private readonly notify: UiNotifier;

  constructor(notify: UiNotifier) {
    this.notify = notify;
  }

  /// Replace the panel's tree atomically, bump its version, and push to
  /// every subscriber. Caller is responsible for validating `tree` first
  /// (the registry trusts what it gets).
  public render(
    pluginId: string,
    panelId: string,
    tree: UiNode,
  ): UiPanelSnapshot {
    const key = makeKey(pluginId, panelId);
    const next = (this.versions.get(key) ?? 0) + 1;
    this.versions.set(key, next);
    this.panels.set(key, { pluginId, panelId, tree, version: next });
    const snap: UiPanelSnapshot = { pluginId, panelId, tree, version: next };
    this.broadcast(snap);
    return snap;
  }

  /// Send one `tree: null` push per panel owned by `pluginId`, then drop
  /// the panel(s). Called by the host on `plugin.disable` / plugin process
  /// exit. Idempotent — re-retiring a plugin with no live panels is a no-op.
  public retirePlugin(pluginId: string): UiPanelSnapshot[] {
    const out: UiPanelSnapshot[] = [];
    for (const [key, entry] of [...this.panels]) {
      if (entry.pluginId !== pluginId) continue;
      const next = (this.versions.get(key) ?? entry.version) + 1;
      this.versions.set(key, next);
      const snap: UiPanelSnapshot = {
        pluginId,
        panelId: entry.panelId,
        tree: null,
        version: next,
      };
      this.broadcast(snap);
      this.panels.delete(key);
      out.push(snap);
    }
    return out;
  }

  /// Read-only view of every currently live panel, in insertion order.
  /// Used by `ui.subscribe` to send a follow-up push per panel so a fresh
  /// client lands in sync without round-tripping.
  public activePanels(): UiPanelSnapshot[] {
    return [...this.panels.values()].map((e) => ({
      pluginId: e.pluginId,
      panelId: e.panelId,
      tree: e.tree,
      version: e.version,
    }));
  }

  /// Add `ws` to the fan-out set. Idempotent — duplicate subscribes are
  /// silently coalesced (matches `notification.subscribe` semantics in §4.5).
  public subscribe(ws: WebSocket): void {
    this.subscribers.add(ws);
  }

  public unsubscribe(ws: WebSocket): void {
    this.subscribers.delete(ws);
  }

  public hasSubscriber(ws: WebSocket): boolean {
    return this.subscribers.has(ws);
  }

  private broadcast(snap: UiPanelSnapshot): void {
    for (const ws of this.subscribers) {
      this.notify(ws, "ui.tree", snap);
    }
  }
}

function makeKey(pluginId: string, panelId: string): string {
  return `${pluginId} ${panelId}`;
}
