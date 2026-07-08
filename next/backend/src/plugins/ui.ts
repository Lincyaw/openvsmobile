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

import { promises as fs } from "node:fs";
import { isAbsolute, normalize } from "node:path";
import type { WebSocket } from "ws";

import { pathIsInside } from "../pathInside.js";

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
export type UiFocusRole = "status" | "action" | "input" | "danger";

export type StyleSlot<TToken extends string> = number | TToken;

export interface UiNodeMetadata {
  accessibilityLabel?: string;
  accessibilityHint?: string;
  spokenValue?: string;
  focusRole?: UiFocusRole;
  focusOrder?: number;
  voiceInputEvent?: string;
  voiceOutputText?: string;
  voiceShortcut?: boolean;
}

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
const SECTION_VARIANTS: ReadonlySet<string> = new Set([
  "plain",
  "card",
  "inset",
]);
/// Banner accent is the {info, success, warning, danger} slice of
/// AccentToken — `brand` / `muted` aren't meaningful for a "you should
/// notice this" surface, and the doc spec calls out the four-value union
/// directly.
const BANNER_ACCENTS: ReadonlySet<string> = new Set([
  "info",
  "success",
  "warning",
  "danger",
]);
const DIVIDER_ORIENTATIONS: ReadonlySet<string> = new Set([
  "horizontal",
  "vertical",
]);
const IMAGE_FITS: ReadonlySet<string> = new Set(["cover", "contain", "fill"]);
const PROGRESS_VARIANTS: ReadonlySet<string> = new Set([
  "linear",
  "circular",
]);
const STACK_ALIGNMENTS: ReadonlySet<string> = new Set([
  "topStart",
  "topCenter",
  "topEnd",
  "centerStart",
  "center",
  "centerEnd",
  "bottomStart",
  "bottomCenter",
  "bottomEnd",
]);
const SCROLL_AXES: ReadonlySet<string> = new Set([
  "vertical",
  "horizontal",
]);
const FOCUS_ROLES: ReadonlySet<string> = new Set([
  "status",
  "action",
  "input",
  "danger",
]);

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
/// `variant` is optional and omitted-equals-plain so pre-Batch-2 trees
/// keep rendering identically.
export type UiSectionVariant = "plain" | "card" | "inset";
export interface UiSection {
  kind: "Section";
  id: string;
  title?: string;
  variant?: UiSectionVariant;
  /// When `true`, the renderer adds a tap-to-expand-collapse header
  /// chevron. Default state is expanded; the renderer persists the
  /// expanded/collapsed state per node id across re-renders. Omitted =
  /// not collapsible.
  collapsible?: boolean;
  children: UiNode[];
}
/// Deprecated alias kept for one minor version: behaves exactly like
/// `UiSection { variant: "card", children }`. New code should emit a
/// Section directly; the host renders both paths through the same code.
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

// ---- Batch 2 new widgets (§4.3) ----

/// Two-state toggle. The plugin owns canonical state; the host fires
/// `onChangeEvent` with `payload: { value: boolean }` the moment the
/// user flips it. Renderer applies the new value optimistically so the
/// thumb tracks the gesture; the plugin's next render is authoritative.
export interface UiSwitch {
  kind: "Switch";
  id: string;
  label?: string;
  value: boolean;
  onChangeEvent?: string;
}

/// One option in a [UiSelect]. The `value` is the wire identifier sent
/// back in `payload.value`; `label` is the human-readable text shown in
/// the picker.
export interface UiSelectOption {
  value: string;
  label: string;
}

/// Single-choice picker. Always renders as a modal bottom-sheet picker
/// on mobile (the doc spec is explicit about this — no dropdown menus
/// on a touch surface). When the user commits a pick, the host fires
/// `onChangeEvent` with `payload: { value: string }`.
export interface UiSelect {
  kind: "Select";
  id: string;
  label?: string;
  options: UiSelectOption[];
  value?: string;
  onChangeEvent?: string;
}

/// In-flow status surface — "you're offline", "syncing 3/12 files".
/// Lives in the declarative tree (unlike `ui.showAlert`, which is
/// imperative and Batch 4). The four-value `accent` union maps onto the
/// info / success / warning / danger tones; brand / muted aren't useful
/// for a "you should notice this" surface.
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
  /// Optional dismiss eventId. When set, the renderer shows a close
  /// affordance and fires this event on tap; the plugin removes the
  /// banner from its next render. Omitted = persistent until the
  /// plugin re-renders without it.
  dismissEventId?: string;
}

/// Explicit divider. Inset sections render their own row separators
/// internally; this widget is for **outside** that context (e.g.
/// between two cards, or as a vertical rule inside a Row).
export type UiDividerOrientation = "horizontal" | "vertical";
export interface UiDivider {
  kind: "Divider";
  id: string;
  orientation?: UiDividerOrientation;
}

// ---- Batch 3 new widgets (§4.3) — rich display ----

export type UiImageFit = "cover" | "contain" | "fill";

/// Network / inline / local-file image. `src` URL schemes accepted:
/// `https://…`, `data:image/...;base64,…`, `file://…`. `file://` URLs
/// are post-validated by the host (`validateFileUrls`) against the
/// caller plugin's manifest `fs` capability + the active workspace root.
export interface UiImage {
  kind: "Image";
  id: string;
  src: string;
  fit?: UiImageFit;
  size?: StyleSlot<SizeToken>;
}

/// Profile circle — image (any [UiImage] URL scheme) when `src` is set,
/// otherwise the first 1–2 chars of `initial` on a deterministic
/// hashed color. `accent` overrides the hash color.
export interface UiAvatar {
  kind: "Avatar";
  id: string;
  src?: string;
  initial?: string;
  size?: StyleSlot<SizeToken>;
  accent?: AccentToken;
}

/// Strict-subset Markdown. Headings h1–h4, paragraphs, lists
/// (ordered/unordered, nested), code blocks, inline code, links, bold,
/// italic, blockquotes, horizontal rules. The validator is intentionally
/// permissive — out-of-subset constructs (raw HTML, tables, images)
/// render as escaped plain text on the client, so the host doesn't try
/// to parse the body here; it only checks that `markdown` is a string.
export interface UiMarkdown {
  kind: "Markdown";
  id: string;
  markdown: string;
}

/// Source-code block. `language` is a highlight.js-style identifier;
/// unknown languages render as unhighlighted monospace on the client.
export interface UiCodeBlock {
  kind: "CodeBlock";
  id: string;
  code: string;
  language?: string;
}

export type UiProgressVariant = "linear" | "circular";

