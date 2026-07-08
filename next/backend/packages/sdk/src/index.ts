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
/// Eyes-free focus role hint for accessibility / voice surfaces.
export type UiFocusRole = "status" | "action" | "input" | "danger";

/// `StyleSlot` is the union of "raw pixel/color value" and "named token".
/// Numbers stay accepted for back-compat (existing `gap: 8` keeps working)
/// while new code can write `gap: "sm"`. Renderer resolves both.
export type StyleSlot<TToken extends string> = number | TToken;

export interface UiNodeMetadata {
  accessibilityLabel?: string;
  accessibilityHint?: string;
  spokenValue?: string;
  focusRole?: UiFocusRole;
  focusOrder?: number;
  voiceInputEvent?: string;
  voiceShortcut?: boolean;
}

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
  /// When `true`, the renderer adds a tap-to-expand-collapse header
  /// chevron. Default state is expanded; the host persists expand/
  /// collapse state per node id across re-renders. Omitted = not
  /// collapsible (always expanded, no chevron).
  collapsible?: boolean;
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

// ---- Batch 3 new widgets (§4.3) — rich display ----

/// `BoxFit` for [UiImage]. Matches the doc spec subset; not the full
/// Flutter enum — we stay narrow on purpose so a plugin author cannot
/// reach for `fitWidth` and assume it works everywhere.
export type UiImageFit = "cover" | "contain" | "fill";

/// Network / inline image. `src` accepts three URL schemes:
///   * `https://…`           — network image (no plugin caps required)
///   * `data:image/...;base64,…` — inline image (no plugin caps required)
///   * `file://…`            — local filesystem; host **gates this on
///                             the plugin's `fs: 'read'` capability AND
///                             requires the path to resolve inside the
///                             active workspace root**. Plugins without
///                             `fs: 'read'` get a `capabilityNotDeclared`
///                             RPC error on `ui.render`.
///
/// Unknown URL scheme → host renders a broken-image placeholder.
export interface UiImage {
  kind: "Image";
  id: string;
  src: string;
  fit?: UiImageFit;
  size?: StyleSlot<SizeToken>;
}

/// Profile circle. With `src` → renders the image (same URL schemes as
/// [UiImage], same fs gating for `file://`). Without `src` → renders
/// the first 1–2 characters of `initial` on a deterministic color
/// hashed from `initial` (Linear / Telegram convention). `accent`
/// overrides the hash color.
///
/// Always rendered as a circle.
export interface UiAvatar {
  kind: "Avatar";
  id: string;
  src?: string;
  initial?: string;
  size?: StyleSlot<SizeToken>;
  accent?: AccentToken;
}

/// Strict-subset Markdown. The renderer accepts headings h1–h4,
/// paragraphs, lists (ordered/unordered, nested), code blocks (triple-
/// backtick), inline code, links, bold, italic, blockquotes, horizontal
/// rules. **No raw HTML, no tables, no images, no nested HTML.**
/// Out-of-subset constructs render as plain text — the renderer never
/// throws on a markdown input.
export interface UiMarkdown {
  kind: "Markdown";
  id: string;
  markdown: string;
}

/// Pre-formatted source code block. `language` is a highlight.js-style
/// identifier; unknown languages render as plain monospace. Reuses the
/// app's existing `flutter_highlight` stack — there is no second syntax-
/// highlighting pipeline in the renderer.
export interface UiCodeBlock {
  kind: "CodeBlock";
  id: string;
  code: string;
  language?: string;
}

export type UiProgressVariant = "linear" | "circular";

/// Progress indicator. `value` is in [0, 1]; omitted/null → indeterminate
/// progress. Default `variant` is `linear`. `label` is rendered below
/// (linear) or to the right (circular).
export interface UiProgress {
  kind: "Progress";
  id: string;
  value?: number;
  variant?: UiProgressVariant;
  label?: string;
  accent?: AccentToken;
}