/// Progress indicator. `value` in [0, 1]; omitted/null → indeterminate.
/// Default `variant` is `linear`.
export interface UiProgress {
  kind: "Progress";
  id: string;
  value?: number;
  variant?: UiProgressVariant;
  label?: string;
  accent?: AccentToken;
}

/// Indeterminate spinner (always circular). Optional `label` rendered
/// to the right; `size` controls spinner diameter.
export interface UiSpinner {
  kind: "Spinner";
  id: string;
  label?: string;
  size?: StyleSlot<SizeToken>;
}

// ---- Batch 5 widgets (§4.3) — long tail ----

/// Fixed-column / adaptive grid. `columns` accepts a positive integer
/// or the literal `'adaptive'` (renderer picks a sensible column count
/// for the viewport). Children flow row-major.
export type UiGridColumns = number | "adaptive";
export interface UiGrid {
  kind: "Grid";
  id: string;
  children: UiNode[];
  columns: UiGridColumns;
  gap?: StyleSlot<SpacingToken>;
}

/// Z-axis stack — children paint on top of each other, anchored by
/// the optional `alignment` (default: `center`).
export type UiStackAlignment =
  | "topStart"
  | "topCenter"
  | "topEnd"
  | "centerStart"
  | "center"
  | "centerEnd"
  | "bottomStart"
  | "bottomCenter"
  | "bottomEnd";
export interface UiStack {
  kind: "Stack";
  id: string;
  children: UiNode[];
  alignment?: UiStackAlignment;
}

/// Aspect-ratio enforcer. `ratio` is width / height; finite > 0.
export interface UiAspect {
  kind: "Aspect";
  id: string;
  ratio: number;
  child: UiNode;
}

/// Flex distribution hint for a Row/Column child. `flex` must be a
/// non-negative finite number; outside a Row/Column the renderer falls
/// back to a plain child without claiming space.
export interface UiFlex {
  kind: "Flex";
  id: string;
  flex: number;
  child: UiNode;
}

/// Explicit scroll region. `axis` defaults to `vertical`.
export type UiScrollAxis = "vertical" | "horizontal";
export interface UiScroll {
  kind: "Scroll";
  id: string;
  axis?: UiScrollAxis;
  child: UiNode;
}

/// Segmented tab control. `activeId` must match one of `tabs[*].id`;
/// the host renders the chrome but switching panel content on tap is
/// the plugin's responsibility (re-render with new `activeId` + the
/// matching tab's content elsewhere in the tree).
export interface UiTabBarTab {
  id: string;
  label: string;
  icon?: string;
}
export interface UiTabBar {
  kind: "TabBar";
  id: string;
  tabs: UiTabBarTab[];
  activeId: string;
  onChangeEvent?: string;
}

/// Search variant of [UiTextField]. Renderer adds a leading magnifier
/// icon + a trailing clear button when the field is non-empty.
export interface UiSearchField {
  kind: "SearchField";
  id: string;
  value?: string;
  placeholder?: string;
  onChangeEvent?: string;
}

/// Standalone checkbox. Same reconciliation contract as [UiSwitch].
export interface UiCheckbox {
  kind: "Checkbox";
  id: string;
  label?: string;
  value: boolean;
  onChangeEvent?: string;
}

export interface UiRadioOption {
  value: string;
  label: string;
}

/// Single-selection radio list. Same reconciliation contract as
/// [UiSwitch].
export interface UiRadioGroup {
  kind: "RadioGroup";
  id: string;
  options: UiRadioOption[];
  value?: string;
  onChangeEvent?: string;
}

/// Continuous (omit `step`) or stepped (with `step`) slider. The
/// validator requires `min < max`, `value` finite (the renderer clamps
/// to range), and `step > 0` when present.
export interface UiSlider {
  kind: "Slider";
  id: string;
  min: number;
  max: number;
  step?: number;
  value: number;
  onChangeEvent?: string;
}

export type UiNode = (
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
  | UiDivider
  | UiImage
  | UiAvatar
  | UiMarkdown
  | UiCodeBlock
  | UiProgress
  | UiSpinner
  | UiGrid
  | UiStack
  | UiAspect
  | UiFlex
  | UiScroll
  | UiTabBar
  | UiSearchField
  | UiCheckbox
  | UiRadioGroup
  | UiSlider
) &
  UiNodeMetadata;

// ---- Batch 4 imperative modals (§4.3) ----
//
// These types live OFF the declarative `ui.tree`. A plugin invokes one
// of three host methods (`ui.showAlert` / `ui.showActionSheet` /
// `ui.showBottomSheet`) which the host pushes to subscribed clients as a
// `ui.modal` notification. The picked action / dismiss flows back via the
// regular `ui.event` channel — same as any tap on a declarative widget.
//
// Why imperative: a modal's lifetime is "open until the user dismisses
// it", which doesn't compose cleanly with the version-bumped declarative
// reconciliation of `ui.tree`. The §4.3 spec is explicit that these
// match the pre-existing `ui.showMessage` / `ui.showQuickPick` direction
// rather than living in the tree.

/// Action variant for [UiAlertDialog] buttons.
export type UiAlertActionVariant = "primary" | "danger";

export interface UiAlertAction {
  label: string;
  eventId: string;
  variant?: UiAlertActionVariant;
}

/// Material AlertDialog. `dismissible: false` blocks tap-outside /
/// back-press dismissal — only the configured action buttons resolve it.
/// When `dismissible !== false` and the user dismisses without picking,
/// no event is fired (matching the doc-spec shape: no `dismissEventId`).
export interface UiAlertDialog {
  id: string;
  title: string;
  body?: string;
  actions: UiAlertAction[];
  dismissible?: boolean;
}

export interface UiActionSheetAction {
  label: string;
  icon?: string;
  eventId: string;
  accent?: AccentToken;
}

/// iOS-style action sheet. The renderer picks the platform-native shape
/// (CupertinoActionSheet on iOS, modal bottom-sheet list on Android).
/// `dismissEventId` fires on tap-outside / back-press; omitted = silent
/// dismiss.
export interface UiActionSheet {
  id: string;
  title?: string;
  actions: UiActionSheetAction[];
  dismissEventId?: string;
}

/// Generic modal bottom sheet hosting an arbitrary [UiNode] child. The
/// child is gated for `file://` URLs at the `ui.showBottomSheet` entry
/// point (separate from the `ui.render` walker, which only sees panel
/// trees).
export interface UiBottomSheet {
  id: string;
  title?: string;
  child: UiNode;
  dismissEventId?: string;
}