/// Indeterminate spinner. `label` is rendered to the right of the
/// spinner; `size` controls the spinner diameter.
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
/// the optional `alignment` (default: `center`). Same nine-point
/// alignment grid as Flutter's `Alignment`.
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

/// Aspect-ratio enforcer. `ratio` is width / height (so `16/9 ≈ 1.78`
/// for landscape video). Renderer sizes the child to fill the available
/// width and computes height from `ratio`.
export interface UiAspect {
  kind: "Aspect";
  id: string;
  ratio: number;
  child: UiNode;
}

/// Flex distribution hint for a child of [UiRow] / [UiColumn]. Wrapping
/// a node in `UiFlex { flex: 2 }` claims 2 shares of the leftover main-
/// axis space relative to its siblings. Outside a Row/Column the
/// renderer falls back to the bare child without taking extra space.
export interface UiFlex {
  kind: "Flex";
  id: string;
  flex: number;
  child: UiNode;
}

/// Explicit scroll region. `axis` defaults to `vertical`. Use when the
/// panel root scroller is insufficient (e.g. a horizontal carousel of
/// cards inside a vertically-scrolling panel).
export type UiScrollAxis = "vertical" | "horizontal";
export interface UiScroll {
  kind: "Scroll";
  id: string;
  axis?: UiScrollAxis;
  child: UiNode;
}

/// Segmented tab control. `activeId` must match one of `tabs[*].id`
/// (the renderer falls back to the first tab if not). Tapping a tab
/// fires `onChangeEvent` with `payload: { tabId }`. The host shows
/// the chrome only — switching panel content on tap is the plugin's
/// responsibility.
export interface UiTabBarTab {
  id: string;
  label: string;
  /// Optional Feather catalog name. Unknown names render no icon.
  icon?: string;
}
export interface UiTabBar {
  kind: "TabBar";
  id: string;
  tabs: UiTabBarTab[];
  activeId: string;
  onChangeEvent?: string;
}

/// Search variant of [UiTextField]. The renderer adds a leading
/// magnifier icon + a trailing clear button (appears only when the
/// field has content). `onChangeEvent` carries `payload: { value }`
/// the same way [UiTextField] does.
export interface UiSearchField {
  kind: "SearchField";
  id: string;
  value?: string;
  placeholder?: string;
  onChangeEvent?: string;
}

/// Standalone checkbox + optional label. Same reconciliation contract
/// as [UiSwitch]: the renderer flips locally on tap and fires
/// `onChangeEvent` with `payload: { value: boolean }`; the plugin's
/// next render is authoritative.
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
/// [UiSwitch] / [UiCheckbox]: optimistic local update on tap +
/// authoritative plugin re-render. Event payload is
/// `{ value: string }`.
export interface UiRadioGroup {
  kind: "RadioGroup";
  id: string;
  options: UiRadioOption[];
  value?: string;
  onChangeEvent?: string;
}

/// Continuous (omit `step`) or stepped (with `step`) slider. `value`
/// is clamped to `[min, max]` by the renderer; `min` must be < `max`.
/// Same reconciliation contract as the other inputs.
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
// These live OFF the declarative `ui.tree`. The plugin calls one of the
// three `showAlert` / `showActionSheet` / `showBottomSheet` methods on
// `PluginContext`, the host pushes a `ui.modal` notification to the app,
// and the user's pick comes back through the regular `onUiEvent` flow
// (carrying the `eventId` configured on the picked action).

export type UiAlertActionVariant = "primary" | "danger";

export interface UiAlertAction {
  label: string;
  eventId: string;
  variant?: UiAlertActionVariant;
}

export interface UiAlertDialog {
  id: string;
  title: string;
  body?: string;
  actions: UiAlertAction[];
  /// Default `true`. Set to `false` to block tap-outside / back-press
  /// dismissal — only the configured action buttons can resolve the
  /// dialog (typical for "data will be lost" confirmations).
  dismissible?: boolean;
}

export interface UiActionSheetAction {
  label: string;
  icon?: string;
  eventId: string;
  accent?: AccentToken;
}

export interface UiActionSheet {
  id: string;
  title?: string;
  actions: UiActionSheetAction[];
  /// Optional eventId fired on tap-outside / back-press. Omitted =
  /// silent dismiss.
  dismissEventId?: string;
}

export interface UiBottomSheet {
  id: string;
  title?: string;
  child: UiNode;
  dismissEventId?: string;
}

/// Constructors mirroring the §4.3 widget vocabulary. IDs may be
/// omitted; an omitted id is replaced with `crypto.randomUUID()` so the
/// host's "every node must have a unique id" validation always
/// succeeds. When the plugin author supplies an id it is passed through
/// verbatim — that is the only way to keep focus / scroll state alive
/// across re-renders.
export const ui = {
  withMetadata<T extends { id: string; kind: string }>(
    node: T,
    metadata: UiNodeMetadata,
  ): T & UiNodeMetadata {
    return Object.assign(node, metadata);
  },
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
    collapsible?: boolean;
    children: UiNode[];
  }): UiSection {
    const out: UiSection = {
      kind: "Section",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.title !== undefined) out.title = p.title;
    if (p.variant !== undefined) out.variant = p.variant;
    if (p.collapsible !== undefined) out.collapsible = p.collapsible;
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
  image(p: {
    id?: string;
    src: string;
    fit?: UiImageFit;
    size?: StyleSlot<SizeToken>;
  }): UiImage {
    const out: UiImage = { kind: "Image", id: ensureId(p.id), src: p.src };
    if (p.fit !== undefined) out.fit = p.fit;
    if (p.size !== undefined) out.size = p.size;
    return out;
  },
  avatar(
    p: {
      id?: string;
      src?: string;
      initial?: string;
      size?: StyleSlot<SizeToken>;
      accent?: AccentToken;
    } = {},
  ): UiAvatar {
    const out: UiAvatar = { kind: "Avatar", id: ensureId(p.id) };
    if (p.src !== undefined) out.src = p.src;
    if (p.initial !== undefined) out.initial = p.initial;
    if (p.size !== undefined) out.size = p.size;
    if (p.accent !== undefined) out.accent = p.accent;
    return out;
  },
  markdown(p: { id?: string; markdown: string }): UiMarkdown {
    return {
      kind: "Markdown",
      id: ensureId(p.id),
      markdown: p.markdown,
    };
  },
  codeBlock(p: {
    id?: string;
    code: string;
    language?: string;
  }): UiCodeBlock {
    const out: UiCodeBlock = {
      kind: "CodeBlock",
      id: ensureId(p.id),
      code: p.code,
    };
    if (p.language !== undefined) out.language = p.language;
    return out;
  },
  progress(p: {
    id?: string;
    value?: number;
    variant?: UiProgressVariant;
    label?: string;
    accent?: AccentToken;
  } = {}): UiProgress {
    const out: UiProgress = { kind: "Progress", id: ensureId(p.id) };
    if (p.value !== undefined) out.value = p.value;
    if (p.variant !== undefined) out.variant = p.variant;
    if (p.label !== undefined) out.label = p.label;
    if (p.accent !== undefined) out.accent = p.accent;
    return out;
  },
  spinner(p: {
    id?: string;
    label?: string;
    size?: StyleSlot<SizeToken>;
  } = {}): UiSpinner {
    const out: UiSpinner = { kind: "Spinner", id: ensureId(p.id) };
    if (p.label !== undefined) out.label = p.label;
    if (p.size !== undefined) out.size = p.size;
    return out;
  },
  // ---- Batch 5 constructors ----
  grid(p: {
    id?: string;
    children: UiNode[];
    columns: UiGridColumns;
    gap?: StyleSlot<SpacingToken>;
  }): UiGrid {
    const out: UiGrid = {
      kind: "Grid",
      id: ensureId(p.id),
      children: p.children,
      columns: p.columns,
    };
    if (p.gap !== undefined) out.gap = p.gap;
    return out;
  },
  stack(p: {
    id?: string;
    children: UiNode[];
    alignment?: UiStackAlignment;
  }): UiStack {
    const out: UiStack = {
      kind: "Stack",
      id: ensureId(p.id),
      children: p.children,
    };
    if (p.alignment !== undefined) out.alignment = p.alignment;
    return out;
  },
  aspect(p: { id?: string; ratio: number; child: UiNode }): UiAspect {
    return {
      kind: "Aspect",
      id: ensureId(p.id),
      ratio: p.ratio,
      child: p.child,
    };
  },
  flex(p: { id?: string; flex: number; child: UiNode }): UiFlex {
    return {
      kind: "Flex",
      id: ensureId(p.id),
      flex: p.flex,
      child: p.child,
    };
  },
  scroll(p: {
    id?: string;
    axis?: UiScrollAxis;
    child: UiNode;
  }): UiScroll {
    const out: UiScroll = {
      kind: "Scroll",
      id: ensureId(p.id),
      child: p.child,
    };
    if (p.axis !== undefined) out.axis = p.axis;
    return out;
  },
  tabBar(p: {
    id?: string;
    tabs: UiTabBarTab[];
    activeId: string;
    onChangeEvent?: string;
  }): UiTabBar {
    const out: UiTabBar = {
      kind: "TabBar",
      id: ensureId(p.id),
      tabs: p.tabs,
      activeId: p.activeId,
    };
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  searchField(
    p: {
      id?: string;
      value?: string;
      placeholder?: string;
      onChangeEvent?: string;
    } = {},
  ): UiSearchField {
    const out: UiSearchField = { kind: "SearchField", id: ensureId(p.id) };
    if (p.value !== undefined) out.value = p.value;
    if (p.placeholder !== undefined) out.placeholder = p.placeholder;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  checkbox(p: {
    id?: string;
    label?: string;
    value: boolean;
    onChangeEvent?: string;
  }): UiCheckbox {
    const out: UiCheckbox = {
      kind: "Checkbox",
      id: ensureId(p.id),
      value: p.value,
    };
    if (p.label !== undefined) out.label = p.label;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  radioGroup(p: {
    id?: string;
    options: UiRadioOption[];
    value?: string;
    onChangeEvent?: string;
  }): UiRadioGroup {
    const out: UiRadioGroup = {
      kind: "RadioGroup",
      id: ensureId(p.id),
      options: p.options,
    };
    if (p.value !== undefined) out.value = p.value;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },
  slider(p: {
    id?: string;
    min: number;
    max: number;
    step?: number;
    value: number;
    onChangeEvent?: string;
  }): UiSlider {
    const out: UiSlider = {
      kind: "Slider",
      id: ensureId(p.id),
      min: p.min,
      max: p.max,
      value: p.value,
    };
    if (p.step !== undefined) out.step = p.step;
    if (p.onChangeEvent !== undefined) out.onChangeEvent = p.onChangeEvent;
    return out;
  },

  // ---- Batch 4 modal constructors ----
  alertDialog(p: {
    id?: string;
    title: string;
    body?: string;
    actions: UiAlertAction[];
    dismissible?: boolean;
  }): UiAlertDialog {
    const out: UiAlertDialog = {
      id: ensureId(p.id),
      title: p.title,
      actions: p.actions,
    };
    if (p.body !== undefined) out.body = p.body;
    if (p.dismissible !== undefined) out.dismissible = p.dismissible;
    return out;
  },
  actionSheet(p: {
    id?: string;
    title?: string;
    actions: UiActionSheetAction[];
    dismissEventId?: string;
  }): UiActionSheet {
    const out: UiActionSheet = {
      id: ensureId(p.id),
      actions: p.actions,
    };
    if (p.title !== undefined) out.title = p.title;
    if (p.dismissEventId !== undefined) out.dismissEventId = p.dismissEventId;
    return out;
  },
  bottomSheet(p: {
    id?: string;
    title?: string;
    child: UiNode;
    dismissEventId?: string;
  }): UiBottomSheet {
    const out: UiBottomSheet = {
      id: ensureId(p.id),
      child: p.child,
    };
    if (p.title !== undefined) out.title = p.title;
    if (p.dismissEventId !== undefined) out.dismissEventId = p.dismissEventId;
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

/// Minimal workspace descriptor exposed to plugins. Mirrors the
/// frontend-facing `Workspace` shape from the design doc §4 minus the
/// `createdAt` timestamp — plugins react to "the user switched
/// workspaces"; lifecycle timing is the host's concern.
///
/// `id` is the same UUID the backend issues for the workspace; it is
/// stable across reconnect so a plugin can persist per-workspace state
/// keyed by it. `root` is the absolute filesystem path (post-symlink
/// canonical form); `label` is the user-visible name (typically the
/// basename of `root`).
export interface WorkspaceRef {
  id: string;
  root: string;
  label: string;
}

// ---------------------------------------------------------------------
// Notification surface (Phase 6A). Mirrors the host's wire shape from
// `next/backend/src/notifications.ts` so plugins do not need to import
// across packages. The host validates this payload on receipt and
// silently overrides `source` to the plugin's manifest id (a plugin
// cannot impersonate another `source` like "system" or another
// plugin's id).
// ---------------------------------------------------------------------

export type NotificationLevel = "info" | "success" | "warning" | "error";

export interface NotificationField {
  key: string;
  value: string;
}

export interface NotificationLink {
  title: string;
  url: string;
}

export type NotificationAction =
  | { kind: "open-url"; url: string }
  | { kind: "copy"; text: string }
  | { kind: "open-workspace"; workspaceId: string }
  | {
      kind: "open-terminal";
      sessionId?: string;
      backendId?: string;
      externalSessionId?: string;
    };

export interface NotificationSpoken {
  title?: string;
  body: string;
  detail?: string;
}

export interface NotificationReplyTargetPlugin {
  kind: "plugin";
  pluginId: string;
  panelId?: string;
}

export type NotificationReplyTarget = NotificationReplyTargetPlugin;

export interface NotificationReply {
  /// Optional for plugin-authored notifications: the host injects and
  /// overrides this to `{ kind: "plugin", pluginId: <this plugin> }`.
  target?: NotificationReplyTarget;
  event?: string;
  context?: unknown;
  placeholder?: string;
  confirmRequired?: boolean;
}

/// Inbound payload a plugin hands to `ctx.showNotification`. The host
/// overrides `source` to the plugin's id on receipt — supplying anything
/// else here is harmless, and omitting it is the normal plugin path.
export interface NotificationInput {
  source?: string;
  level: NotificationLevel;
  title: string;
  body?: string;
  fields?: NotificationField[];
  links?: NotificationLink[];
  action?: NotificationAction;
  spoken?: NotificationSpoken;
  reply?: NotificationReply;
  groupKey?: string;
  supersedes?: string;
  important?: boolean;
  ttl?: number;
  timestamp?: number;
  widget?: unknown;
}

export interface NotificationReplyInput {
  notificationId: string;
  text: string;
  pluginId?: string;
  panelId?: string;
  event?: string;
  context?: unknown;
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
  /// Open a Material AlertDialog. The host returns `{ delivered: true }`
  /// once the push has been broadcast to subscribed clients; the user's
  /// pick comes back through `onUiEvent` carrying the picked action's
  /// `eventId`. If `dismissible: false`, the dialog is modal — only the
  /// action buttons can resolve it.
  // Resolves once the host has broadcast the modal — does NOT wait for
  // the user to pick. Wire user choices via onUiEvent.
  showAlert(
    panelId: string,
    alert: UiAlertDialog,
  ): Promise<{ delivered: boolean }>;
  /// Open a platform-native action sheet (iOS-style on iOS,
  /// modal-bottom-sheet list on Android). The user's pick comes back
  /// through `onUiEvent`; tap-outside / back-press fires
  /// `dismissEventId` if configured, otherwise silently dismisses.
  // Resolves once the host has broadcast the modal — does NOT wait for
  // the user to pick. Wire user choices via onUiEvent.
  showActionSheet(
    panelId: string,
    sheet: UiActionSheet,
  ): Promise<{ delivered: boolean }>;
  /// Open a generic modal bottom sheet rendering an arbitrary [UiNode]
  /// `child` via `UiRenderer`. The host re-applies the Batch-3 `file://`
  /// fs-capability gate to the child tree at this entry point — a
  /// BottomSheet child that points outside the active workspace will
  /// be rejected before the push is broadcast.
  // Resolves once the host has broadcast the modal — does NOT wait for
  // the user to pick. Wire user choices via onUiEvent.
  // TODO(v1): ui.dismissModal(modalId) — plugin-driven close path.
  showBottomSheet(
    panelId: string,
    sheet: UiBottomSheet,
  ): Promise<{ delivered: boolean }>;
  /// Read the currently-active workspace from the host. Returns `null`
  /// when no workspace is active (fresh backend with no workspaces open,
  /// or the user just closed the last one). Round-trips a
  /// `workspace.current` request to the host; gated by the manifest's
  /// `fs` capability per §3.6 (the `workspace.*` namespace already maps
  /// to `fs`). Plugins without `fs` capability get a `capabilityNotDeclared`
  /// rejection.
  ///
  /// This is the canonical way to do the initial read on activation —
  /// `onWorkspaceActivated` does NOT fire on plugin startup, so the
  /// usual shape is: `await ctx.currentWorkspace()` inside `onActivate`,
  /// then react to `onWorkspaceActivated` for subsequent switches.
  currentWorkspace(): Promise<WorkspaceRef | null>;
  /// Fire a user-facing notification through the host's notification
  /// store + WS fan-out (§4.5). Round-trips a `notify.show` request;
  /// gated by the manifest's `ui` capability. The host overrides
  /// `input.source` to the plugin's id before persistence — plugins
  /// cannot impersonate `"system"` or another plugin's id. Returns the
  /// server-assigned notification id so the plugin can correlate it
  /// with later `supersedes` calls.
  showNotification(input: NotificationInput): Promise<{ id: string }>;
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
  /// Invoked when the user activates a different workspace, or when the
  /// last open workspace is closed (in which case `workspace` is
  /// `null`). Does NOT fire on plugin startup — the activation hook
  /// already runs once, and the canonical way to get the initial value
  /// is `ctx.currentWorkspace()`. Fan-out is unconditional: every
  /// active plugin process receives the underlying `workspace.activated`
  /// notification regardless of manifest declarations; plugins that
  /// don't supply a callback silently ignore it.
  onWorkspaceActivated?(
    ctx: PluginContext,
    workspace: WorkspaceRef | null,
  ): void | Promise<void>;
  /// Invoked when the app sends an inline reply to a notification whose
  /// `reply.target` resolves to this plugin. The plugin owns backend-specific
  /// interpretation: append to a Codex session, send to a gateway, or ignore.
  onNotificationReply?(
    ctx: PluginContext,
    reply: NotificationReplyInput,
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
        showAlert(panelId, alert): Promise<{ delivered: boolean }> {
          return sendShowRequest("ui.showAlert", { panelId, alert });
        },
        showActionSheet(panelId, sheet): Promise<{ delivered: boolean }> {
          return sendShowRequest("ui.showActionSheet", { panelId, sheet });
        },
        showBottomSheet(panelId, sheet): Promise<{ delivered: boolean }> {
          return sendShowRequest("ui.showBottomSheet", { panelId, sheet });
        },
        currentWorkspace(): Promise<WorkspaceRef | null> {
          return new Promise<WorkspaceRef | null>((resolve, reject) => {
            const id = nextOutboundId++;
            pendingInvokes.set(id, {
              // Host shape: `{ workspace: WorkspaceRef | null }`. Unwrap
              // before surfacing to the caller so the SDK contract matches
              // the doc'd return type.
              resolve: (v) => {
                const r = (v ?? {}) as { workspace?: WorkspaceRef | null };
                resolve(r.workspace ?? null);
              },
              reject,
            });
            writeMessage({
              jsonrpc: "2.0",
              id,
              method: "workspace.current",
              params: {},
            });
          });
        },
        showNotification(input): Promise<{ id: string }> {
          return new Promise<{ id: string }>((resolve, reject) => {
            const id = nextOutboundId++;
            pendingInvokes.set(id, {
              // Host shape: `{ id: <notification-id> }`. We narrow here
              // rather than at the call site so the SDK contract stays
              // crisp even if the host later returns more fields.
              resolve: (v) => {
                const r = (v ?? {}) as { id?: unknown };
                if (typeof r.id !== "string") {
                  reject(
                    new Error(
                      "notify.show response missing string id",
                    ),
                  );
                  return;
                }
                resolve({ id: r.id });
              },
              reject,
            });
            writeMessage({
              jsonrpc: "2.0",
              id,
              method: "notify.show",
              params: { input },
            });
          });
        },
      };

      // Shared sender for the three imperative-modal RPCs. They all
      // share the same request/response wire shape (params object →
      // `{ delivered: true }` on success, JSON-RPC error otherwise), so
      // factoring out the framing keeps the three thin context methods
      // above readable.
      function sendShowRequest(
        method: string,
        params: Record<string, unknown>,
      ): Promise<{ delivered: boolean }> {
        return new Promise<{ delivered: boolean }>((resolve, reject) => {
          const id = nextOutboundId++;
          pendingInvokes.set(id, {
            resolve: (v) => resolve(v as { delivered: boolean }),
            reject,
          });
          writeMessage({
            jsonrpc: "2.0",
            id,
            method,
            params,
          });
        });
      }

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

        if (msg.method === "workspace.activated") {
          // Notification-shaped: the host fires this on every active
          // workspace transition (including → null on the last close).
          // We unwrap the payload, invoke the optional callback, and ack
          // (when the host happened to send an id — current host doesn't,
          // but the response slot stays open in case that changes).
          const params = (msg.params ?? {}) as {
            workspace?: WorkspaceRef | null;
          };
          const wsRef: WorkspaceRef | null =
            params.workspace !== undefined && params.workspace !== null
              ? params.workspace
              : null;
          if (config.onWorkspaceActivated === undefined) {
            // No-op when the plugin didn't subscribe — matches what
            // `ui.event` / `command.invoke` do when their callbacks are
            // absent. Ack only if the host sent a request id.
            respond(msg.id, undefined, {});
            return;
          }
          try {
            await config.onWorkspaceActivated(ctx, wsRef);
          } catch (err) {
            // Notification handler — no JSON-RPC reply to send.
            // Surface the throw via `host.log` so the plugin author
            // sees it, matching `onActivate` above.
            ctx.log(
              "error",
              `onWorkspaceActivated threw: ${(err as Error).message ?? String(err)}`,
            );
          }
          return;
        }

        if (msg.method === "notification.reply") {
          const params = (msg.params ?? {}) as Partial<NotificationReplyInput>;
          if (
            typeof params.notificationId !== "string" ||
            typeof params.text !== "string"
          ) {
            respond(msg.id, {
              code: RPC_ERR_INVALID_PARAMS,
              message:
                "notification.reply params must include string notificationId/text",
            });
            return;
          }
          const reply: NotificationReplyInput = {
            notificationId: params.notificationId,
            text: params.text,
          };
          if (typeof params.pluginId === "string") reply.pluginId = params.pluginId;
          if (typeof params.panelId === "string") reply.panelId = params.panelId;
          if (typeof params.event === "string") reply.event = params.event;
          if (params.context !== undefined) reply.context = params.context;
          if (config.onNotificationReply === undefined) {
            respond(msg.id, undefined, {});
            return;
          }
          try {
            await config.onNotificationReply(ctx, reply);
            respond(msg.id, undefined, {});
          } catch (err) {
            if (msg.id === undefined) {
              ctx.log(
                "error",
                `onNotificationReply threw: ${(err as Error).message ?? String(err)}`,
              );
              return;
            }
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