const ALERT_VARIANTS: ReadonlySet<string> = new Set(["primary", "danger"]);

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
  const metadata = parseNodeMetadata(r, path);
  const kind = r.kind;
  let node: UiNode;
  switch (kind) {
    case "Column":
    case "Row":
      node = parseFlex(r, seen, path, id, kind) as UiNode;
      break;
    case "Section":
      node = parseSection(r, seen, path, id) as UiNode;
      break;
    case "Card":
      node = parseCard(r, seen, path, id) as UiNode;
      break;
    case "List":
      node = parseList(r, seen, path, id) as UiNode;
      break;
    case "Text":
      node = parseText(r, path, id) as UiNode;
      break;
    case "Spacer":
      node = parseSpacer(r, path, id) as UiNode;
      break;
    case "TextField":
      node = parseTextField(r, path, id) as UiNode;
      break;
    case "Button":
      node = parseButton(r, path, id) as UiNode;
      break;
    case "Icon":
      node = parseIcon(r, path, id) as UiNode;
      break;
    case "Badge":
      node = parseBadge(r, path, id) as UiNode;
      break;
    case "ListTile":
      node = parseListTile(r, seen, path, id) as UiNode;
      break;
    case "AppGrid":
      node = parseAppGrid(r, path, id) as UiNode;
      break;
    case "Switch":
      node = parseSwitch(r, path, id) as UiNode;
      break;
    case "Select":
      node = parseSelect(r, path, id) as UiNode;
      break;
    case "Banner":
      node = parseBanner(r, path, id) as UiNode;
      break;
    case "Divider":
      node = parseDivider(r, path, id) as UiNode;
      break;
    case "Image":
      node = parseImage(r, path, id) as UiNode;
      break;
    case "Avatar":
      node = parseAvatar(r, path, id) as UiNode;
      break;
    case "Markdown":
      node = parseMarkdown(r, path, id) as UiNode;
      break;
    case "CodeBlock":
      node = parseCodeBlock(r, path, id) as UiNode;
      break;
    case "Progress":
      node = parseProgress(r, path, id) as UiNode;
      break;
    case "Spinner":
      node = parseSpinner(r, path, id) as UiNode;
      break;
    case "Grid":
      node = parseGrid(r, seen, path, id) as UiNode;
      break;
    case "Stack":
      node = parseStack(r, seen, path, id) as UiNode;
      break;
    case "Aspect":
      node = parseAspect(r, seen, path, id) as UiNode;
      break;
    case "Flex":
      node = parseFlexNode(r, seen, path, id) as UiNode;
      break;
    case "Scroll":
      node = parseScroll(r, seen, path, id) as UiNode;
      break;
    case "TabBar":
      node = parseTabBar(r, path, id) as UiNode;
      break;
    case "SearchField":
      node = parseSearchField(r, path, id) as UiNode;
      break;
    case "Checkbox":
      node = parseCheckbox(r, path, id) as UiNode;
      break;
    case "RadioGroup":
      node = parseRadioGroup(r, path, id) as UiNode;
      break;
    case "Slider":
      node = parseSlider(r, path, id) as UiNode;
      break;
    default:
      throw new UiValidationError(
        `${path}: unknown node kind ${JSON.stringify(kind)}`,
      );
  }
  Object.assign(node, metadata);
  return node;
}

function parseNodeMetadata(
  r: Record<string, unknown>,
  path: string,
): UiNodeMetadata {
  const out: UiNodeMetadata = {};
  const accessibilityLabel = optString(
    r.accessibilityLabel,
    path,
    "accessibilityLabel",
  );
  if (accessibilityLabel !== undefined) {
    if (accessibilityLabel.length === 0) {
      throw new UiValidationError(
        `${path}.accessibilityLabel: must be a non-empty string when provided`,
      );
    }
    out.accessibilityLabel = accessibilityLabel;
  }
  const accessibilityHint = optString(
    r.accessibilityHint,
    path,
    "accessibilityHint",
  );
  if (accessibilityHint !== undefined) {
    if (accessibilityHint.length === 0) {
      throw new UiValidationError(
        `${path}.accessibilityHint: must be a non-empty string when provided`,
      );
    }
    out.accessibilityHint = accessibilityHint;
  }
  const spokenValue = optString(r.spokenValue, path, "spokenValue");
  if (spokenValue !== undefined) {
    if (spokenValue.length === 0) {
      throw new UiValidationError(
        `${path}.spokenValue: must be a non-empty string when provided`,
      );
    }
    out.spokenValue = spokenValue;
  }
  if (r.focusRole !== undefined && r.focusRole !== null) {
    if (typeof r.focusRole !== "string" || !FOCUS_ROLES.has(r.focusRole)) {
      throw new UiValidationError(
        `${path}.focusRole: must be "status" | "action" | "input" | "danger"`,
      );
    }
    out.focusRole = r.focusRole as UiFocusRole;
  }
  if (r.focusOrder !== undefined && r.focusOrder !== null) {
    if (
      typeof r.focusOrder !== "number" ||
      !Number.isInteger(r.focusOrder) ||
      r.focusOrder < 0
    ) {
      throw new UiValidationError(
        `${path}.focusOrder: must be a non-negative integer when provided`,
      );
    }
    out.focusOrder = r.focusOrder;
  }
  const voiceInputEvent = optString(r.voiceInputEvent, path, "voiceInputEvent");
  if (voiceInputEvent !== undefined) {
    if (voiceInputEvent.length === 0) {
      throw new UiValidationError(
        `${path}.voiceInputEvent: must be a non-empty string when provided`,
      );
    }
    out.voiceInputEvent = voiceInputEvent;
  }
  const voiceOutputText = optString(r.voiceOutputText, path, "voiceOutputText");
  if (voiceOutputText !== undefined) {
    if (voiceOutputText.length === 0) {
      throw new UiValidationError(
        `${path}.voiceOutputText: must be a non-empty string when provided`,
      );
    }
    out.voiceOutputText = voiceOutputText;
  }
  if (r.voiceShortcut !== undefined && r.voiceShortcut !== null) {
    if (typeof r.voiceShortcut !== "boolean") {
      throw new UiValidationError(
        `${path}.voiceShortcut: must be a boolean when provided`,
      );
    }
    out.voiceShortcut = r.voiceShortcut;
  }
  return out;
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
  const variant = r.variant;
  if (variant !== undefined && variant !== null) {
    if (typeof variant !== "string" || !SECTION_VARIANTS.has(variant)) {
      throw new UiValidationError(
        `${path}.variant: must be "plain" | "card" | "inset"`,
      );
    }
    out.variant = variant as UiSectionVariant;
  }
  const collapsible = r.collapsible;
  if (collapsible !== undefined && collapsible !== null) {
    if (typeof collapsible !== "boolean") {
      throw new UiValidationError(
        `${path}.collapsible: must be a boolean when provided`,
      );
    }
    out.collapsible = collapsible;
  }
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

function parseSwitch(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSwitch {
  const value = r.value;
  if (typeof value !== "boolean") {
    throw new UiValidationError(`${path}.value: must be a boolean`);
  }
  const out: UiSwitch = { kind: "Switch", id, value };
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseSelect(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSelect {
  const rawOptions = r.options;
  if (!Array.isArray(rawOptions)) {
    throw new UiValidationError(`${path}.options: must be an array`);
  }
  const options: UiSelectOption[] = [];
  const seenValues = new Set<string>();
  for (let i = 0; i < rawOptions.length; i++) {
    const raw = rawOptions[i];
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new UiValidationError(`${path}.options[${i}]: must be an object`);
    }
    const o = raw as Record<string, unknown>;
    const value = o.value;
    if (typeof value !== "string" || value.length === 0) {
      throw new UiValidationError(
        `${path}.options[${i}].value: must be a non-empty string`,
      );
    }
    const label = o.label;
    if (typeof label !== "string" || label.length === 0) {
      throw new UiValidationError(
        `${path}.options[${i}].label: must be a non-empty string`,
      );
    }
    // Duplicate option values are a plugin-author bug — the picker would
    // be unable to disambiguate which one matched the selected `value`.
    if (seenValues.has(value)) {
      throw new UiValidationError(
        `${path}.options[${i}]: duplicate option value "${value}"`,
      );
    }
    seenValues.add(value);
    options.push({ value, label });
  }
  const out: UiSelect = { kind: "Select", id, options };
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const value = optString(r.value, path, "value");
  if (value !== undefined) {
    // A `value` outside the option set would render an empty picker
    // trigger — surface that as an error so the plugin author notices
    // the typo at validation time instead of from a confused user.
    if (!seenValues.has(value)) {
      throw new UiValidationError(
        `${path}.value: must match one of the options' value`,
      );
    }
    out.value = value;
  }
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseBanner(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiInlineBanner {
  const title = r.title;
  if (typeof title !== "string" || title.length === 0) {
    throw new UiValidationError(`${path}.title: must be a non-empty string`);
  }
  const accentRaw = r.accent;
  if (typeof accentRaw !== "string" || !BANNER_ACCENTS.has(accentRaw)) {
    throw new UiValidationError(
      `${path}.accent: must be "info" | "success" | "warning" | "danger"`,
    );
  }
  const out: UiInlineBanner = {
    kind: "Banner",
    id,
    title,
    accent: accentRaw as UiInlineBannerAccent,
  };
  const body = optString(r.body, path, "body");
  if (body !== undefined) out.body = body;
  if (r.action !== undefined && r.action !== null) {
    if (typeof r.action !== "object" || Array.isArray(r.action)) {
      throw new UiValidationError(
        `${path}.action: must be { label, eventId } when provided`,
      );
    }
    const ar = r.action as Record<string, unknown>;
    const aLabel = ar.label;
    const aEventId = ar.eventId;
    if (typeof aLabel !== "string" || aLabel.length === 0) {
      throw new UiValidationError(
        `${path}.action.label: must be a non-empty string`,
      );
    }
    if (typeof aEventId !== "string" || aEventId.length === 0) {
      throw new UiValidationError(
        `${path}.action.eventId: must be a non-empty string`,
      );
    }
    out.action = { label: aLabel, eventId: aEventId };
  }
  const dismissEventId = optString(r.dismissEventId, path, "dismissEventId");
  if (dismissEventId !== undefined) out.dismissEventId = dismissEventId;
  return out;
}

function parseDivider(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiDivider {
  const out: UiDivider = { kind: "Divider", id };
  const orientation = r.orientation;
  if (orientation !== undefined && orientation !== null) {
    if (
      typeof orientation !== "string" ||
      !DIVIDER_ORIENTATIONS.has(orientation)
    ) {
      throw new UiValidationError(
        `${path}.orientation: must be "horizontal" | "vertical"`,
      );
    }
    out.orientation = orientation as UiDividerOrientation;
  }
  return out;
}

function parseImage(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiImage {
  const src = r.src;
  if (typeof src !== "string" || src.length === 0) {
    throw new UiValidationError(`${path}.src: must be a non-empty string`);
  }
  const out: UiImage = { kind: "Image", id, src };
  const fit = r.fit;
  if (fit !== undefined && fit !== null) {
    if (typeof fit !== "string" || !IMAGE_FITS.has(fit)) {
      throw new UiValidationError(
        `${path}.fit: must be "cover" | "contain" | "fill"`,
      );
    }
    out.fit = fit as UiImageFit;
  }
  const size = optSize(r.size, path, "size");
  if (size !== undefined) out.size = size;
  return out;
}

function parseAvatar(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiAvatar {
  const out: UiAvatar = { kind: "Avatar", id };
  // `src` and `initial` are both optional individually — but a totally
  // empty avatar (neither set) is a plugin-author bug because the
  // renderer would have no glyph to fall back on. Surface as a
  // validation error rather than rendering a blank circle.
  const src = optString(r.src, path, "src");
  if (src !== undefined) out.src = src;
  const initial = optString(r.initial, path, "initial");
  if (initial !== undefined) out.initial = initial;
  if (out.src === undefined && out.initial === undefined) {
    throw new UiValidationError(
      `${path}: avatar requires src or initial`,
    );
  }
  const size = optSize(r.size, path, "size");
  if (size !== undefined) out.size = size;
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function parseMarkdown(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiMarkdown {
  const markdown = r.markdown;
  if (typeof markdown !== "string") {
    throw new UiValidationError(
      `${path}.markdown: must be a string`,
    );
  }
  return { kind: "Markdown", id, markdown };
}

function parseCodeBlock(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiCodeBlock {
  const code = r.code;
  if (typeof code !== "string") {
    throw new UiValidationError(`${path}.code: must be a string`);
  }
  const out: UiCodeBlock = { kind: "CodeBlock", id, code };
  const language = optString(r.language, path, "language");
  if (language !== undefined) out.language = language;
  return out;
}

function parseProgress(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiProgress {
  const out: UiProgress = { kind: "Progress", id };
  if (r.value !== undefined && r.value !== null) {
    if (typeof r.value !== "number" || !Number.isFinite(r.value)) {
      throw new UiValidationError(
        `${path}.value: must be a finite number in [0, 1] when provided`,
      );
    }
    if (r.value < 0 || r.value > 1) {
      throw new UiValidationError(
        `${path}.value: must be in [0, 1] when provided`,
      );
    }
    out.value = r.value;
  }
  if (r.variant !== undefined && r.variant !== null) {
    if (typeof r.variant !== "string" || !PROGRESS_VARIANTS.has(r.variant)) {
      throw new UiValidationError(
        `${path}.variant: must be "linear" | "circular"`,
      );
    }
    out.variant = r.variant as UiProgressVariant;
  }
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const accent = optAccent(r.accent, path, "accent");
  if (accent !== undefined) out.accent = accent;
  return out;
}

function parseSpinner(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSpinner {
  const out: UiSpinner = { kind: "Spinner", id };
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const size = optSize(r.size, path, "size");
  if (size !== undefined) out.size = size;
  return out;
}

// ---- Batch 5 parsers ----

function parseGrid(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiGrid {
  const children = parseChildren(r.children, seen, path, "children");
  const columnsRaw = r.columns;
  let columns: UiGridColumns;
  if (columnsRaw === "adaptive") {
    columns = "adaptive";
  } else if (typeof columnsRaw === "number") {
    if (!Number.isInteger(columnsRaw) || columnsRaw < 1) {
      throw new UiValidationError(
        `${path}.columns: must be a positive integer or "adaptive"`,
      );
    }
    columns = columnsRaw;
  } else {
    throw new UiValidationError(
      `${path}.columns: must be a positive integer or "adaptive"`,
    );
  }
  const out: UiGrid = { kind: "Grid", id, children, columns };
  const gap = optSpacing(r.gap, path, "gap");
  if (gap !== undefined) out.gap = gap;
  return out;
}

function parseStack(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiStack {
  const children = parseChildren(r.children, seen, path, "children");
  const out: UiStack = { kind: "Stack", id, children };
  const alignment = r.alignment;
  if (alignment !== undefined && alignment !== null) {
    if (typeof alignment !== "string" || !STACK_ALIGNMENTS.has(alignment)) {
      throw new UiValidationError(
        `${path}.alignment: must be one of ${[...STACK_ALIGNMENTS]
          .map((t) => `"${t}"`)
          .join(" | ")}`,
      );
    }
    out.alignment = alignment as UiStackAlignment;
  }
  return out;
}

function parseAspect(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiAspect {
  const ratio = r.ratio;
  if (typeof ratio !== "number" || !Number.isFinite(ratio) || ratio <= 0) {
    throw new UiValidationError(
      `${path}.ratio: must be a positive finite number`,
    );
  }
  if (r.child === undefined || r.child === null) {
    throw new UiValidationError(`${path}.child: required`);
  }
  const child = parseNode(r.child, seen, `${path}.child`);
  return { kind: "Aspect", id, ratio, child };
}

function parseFlexNode(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiFlex {
  const flex = r.flex;
  if (typeof flex !== "number" || !Number.isFinite(flex) || flex < 0) {
    throw new UiValidationError(
      `${path}.flex: must be a non-negative finite number`,
    );
  }
  if (r.child === undefined || r.child === null) {
    throw new UiValidationError(`${path}.child: required`);
  }
  const child = parseNode(r.child, seen, `${path}.child`);
  return { kind: "Flex", id, flex, child };
}

function parseScroll(
  r: Record<string, unknown>,
  seen: Set<string>,
  path: string,
  id: string,
): UiScroll {
  if (r.child === undefined || r.child === null) {
    throw new UiValidationError(`${path}.child: required`);
  }
  const child = parseNode(r.child, seen, `${path}.child`);
  const out: UiScroll = { kind: "Scroll", id, child };
  const axis = r.axis;
  if (axis !== undefined && axis !== null) {
    if (typeof axis !== "string" || !SCROLL_AXES.has(axis)) {
      throw new UiValidationError(
        `${path}.axis: must be "vertical" | "horizontal"`,
      );
    }
    out.axis = axis as UiScrollAxis;
  }
  return out;
}

function parseTabBar(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiTabBar {
  const rawTabs = r.tabs;
  if (!Array.isArray(rawTabs) || rawTabs.length === 0) {
    throw new UiValidationError(
      `${path}.tabs: must be a non-empty array`,
    );
  }
  const tabs: UiTabBarTab[] = [];
  const seenIds = new Set<string>();
  for (let i = 0; i < rawTabs.length; i++) {
    const raw = rawTabs[i];
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new UiValidationError(`${path}.tabs[${i}]: must be an object`);
    }
    const t = raw as Record<string, unknown>;
    const tabId = t.id;
    if (typeof tabId !== "string" || tabId.length === 0) {
      throw new UiValidationError(
        `${path}.tabs[${i}].id: must be a non-empty string`,
      );
    }
    if (seenIds.has(tabId)) {
      throw new UiValidationError(
        `${path}.tabs[${i}]: duplicate tab id "${tabId}"`,
      );
    }
    seenIds.add(tabId);
    const label = t.label;
    if (typeof label !== "string" || label.length === 0) {
      throw new UiValidationError(
        `${path}.tabs[${i}].label: must be a non-empty string`,
      );
    }
    const tab: UiTabBarTab = { id: tabId, label };
    const icon = optString(t.icon, path, `tabs[${i}].icon`);
    if (icon !== undefined) tab.icon = icon;
    tabs.push(tab);
  }
  const activeId = r.activeId;
  if (typeof activeId !== "string" || activeId.length === 0) {
    throw new UiValidationError(
      `${path}.activeId: must be a non-empty string`,
    );
  }
  // A mismatched activeId would silently fall through to "first tab"
  // in the renderer. Surface as a validation error so the plugin
  // author notices the typo at render time.
  if (!seenIds.has(activeId)) {
    throw new UiValidationError(
      `${path}.activeId: must match one of the tabs' id`,
    );
  }
  const out: UiTabBar = { kind: "TabBar", id, tabs, activeId };
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseSearchField(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSearchField {
  const out: UiSearchField = { kind: "SearchField", id };
  const value = optString(r.value, path, "value");
  if (value !== undefined) out.value = value;
  const placeholder = optString(r.placeholder, path, "placeholder");
  if (placeholder !== undefined) out.placeholder = placeholder;
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseCheckbox(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiCheckbox {
  const value = r.value;
  if (typeof value !== "boolean") {
    throw new UiValidationError(`${path}.value: must be a boolean`);
  }
  const out: UiCheckbox = { kind: "Checkbox", id, value };
  const label = optString(r.label, path, "label");
  if (label !== undefined) out.label = label;
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseRadioGroup(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiRadioGroup {
  const rawOptions = r.options;
  if (!Array.isArray(rawOptions) || rawOptions.length === 0) {
    throw new UiValidationError(
      `${path}.options: must be a non-empty array`,
    );
  }
  const options: UiRadioOption[] = [];
  const seenValues = new Set<string>();
  for (let i = 0; i < rawOptions.length; i++) {
    const raw = rawOptions[i];
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new UiValidationError(
        `${path}.options[${i}]: must be an object`,
      );
    }
    const o = raw as Record<string, unknown>;
    const value = o.value;
    if (typeof value !== "string" || value.length === 0) {
      throw new UiValidationError(
        `${path}.options[${i}].value: must be a non-empty string`,
      );
    }
    const label = o.label;
    if (typeof label !== "string" || label.length === 0) {
      throw new UiValidationError(
        `${path}.options[${i}].label: must be a non-empty string`,
      );
    }
    if (seenValues.has(value)) {
      throw new UiValidationError(
        `${path}.options[${i}]: duplicate option value "${value}"`,
      );
    }
    seenValues.add(value);
    options.push({ value, label });
  }
  const out: UiRadioGroup = { kind: "RadioGroup", id, options };
  const value = optString(r.value, path, "value");
  if (value !== undefined) {
    if (!seenValues.has(value)) {
      throw new UiValidationError(
        `${path}.value: must match one of the options' value`,
      );
    }
    out.value = value;
  }
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

function parseSlider(
  r: Record<string, unknown>,
  path: string,
  id: string,
): UiSlider {
  const min = r.min;
  const max = r.max;
  const value = r.value;
  if (typeof min !== "number" || !Number.isFinite(min)) {
    throw new UiValidationError(
      `${path}.min: must be a finite number`,
    );
  }
  if (typeof max !== "number" || !Number.isFinite(max)) {
    throw new UiValidationError(
      `${path}.max: must be a finite number`,
    );
  }
  if (min >= max) {
    throw new UiValidationError(`${path}: min must be < max`);
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new UiValidationError(
      `${path}.value: must be a finite number`,
    );
  }
  const out: UiSlider = { kind: "Slider", id, min, max, value };
  if (r.step !== undefined && r.step !== null) {
    if (typeof r.step !== "number" || !Number.isFinite(r.step) || r.step <= 0) {
      throw new UiValidationError(
        `${path}.step: must be a positive finite number when provided`,
      );
    }
    out.step = r.step;
  }
  const onChangeEvent = optString(r.onChangeEvent, path, "onChangeEvent");
  if (onChangeEvent !== undefined) out.onChangeEvent = onChangeEvent;
  return out;
}

// ---- Batch 4 modal validators ----
//
// Modals carry their own `id` namespace and (for AlertDialog / ActionSheet)
// their own list of action `eventId`s. We re-use the existing `seen` set
// from `validateUiTree` only for [UiBottomSheet.child] — its child is a
// full `UiNode` tree that must abide by the same per-tree id-uniqueness
// rule as a `ui.render` payload. Top-level modal ids are unique across
// the modal's own action set (so a plugin can't ship two actions with
// the same `eventId` and ambiguate the routing).

/// Validate a [UiAlertDialog] payload. Throws [UiValidationError] for
/// any shape problem. Used by `host.ts::handleShowAlert`.
export function validateAlertDialog(raw: unknown): UiAlertDialog {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError("alert must be an object");
  }
  const r = raw as Record<string, unknown>;
  const id = r.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new UiValidationError("alert.id must be a non-empty string");
  }
  const title = r.title;
  if (typeof title !== "string" || title.length === 0) {
    throw new UiValidationError("alert.title must be a non-empty string");
  }
  const rawActions = r.actions;
  if (!Array.isArray(rawActions) || rawActions.length === 0) {
    throw new UiValidationError("alert.actions must be a non-empty array");
  }
  const actions: UiAlertAction[] = [];
  const seenEventIds = new Set<string>();
  for (let i = 0; i < rawActions.length; i++) {
    const a = rawActions[i];
    if (!a || typeof a !== "object" || Array.isArray(a)) {
      throw new UiValidationError(`alert.actions[${i}]: must be an object`);
    }
    const aa = a as Record<string, unknown>;
    const label = aa.label;
    if (typeof label !== "string" || label.length === 0) {
      throw new UiValidationError(
        `alert.actions[${i}].label: must be a non-empty string`,
      );
    }
    const eventId = aa.eventId;
    if (typeof eventId !== "string" || eventId.length === 0) {
      throw new UiValidationError(
        `alert.actions[${i}].eventId: must be a non-empty string`,
      );
    }
    if (seenEventIds.has(eventId)) {
      throw new UiValidationError(
        `alert.actions[${i}]: duplicate eventId "${eventId}"`,
      );
    }
    seenEventIds.add(eventId);
    const out: UiAlertAction = { label, eventId };
    if (aa.variant !== undefined && aa.variant !== null) {
      if (typeof aa.variant !== "string" || !ALERT_VARIANTS.has(aa.variant)) {
        throw new UiValidationError(
          `alert.actions[${i}].variant: must be "primary" | "danger"`,
        );
      }
      out.variant = aa.variant as UiAlertActionVariant;
    }
    actions.push(out);
  }
  const out: UiAlertDialog = { id, title, actions };
  const body = optString(r.body, "alert", "body");
  if (body !== undefined) out.body = body;
  if (r.dismissible !== undefined && r.dismissible !== null) {
    if (typeof r.dismissible !== "boolean") {
      throw new UiValidationError(
        "alert.dismissible: must be a boolean when provided",
      );
    }
    out.dismissible = r.dismissible;
  }
  return out;
}

/// Validate a [UiActionSheet] payload.
export function validateActionSheet(raw: unknown): UiActionSheet {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError("actionSheet must be an object");
  }
  const r = raw as Record<string, unknown>;
  const id = r.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new UiValidationError("actionSheet.id must be a non-empty string");
  }
  const rawActions = r.actions;
  if (!Array.isArray(rawActions) || rawActions.length === 0) {
    throw new UiValidationError(
      "actionSheet.actions must be a non-empty array",
    );
  }
  const actions: UiActionSheetAction[] = [];
  const seenEventIds = new Set<string>();
  for (let i = 0; i < rawActions.length; i++) {
    const a = rawActions[i];
    if (!a || typeof a !== "object" || Array.isArray(a)) {
      throw new UiValidationError(
        `actionSheet.actions[${i}]: must be an object`,
      );
    }
    const aa = a as Record<string, unknown>;
    const label = aa.label;
    if (typeof label !== "string" || label.length === 0) {
      throw new UiValidationError(
        `actionSheet.actions[${i}].label: must be a non-empty string`,
      );
    }
    const eventId = aa.eventId;
    if (typeof eventId !== "string" || eventId.length === 0) {
      throw new UiValidationError(
        `actionSheet.actions[${i}].eventId: must be a non-empty string`,
      );
    }
    if (seenEventIds.has(eventId)) {
      throw new UiValidationError(
        `actionSheet.actions[${i}]: duplicate eventId "${eventId}"`,
      );
    }
    seenEventIds.add(eventId);
    const out: UiActionSheetAction = { label, eventId };
    const icon = optString(aa.icon, `actionSheet.actions[${i}]`, "icon");
    if (icon !== undefined) out.icon = icon;
    const accent = optAccent(aa.accent, `actionSheet.actions[${i}]`, "accent");
    if (accent !== undefined) out.accent = accent;
    actions.push(out);
  }
  const out: UiActionSheet = { id, actions };
  const title = optString(r.title, "actionSheet", "title");
  if (title !== undefined) out.title = title;
  const dismissEventId = optString(
    r.dismissEventId,
    "actionSheet",
    "dismissEventId",
  );
  if (dismissEventId !== undefined) out.dismissEventId = dismissEventId;
  return out;
}

/// Validate a [UiBottomSheet] payload. The `child` is parsed through
/// [validateUiTree] so it abides by the same shape + per-tree id
/// uniqueness rule as a `ui.render` payload.
export function validateBottomSheet(raw: unknown): UiBottomSheet {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new UiValidationError("bottomSheet must be an object");
  }
  const r = raw as Record<string, unknown>;
  const id = r.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new UiValidationError("bottomSheet.id must be a non-empty string");
  }
  if (r.child === undefined || r.child === null) {
    throw new UiValidationError("bottomSheet.child: must be a UiNode object");
  }
  const child = validateUiTree(r.child);
  const out: UiBottomSheet = { id, child };
  const title = optString(r.title, "bottomSheet", "title");
  if (title !== undefined) out.title = title;
  const dismissEventId = optString(
    r.dismissEventId,
    "bottomSheet",
    "dismissEventId",
  );
  if (dismissEventId !== undefined) out.dismissEventId = dismissEventId;
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

// ----- file:// URL extraction + gating (Batch 3 fs gating) -----
//
// `UiImage` and `UiAvatar` can carry a `file://…` src. The host gates
// such URLs against the calling plugin's manifest `fs` capability AND
// the active workspace root. Centralizing the gate here keeps the
// policy next to the schema it's gating; the host wires
// `validateFileUrlsAgainstWorkspace` into `ui.render` after the tree
// validates.
//
// Security boundary: this gate must be at least as strict as the
// `fs.*` RPC isolation (CLAUDE.md guarantee: "symlinks cannot escape
// root"). Concretely:
//   * Paths are realpath-resolved before the prefix check — a symlink
//     inside the workspace that points at `/etc/passwd` is rejected,
//     matching `resolveCallerPath` in workspace.ts.
//   * Non-existent paths reject (`outsideWorkspace`) rather than
//     accepting lexically. The renderer's `FileImage` would just paint
//     a broken-image placeholder anyway; collapsing into the same
//     outcome here keeps the gate symmetric with `fs.readFile`, which
//     also rejects on ENOENT.
//   * Malformed `file://` URLs (bad percent-encoding) are dropped from
//     the site list entirely — the renderer treats unknown URL
//     schemes as broken images, so we mirror that posture instead of
//     leaking a half-decoded path into the prefix check.

export interface FileUrlSite {
  /// Absolute, decoded filesystem path the `file://` URL points at.
  /// Not realpath-resolved yet — the gate does that synchronously
  /// inside `validateFileUrlsAgainstWorkspace`.
  rawPath: string;
  /// Dot-path of the offending node inside the tree, for error reporting.
  path: string;
}

/// Result of [validateFileUrlsAgainstWorkspace] — `ok` means every
/// `file://` URL in the tree (if any) cleared the capability, the
/// workspace-prefix check, AND the symlink-realpath check. Otherwise
/// `error` carries the first violation so the caller can map it to a
/// JSON-RPC error frame.
export type FileUrlGateResult =
  | { ok: true }
  | {
      ok: false;
      code:
        | "capabilityNotDeclared"
        | "outsideWorkspace"
        | "noActiveWorkspace";
      message: string;
    };

/// Apply the Batch-3 `file://` URL gate to a validated tree.
///
/// Async because we `fs.realpath` each `file://` target — a lexical-
/// only check could be bypassed by a symlink inside the workspace that
/// points outside it (e.g. `/srv/ws/evil → /etc/passwd`). The `fs.*`
/// RPCs use the same `realpath` discipline (see `resolveCallerPath`
/// in workspace.ts); this gate must not be weaker than that boundary.
///
/// Rules:
///   * No `file://` URLs in the tree → `{ ok: true }` regardless of caps.
///   * Plugin's manifest `fs` ∈ {"read", "readwrite"} → required for any
///     `file://` URL. Otherwise → `capabilityNotDeclared`.
///   * `workspaceRoot === null` (no active workspace) → `noActiveWorkspace`.
///   * The realpath-resolved path must lie inside the realpath-resolved
///     workspace root. Symlinks that escape → `outsideWorkspace`.
///     Paths that don't exist (or are not absolute) → `outsideWorkspace`
///     so the gate is symmetric with the `fs.*` RPCs' ENOENT handling.
export async function validateFileUrlsAgainstWorkspace(
  tree: UiNode,
  fsCap: "none" | "read" | "readwrite",
  workspaceRoot: string | null,
): Promise<FileUrlGateResult> {
  const sites = collectFileUrls(tree);
  if (sites.length === 0) return { ok: true };
  if (fsCap !== "read" && fsCap !== "readwrite") {
    return {
      ok: false,
      code: "capabilityNotDeclared",
      message: `${sites[0].path} uses file:// but plugin did not declare capabilities.fs`,
    };
  }
  if (workspaceRoot === null) {
    return {
      ok: false,
      code: "noActiveWorkspace",
      message: `${sites[0].path} uses file:// but no workspace is currently active`,
    };
  }
  // Realpath-resolve the workspace root once. If the workspace root
  // itself can't be resolved we have to refuse every site — that's
  // a pathological config and falling open would be unsafe.
  let resolvedRoot: string;
  try {
    resolvedRoot = await fs.realpath(workspaceRoot);
  } catch {
    return {
      ok: false,
      code: "outsideWorkspace",
      message: `cannot realpath workspace root ${workspaceRoot}`,
    };
  }
  for (const site of sites) {
    // The decoded path must be absolute. Relative file:// URLs are
    // ill-formed and we treat them as outside-workspace rather than
    // trying to anchor them anywhere.
    if (!isAbsolute(site.rawPath)) {
      return {
        ok: false,
        code: "outsideWorkspace",
        message: `${site.path} file:// path "${site.rawPath}" is not absolute`,
      };
    }
    const normalized = normalize(site.rawPath);
    let resolved: string;
    try {
      resolved = await fs.realpath(normalized);
    } catch {
      // ENOENT / EACCES / etc. → collapse into "outside workspace"
      // for two reasons:
      //   1. The `fs.*` RPCs do the same collapse so a plugin can't
      //      probe filesystem layout via differential error messages.
      //   2. The renderer will paint a broken-image placeholder
      //      anyway — there's no reason to forward a render that
      //      can't load.
      return {
        ok: false,
        code: "outsideWorkspace",
        message: `${site.path} file:// path "${site.rawPath}" is outside the active workspace`,
      };
    }
    if (!pathIsInside(resolved, resolvedRoot)) {
      return {
        ok: false,
        code: "outsideWorkspace",
        message: `${site.path} file:// path "${site.rawPath}" is outside the active workspace`,
      };
    }
  }
  return { ok: true };
}

/// Walk `tree` and collect every `file://` URL it references. Returns
/// an empty array if no UiImage / UiAvatar carries a file:// src.
///
/// The walker is exhaustive on `UiNode.kind` — every container kind
/// recurses into its children explicitly, every leaf kind returns
/// without recursing, and the final `assertNever` makes TypeScript
/// fail the build when a future widget adds nested content without
/// updating this walker. Silently skipping a future container would
/// degrade the security boundary, so the strictness is intentional.
export function collectFileUrls(tree: UiNode): FileUrlSite[] {
  const out: FileUrlSite[] = [];
  walk(tree, "$");
  return out;

  function walk(node: UiNode, path: string): void {
    switch (node.kind) {
      case "Column":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "Row":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "Section":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "Card":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "List":
        node.items.forEach((c, i) => walk(c, `${path}.items[${i}]`));
        return;
      case "ListTile":
        if (node.leading !== undefined) walk(node.leading, `${path}.leading`);
        if (node.trailing !== undefined) walk(node.trailing, `${path}.trailing`);
        return;
      case "Image":
        check(node.src, path);
        return;
      case "Avatar":
        if (node.src !== undefined) check(node.src, path);
        return;
      case "Grid":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "Stack":
        node.children.forEach((c, i) => walk(c, `${path}.children[${i}]`));
        return;
      case "Aspect":
        walk(node.child, `${path}.child`);
        return;
      case "Flex":
        walk(node.child, `${path}.child`);
        return;
      case "Scroll":
        walk(node.child, `${path}.child`);
        return;
      // ---- Leaf / non-container kinds: nothing to recurse into ----
      case "Text":
      case "Spacer":
      case "TextField":
      case "Button":
      case "Icon":
      case "Badge":
      case "AppGrid":
      case "Switch":
      case "Select":
      case "Banner":
      case "Divider":
      case "Markdown":
      case "CodeBlock":
      case "Progress":
      case "Spinner":
      case "TabBar":
      case "SearchField":
      case "Checkbox":
      case "RadioGroup":
      case "Slider":
        return;
      default:
        // Compile-time exhaustiveness: if a new UiNode kind is added
        // to the union and this switch isn't updated, `node` here is
        // not `never` and TypeScript refuses the assignment below.
        assertNever(node);
    }
  }

  function check(src: string, path: string): void {
    if (!src.startsWith("file://")) return;
    let decoded: string;
    try {
      decoded = decodeURIComponent(src.substring("file://".length));
    } catch {
      // Malformed percent-encoding. We drop the site entirely — the
      // renderer treats unknown / unparseable URL schemes as broken
      // images, and forwarding a half-decoded path would either
      // false-accept (if the raw bytes happen to share the workspace
      // prefix) or fail with a confusing "outside workspace" error.
      // Dropping is the symmetric outcome.
      return;
    }
    out.push({ rawPath: decoded, path });
  }
}

/// Compile-time exhaustiveness assertion. Reachable only when a new
/// `UiNode.kind` lands without a matching `case` in `collectFileUrls`'s
/// walker — at which point TypeScript fails the assignment because the
/// inferred type isn't `never`. Runtime is unreachable in well-typed
/// code; we still throw so a JS-only consumer gets a loud signal
/// instead of silent under-coverage.
function assertNever(node: never): never {
  throw new Error(
    `collectFileUrls walker missing case for ${JSON.stringify(node)}`,
  );
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

  /// Fan a modal push (`ui.modal`) out to every subscriber. Used by
  /// Batch 4's imperative `ui.showAlert` / `ui.showActionSheet` /
  /// `ui.showBottomSheet` host methods. Modals live OFF the `ui.tree`
  /// version stream — they have no per-panel monotonic version and no
  /// retirement push; the client manages their lifetime via the regular
  /// `ui.event` flow (action pick or dismiss).
  ///
  /// Returns the number of subscribers the push reached so the caller
  /// can surface "no UI attached" through `ui.show*`'s response.
  public broadcastModal(payload: UiModalPush): number {
    let n = 0;
    for (const ws of this.subscribers) {
      this.notify(ws, "ui.modal", payload);
      n++;
    }
    return n;
  }
}

/// Discriminated payload for the `ui.modal` notification. The `kind`
/// matches the `ui.show*` method name's suffix so the client's switch
/// reads naturally; the `pluginId` + `panelId` pair routes the
/// follow-up `ui.event` back to the right plugin.
export type UiModalPush =
  | {
      kind: "alert";
      pluginId: string;
      panelId: string;
      alert: UiAlertDialog;
    }
  | {
      kind: "actionSheet";
      pluginId: string;
      panelId: string;
      sheet: UiActionSheet;
    }
  | {
      kind: "bottomSheet";
      pluginId: string;
      panelId: string;
      sheet: UiBottomSheet;
    };

function makeKey(pluginId: string, panelId: string): string {
  return `${pluginId} ${panelId}`;
}
