// UI descriptor protocol tests (issue #59 / design §4.3).
//
// Covers three responsibilities:
//   * Validation:    `ui.render` with duplicate node ids → -32602 invalidParams.
//   * Fan-out:       3 plugin-emitted `ui.render` calls → 3 `ui.tree` pushes
//                    with strictly monotonic per-panel versions; subscribe-
//                    after-renders replays the current panel snapshot.
//   * Event routing: app→backend `ui.event` reaches the owning plugin and
//                    carries the same payload.
//   * Lifecycle:     plugin exit emits `ui.tree { tree: null }` for every
//                    panel the plugin had registered.
//
// Patterned after rpc.test.ts (synthetic RpcContext + FakeWebSocket) and
// pluginHost.test.ts (real child processes for the plugin side).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import { cp, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  FakeWebSocket,
  makeTempDir,
  rmTempDir,
  sleep,
} from "./_helpers.js";
import { dispatch, RpcError, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { PluginHost } from "../src/plugins/host.js";
import {
  UiPanelRegistry,
  UiValidationError,
  validateActionSheet,
  validateAlertDialog,
  validateBottomSheet,
  validateFileUrlsAgainstWorkspace,
  validateUiTree,
  type UiModalPush,
  type UiPanelSnapshot,
} from "../src/plugins/ui.js";

const FIXTURE_ROOT = join(
  dirname(fileURLToPath(import.meta.url)),
  "fixtures",
  "plugins",
);

interface Harness {
  host: PluginHost;
  state: ProcessState;
  sock: FakeWebSocket;
  ctx: RpcContext;
  logDir: string;
  diagnostics: string[];
}

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-uitest-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function buildHarness(fixtures: string[]): Promise<Harness> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  for (const name of fixtures) {
    await cp(join(FIXTURE_ROOT, name), join(pluginsDir, name), {
      recursive: true,
    });
  }
  const diagnostics: string[] = [];
  const host = new PluginHost({
    pluginsDir,
    logDir,
    logger: (line) => diagnostics.push(line),
    onHostLog: () => {},
  });
  const state = new ProcessState({ pluginHost: host });
  const sock = new FakeWebSocket();
  const ctx: RpcContext = {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: sock as unknown as WebSocket,
    markAuthenticated: () => {},
  };
  await host.start();
  return { host, state, sock, ctx, logDir, diagnostics };
}

async function call<T = unknown>(
  ctx: RpcContext,
  method: string,
  params: unknown = {},
): Promise<T> {
  return (await dispatch(ctx, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  })) as T;
}

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  budgetMs: number,
  stepMs = 25,
): Promise<T> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const v = await predicate();
    if (v !== undefined) return v;
    await sleep(stepMs);
  }
  const v = await predicate();
  if (v !== undefined) return v;
  throw new Error(`waitFor timed out after ${budgetMs}ms`);
}

describe("validateUiTree", () => {
  it("accepts a well-formed tree", () => {
    const tree = validateUiTree({
      kind: "Column",
      id: "root",
      gap: 8,
      children: [
        { kind: "Text", id: "t1", text: "hi" },
        { kind: "Spacer", id: "sp", size: 16 },
        { kind: "Button", id: "b1", label: "Go", style: "primary" },
      ],
    });
    expect(tree.kind).toBe("Column");
    if (tree.kind !== "Column") throw new Error("unreachable");
    expect(tree.children).toHaveLength(3);
  });

  it("rejects duplicate ids across the tree", () => {
    expect(() =>
      validateUiTree({
        kind: "Column",
        id: "root",
        children: [
          { kind: "Text", id: "x", text: "first" },
          {
            kind: "Section",
            id: "sec",
            children: [
              { kind: "Text", id: "x", text: "second" },
            ],
          },
        ],
      }),
    ).toThrow(UiValidationError);
  });

  it("rejects an unknown kind", () => {
    expect(() =>
      validateUiTree({ kind: "Frobnicate", id: "n" }),
    ).toThrow(/unknown node kind/);
  });

  it("rejects a missing id", () => {
    expect(() =>
      validateUiTree({ kind: "Text", text: "no id" }),
    ).toThrow(/id must be a non-empty string/);
  });

  it("rejects an invalid Button style", () => {
    expect(() =>
      validateUiTree({
        kind: "Button",
        id: "btn",
        label: "Click",
        style: "warning",
      }),
    ).toThrow(/style/);
  });

  it("preserves eyes-free metadata on any node", () => {
    const tree = validateUiTree({
      kind: "Text",
      id: "status",
      text: "Done",
      accessibilityLabel: "Agent status",
      accessibilityHint: "Double tap to open details",
      spokenValue: "Agent finished with 3 changed files",
      focusRole: "status",
      focusOrder: 2,
      voiceInputEvent: "voice.reply",
      voiceOutputText: "Agent finished with 3 changed files",
      voiceShortcut: true,
    });
    expect(tree.accessibilityLabel).toBe("Agent status");
    expect(tree.accessibilityHint).toBe("Double tap to open details");
    expect(tree.spokenValue).toBe("Agent finished with 3 changed files");
    expect(tree.focusRole).toBe("status");
    expect(tree.focusOrder).toBe(2);
    expect(tree.voiceInputEvent).toBe("voice.reply");
    expect(tree.voiceOutputText).toBe("Agent finished with 3 changed files");
    expect(tree.voiceShortcut).toBe(true);
  });

  it("rejects invalid eyes-free metadata", () => {
    expect(() =>
      validateUiTree({
        kind: "Text",
        id: "status",
        text: "Done",
        focusRole: "primary",
      }),
    ).toThrow(/focusRole/);
    expect(() =>
      validateUiTree({
        kind: "Text",
        id: "status",
        text: "Done",
        focusOrder: -1,
      }),
    ).toThrow(/focusOrder/);
    expect(() =>
      validateUiTree({
        kind: "Text",
        id: "status",
        text: "Done",
        voiceOutputText: "",
      }),
    ).toThrow(/voiceOutputText/);
    expect(() =>
      validateUiTree({
        kind: "Text",
        id: "status",
        text: "Done",
        voiceShortcut: "yes",
      }),
    ).toThrow(/voiceShortcut/);
  });

  // ---- Batch 1 widgets (§4.3) ----

  it("accepts UiIcon with a tokenized size and accent", () => {
    const tree = validateUiTree({
      kind: "Icon",
      id: "i",
      name: "home",
      size: "md",
      accent: "brand",
    });
    expect(tree.kind).toBe("Icon");
    if (tree.kind !== "Icon") throw new Error("unreachable");
    expect(tree.name).toBe("home");
    expect(tree.size).toBe("md");
    expect(tree.accent).toBe("brand");
  });

  it("accepts UiIcon with a numeric size (back-compat)", () => {
    const tree = validateUiTree({
      kind: "Icon",
      id: "i2",
      name: "settings",
      size: 24,
    });
    if (tree.kind !== "Icon") throw new Error("unreachable");
    expect(tree.size).toBe(24);
  });

  it("rejects UiIcon with unknown accent", () => {
    expect(() =>
      validateUiTree({
        kind: "Icon",
        id: "i3",
        name: "home",
        accent: "purple",
      }),
    ).toThrow(/accent/);
  });

  it("accepts UiBadge with the pill variant + count", () => {
    const tree = validateUiTree({
      kind: "Badge",
      id: "b",
      variant: "pill",
      count: 7,
      accent: "danger",
    });
    if (tree.kind !== "Badge") throw new Error("unreachable");
    expect(tree.count).toBe(7);
    expect(tree.variant).toBe("pill");
  });

  it("rejects UiBadge missing variant", () => {
    expect(() =>
      validateUiTree({ kind: "Badge", id: "b2" }),
    ).toThrow(/variant/);
  });

  it("rejects UiBadge with negative count", () => {
    expect(() =>
      validateUiTree({
        kind: "Badge",
        id: "b3",
        variant: "pill",
        count: -1,
      }),
    ).toThrow(/count/);
  });

  it("accepts UiListTile with leading / trailing / swipeActions", () => {
    const tree = validateUiTree({
      kind: "ListTile",
      id: "row",
      title: "Hello",
      subtitle: "world",
      leading: { kind: "Icon", id: "row.l", name: "user" },
      trailing: { kind: "Badge", id: "row.t", variant: "dot" },
      onTapEvent: "open",
      swipeActions: [
        { label: "Delete", eventId: "row.delete", accent: "danger" },
      ],
    });
    if (tree.kind !== "ListTile") throw new Error("unreachable");
    expect(tree.title).toBe("Hello");
    expect(tree.leading?.kind).toBe("Icon");
    expect(tree.trailing?.kind).toBe("Badge");
    expect(tree.swipeActions).toHaveLength(1);
  });

  it("rejects UiListTile with non-string title", () => {
    expect(() =>
      validateUiTree({ kind: "ListTile", id: "row", title: 42 }),
    ).toThrow(/title/);
  });

  it("accepts UiAppGrid with a string-icon tile and onLaunchEvent", () => {
    const tree = validateUiTree({
      kind: "AppGrid",
      id: "g",
      onLaunchEvent: "launch",
      columns: 3,
      items: [
        { id: "t1", name: "Notes", icon: "file-text", accent: "brand" },
      ],
    });
    if (tree.kind !== "AppGrid") throw new Error("unreachable");
    expect(tree.items).toHaveLength(1);
    expect(tree.items[0].icon).toBe("file-text");
    expect(tree.columns).toBe(3);
  });

  it("accepts UiAppGrid with a { uri } icon (Batch 3 forward-compat)", () => {
    const tree = validateUiTree({
      kind: "AppGrid",
      id: "g2",
      items: [
        { id: "t", name: "Custom", icon: { uri: "https://x/i.png" } },
      ],
    });
    if (tree.kind !== "AppGrid") throw new Error("unreachable");
    expect(tree.items[0].icon).toEqual({ uri: "https://x/i.png" });
  });

  it("rejects UiAppGrid with duplicate tile ids", () => {
    expect(() =>
      validateUiTree({
        kind: "AppGrid",
        id: "g3",
        items: [
          { id: "t", name: "A", icon: "home" },
          { id: "t", name: "B", icon: "home" },
        ],
      }),
    ).toThrow(/duplicate tile id/);
  });

  it("accepts Column.gap as a token string", () => {
    const tree = validateUiTree({
      kind: "Column",
      id: "c",
      gap: "sm",
      children: [{ kind: "Text", id: "t", text: "hi" }],
    });
    if (tree.kind !== "Column") throw new Error("unreachable");
    expect(tree.gap).toBe("sm");
  });

  it("rejects Column.gap as an unknown token string", () => {
    expect(() =>
      validateUiTree({
        kind: "Column",
        id: "c2",
        gap: "huge",
        children: [],
      }),
    ).toThrow(/gap/);
  });

  // ---- Batch 2 widgets (§4.3) ----

  it("Section.variant defaults to undefined for pre-Batch-2 trees", () => {
    const tree = validateUiTree({
      kind: "Section",
      id: "s",
      title: "Settings",
      children: [{ kind: "Text", id: "t", text: "hi" }],
    });
    if (tree.kind !== "Section") throw new Error("unreachable");
    expect(tree.variant).toBeUndefined();
  });

  it("Section.variant accepts plain | card | inset", () => {
    for (const variant of ["plain", "card", "inset"] as const) {
      const tree = validateUiTree({
        kind: "Section",
        id: `s-${variant}`,
        variant,
        children: [],
      });
      if (tree.kind !== "Section") throw new Error("unreachable");
      expect(tree.variant).toBe(variant);
    }
  });

  it("rejects Section.variant outside the accepted union", () => {
    expect(() =>
      validateUiTree({
        kind: "Section",
        id: "s2",
        variant: "elevated",
        children: [],
      }),
    ).toThrow(/variant/);
  });

  it("UiSwitch requires a boolean value", () => {
    const tree = validateUiTree({
      kind: "Switch",
      id: "sw",
      label: "Private",
      value: true,
      onChangeEvent: "toggle",
    });
    if (tree.kind !== "Switch") throw new Error("unreachable");
    expect(tree.value).toBe(true);
    expect(tree.label).toBe("Private");
    expect(tree.onChangeEvent).toBe("toggle");
  });

  it("rejects UiSwitch with a missing value", () => {
    expect(() =>
      validateUiTree({ kind: "Switch", id: "sw2", label: "x" }),
    ).toThrow(/value/);
  });

  it("rejects UiSwitch with non-boolean value", () => {
    expect(() =>
      validateUiTree({ kind: "Switch", id: "sw3", value: "yes" }),
    ).toThrow(/value/);
  });

  it("UiSelect parses options + label + value + onChangeEvent", () => {
    const tree = validateUiTree({
      kind: "Select",
      id: "sel",
      label: "Theme",
      options: [
        { value: "system", label: "System" },
        { value: "light", label: "Light" },
        { value: "dark", label: "Dark" },
      ],
      value: "dark",
      onChangeEvent: "themeChanged",
    });
    if (tree.kind !== "Select") throw new Error("unreachable");
    expect(tree.options).toHaveLength(3);
    expect(tree.options[1].label).toBe("Light");
    expect(tree.value).toBe("dark");
    expect(tree.onChangeEvent).toBe("themeChanged");
  });

  it("rejects UiSelect with duplicate option values", () => {
    expect(() =>
      validateUiTree({
        kind: "Select",
        id: "sel2",
        options: [
          { value: "x", label: "A" },
          { value: "x", label: "B" },
        ],
      }),
    ).toThrow(/duplicate option value/);
  });

  it("rejects UiSelect with a value that no option carries", () => {
    expect(() =>
      validateUiTree({
        kind: "Select",
        id: "sel3",
        options: [{ value: "a", label: "A" }],
        value: "z",
      }),
    ).toThrow(/value/);
  });

  it("UiInlineBanner accepts the four-accent union with optional action", () => {
    const tree = validateUiTree({
      kind: "Banner",
      id: "ban",
      title: "Heads up",
      body: "Things changed.",
      accent: "warning",
      action: { label: "Apply", eventId: "apply" },
      dismissEventId: "dismiss",
    });
    if (tree.kind !== "Banner") throw new Error("unreachable");
    expect(tree.title).toBe("Heads up");
    expect(tree.accent).toBe("warning");
    expect(tree.action).toEqual({ label: "Apply", eventId: "apply" });
    expect(tree.dismissEventId).toBe("dismiss");
  });

  it("rejects UiInlineBanner with accent outside info|success|warning|danger", () => {
    expect(() =>
      validateUiTree({
        kind: "Banner",
        id: "ban2",
        title: "x",
        accent: "brand",
      }),
    ).toThrow(/accent/);
  });

  it("rejects UiInlineBanner with action missing eventId", () => {
    expect(() =>
      validateUiTree({
        kind: "Banner",
        id: "ban3",
        title: "x",
        accent: "info",
        action: { label: "Apply" },
      }),
    ).toThrow(/eventId/);
  });

  it("UiDivider accepts an optional orientation", () => {
    const tree = validateUiTree({
      kind: "Divider",
      id: "d",
      orientation: "vertical",
    });
    if (tree.kind !== "Divider") throw new Error("unreachable");
    expect(tree.orientation).toBe("vertical");
  });

  it("UiDivider defaults orientation to undefined (renderer picks horizontal)", () => {
    const tree = validateUiTree({ kind: "Divider", id: "d2" });
    if (tree.kind !== "Divider") throw new Error("unreachable");
    expect(tree.orientation).toBeUndefined();
  });

  it("rejects UiDivider with unknown orientation", () => {
    expect(() =>
      validateUiTree({ kind: "Divider", id: "d3", orientation: "diagonal" }),
    ).toThrow(/orientation/);
  });

  // ---- Batch 3 widgets (§4.3) — rich display ----

  it("UiImage parses src + fit + tokenized size", () => {
    const tree = validateUiTree({
      kind: "Image",
      id: "img",
      src: "https://example.com/x.png",
      fit: "contain",
      size: "lg",
    });
    if (tree.kind !== "Image") throw new Error("unreachable");
    expect(tree.src).toBe("https://example.com/x.png");
    expect(tree.fit).toBe("contain");
    expect(tree.size).toBe("lg");
  });

  it("UiImage accepts file:// and data: URLs (gate runs in host, not parser)", () => {
    const tree = validateUiTree({
      kind: "Image",
      id: "img2",
      src: "file:///workspace/icon.png",
    });
    if (tree.kind !== "Image") throw new Error("unreachable");
    expect(tree.src).toBe("file:///workspace/icon.png");
  });

  it("rejects UiImage missing src", () => {
    expect(() =>
      validateUiTree({ kind: "Image", id: "img3" }),
    ).toThrow(/src/);
  });

  it("rejects UiImage with unknown fit", () => {
    expect(() =>
      validateUiTree({
        kind: "Image",
        id: "img4",
        src: "https://x",
        fit: "scaleDown",
      }),
    ).toThrow(/fit/);
  });

  it("UiAvatar parses initial + accent fallback", () => {
    const tree = validateUiTree({
      kind: "Avatar",
      id: "av",
      initial: "AB",
      size: "md",
      accent: "info",
    });
    if (tree.kind !== "Avatar") throw new Error("unreachable");
    expect(tree.initial).toBe("AB");
    expect(tree.accent).toBe("info");
  });

  it("UiAvatar with src only is valid (no initial required)", () => {
    const tree = validateUiTree({
      kind: "Avatar",
      id: "av2",
      src: "https://x/pic.png",
    });
    if (tree.kind !== "Avatar") throw new Error("unreachable");
    expect(tree.src).toBe("https://x/pic.png");
    expect(tree.initial).toBeUndefined();
  });

  it("rejects UiAvatar with neither src nor initial", () => {
    expect(() =>
      validateUiTree({ kind: "Avatar", id: "av3" }),
    ).toThrow(/src or initial/);
  });

  it("UiMarkdown round-trips its body unchanged", () => {
    const body = "# Hello\n\nThis is *bold* and `code`.";
    const tree = validateUiTree({
      kind: "Markdown",
      id: "md",
      markdown: body,
    });
    if (tree.kind !== "Markdown") throw new Error("unreachable");
    expect(tree.markdown).toBe(body);
  });

  it("rejects UiMarkdown with non-string markdown", () => {
    expect(() =>
      validateUiTree({ kind: "Markdown", id: "md2", markdown: 42 }),
    ).toThrow(/markdown/);
  });

  it("UiCodeBlock parses code + language", () => {
    const tree = validateUiTree({
      kind: "CodeBlock",
      id: "cb",
      code: "const x = 1;",
      language: "typescript",
    });
    if (tree.kind !== "CodeBlock") throw new Error("unreachable");
    expect(tree.code).toBe("const x = 1;");
    expect(tree.language).toBe("typescript");
  });

  it("UiCodeBlock without language is valid (renderer falls back to plain mono)", () => {
    const tree = validateUiTree({
      kind: "CodeBlock",
      id: "cb2",
      code: "anything",
    });
    if (tree.kind !== "CodeBlock") throw new Error("unreachable");
    expect(tree.language).toBeUndefined();
  });

  it("rejects UiCodeBlock with non-string code", () => {
    expect(() =>
      validateUiTree({ kind: "CodeBlock", id: "cb3", code: null }),
    ).toThrow(/code/);
  });

  it("UiProgress parses value/variant/label/accent", () => {
    const tree = validateUiTree({
      kind: "Progress",
      id: "pg",
      value: 0.42,
      variant: "circular",
      label: "Loading…",
      accent: "info",
    });
    if (tree.kind !== "Progress") throw new Error("unreachable");
    expect(tree.value).toBe(0.42);
    expect(tree.variant).toBe("circular");
    expect(tree.label).toBe("Loading…");
    expect(tree.accent).toBe("info");
  });

  it("UiProgress with no value is valid (indeterminate)", () => {
    const tree = validateUiTree({ kind: "Progress", id: "pg2" });
    if (tree.kind !== "Progress") throw new Error("unreachable");
    expect(tree.value).toBeUndefined();
    expect(tree.variant).toBeUndefined();
  });

  it("rejects UiProgress with value out of [0, 1]", () => {
    expect(() =>
      validateUiTree({ kind: "Progress", id: "pg3", value: 1.5 }),
    ).toThrow(/value/);
    expect(() =>
      validateUiTree({ kind: "Progress", id: "pg4", value: -0.1 }),
    ).toThrow(/value/);
  });

  it("rejects UiProgress with unknown variant", () => {
    expect(() =>
      validateUiTree({
        kind: "Progress",
        id: "pg5",
        variant: "stepped",
      }),
    ).toThrow(/variant/);
  });

  it("UiSpinner parses label + tokenized size", () => {
    const tree = validateUiTree({
      kind: "Spinner",
      id: "sp",
      label: "refreshing…",
      size: "lg",
    });
    if (tree.kind !== "Spinner") throw new Error("unreachable");
    expect(tree.label).toBe("refreshing…");
    expect(tree.size).toBe("lg");
  });

  it("UiSpinner without label / size is valid", () => {
    const tree = validateUiTree({ kind: "Spinner", id: "sp2" });
    if (tree.kind !== "Spinner") throw new Error("unreachable");
    expect(tree.label).toBeUndefined();
    expect(tree.size).toBeUndefined();
  });

  // ---- Batch 5 widgets (§4.3) — long tail ----

  it("Section.collapsible defaults to undefined and accepts boolean", () => {
    const omitted = validateUiTree({
      kind: "Section",
      id: "s",
      children: [],
    });
    if (omitted.kind !== "Section") throw new Error("unreachable");
    expect(omitted.collapsible).toBeUndefined();
    const enabled = validateUiTree({
      kind: "Section",
      id: "s2",
      collapsible: true,
      children: [],
    });
    if (enabled.kind !== "Section") throw new Error("unreachable");
    expect(enabled.collapsible).toBe(true);
  });

  it("rejects Section.collapsible with non-boolean value", () => {
    expect(() =>
      validateUiTree({
        kind: "Section",
        id: "s3",
        collapsible: "yes",
        children: [],
      }),
    ).toThrow(/collapsible/);
  });

  it("UiGrid accepts integer columns + adaptive sentinel", () => {
    const fixed = validateUiTree({
      kind: "Grid",
      id: "g",
      columns: 3,
      gap: "sm",
      children: [{ kind: "Text", id: "t", text: "x" }],
    });
    if (fixed.kind !== "Grid") throw new Error("unreachable");
    expect(fixed.columns).toBe(3);
    expect(fixed.gap).toBe("sm");
    const adaptive = validateUiTree({
      kind: "Grid",
      id: "g2",
      columns: "adaptive",
      children: [],
    });
    if (adaptive.kind !== "Grid") throw new Error("unreachable");
    expect(adaptive.columns).toBe("adaptive");
  });

  it("rejects UiGrid columns <= 0 or non-integer", () => {
    expect(() =>
      validateUiTree({
        kind: "Grid",
        id: "g3",
        columns: 0,
        children: [],
      }),
    ).toThrow(/columns/);
    expect(() =>
      validateUiTree({
        kind: "Grid",
        id: "g4",
        columns: 2.5,
        children: [],
      }),
    ).toThrow(/columns/);
    expect(() =>
      validateUiTree({
        kind: "Grid",
        id: "g5",
        columns: "wide",
        children: [],
      }),
    ).toThrow(/columns/);
  });

  it("UiStack accepts the nine-point alignment union", () => {
    for (const alignment of [
      "topStart",
      "topCenter",
      "topEnd",
      "centerStart",
      "center",
      "centerEnd",
      "bottomStart",
      "bottomCenter",
      "bottomEnd",
    ] as const) {
      const tree = validateUiTree({
        kind: "Stack",
        id: `s-${alignment}`,
        alignment,
        children: [],
      });
      if (tree.kind !== "Stack") throw new Error("unreachable");
      expect(tree.alignment).toBe(alignment);
    }
  });

  it("rejects UiStack with unknown alignment", () => {
    expect(() =>
      validateUiTree({
        kind: "Stack",
        id: "s",
        alignment: "diagonal",
        children: [],
      }),
    ).toThrow(/alignment/);
  });

  it("UiAspect parses ratio + child", () => {
    const tree = validateUiTree({
      kind: "Aspect",
      id: "a",
      ratio: 16 / 9,
      child: { kind: "Text", id: "t", text: "x" },
    });
    if (tree.kind !== "Aspect") throw new Error("unreachable");
    expect(tree.ratio).toBeCloseTo(16 / 9);
    expect(tree.child.kind).toBe("Text");
  });

  it("rejects UiAspect with non-positive ratio or missing child", () => {
    expect(() =>
      validateUiTree({ kind: "Aspect", id: "a", ratio: 0, child: { kind: "Text", id: "t", text: "x" } }),
    ).toThrow(/ratio/);
    expect(() =>
      validateUiTree({ kind: "Aspect", id: "a2", ratio: 1 }),
    ).toThrow(/child/);
  });

  it("UiFlex parses flex + child", () => {
    const tree = validateUiTree({
      kind: "Flex",
      id: "f",
      flex: 2,
      child: { kind: "Text", id: "t", text: "x" },
    });
    if (tree.kind !== "Flex") throw new Error("unreachable");
    expect(tree.flex).toBe(2);
    expect(tree.child.kind).toBe("Text");
  });

  it("rejects UiFlex with negative flex", () => {
    expect(() =>
      validateUiTree({
        kind: "Flex",
        id: "f",
        flex: -1,
        child: { kind: "Text", id: "t", text: "x" },
      }),
    ).toThrow(/flex/);
  });

  it("UiScroll defaults axis to undefined and accepts horizontal/vertical", () => {
    const tree = validateUiTree({
      kind: "Scroll",
      id: "s",
      child: { kind: "Text", id: "t", text: "x" },
    });
    if (tree.kind !== "Scroll") throw new Error("unreachable");
    expect(tree.axis).toBeUndefined();
    const h = validateUiTree({
      kind: "Scroll",
      id: "s2",
      axis: "horizontal",
      child: { kind: "Text", id: "t2", text: "x" },
    });
    if (h.kind !== "Scroll") throw new Error("unreachable");
    expect(h.axis).toBe("horizontal");
  });

  it("rejects UiScroll with unknown axis", () => {
    expect(() =>
      validateUiTree({
        kind: "Scroll",
        id: "s",
        axis: "diagonal",
        child: { kind: "Text", id: "t", text: "x" },
      }),
    ).toThrow(/axis/);
  });

  it("UiTabBar parses tabs + activeId + onChangeEvent", () => {
    const tree = validateUiTree({
      kind: "TabBar",
      id: "tb",
      activeId: "a",
      onChangeEvent: "tabPicked",
      tabs: [
        { id: "a", label: "Alpha", icon: "home" },
        { id: "b", label: "Beta" },
      ],
    });
    if (tree.kind !== "TabBar") throw new Error("unreachable");
    expect(tree.tabs).toHaveLength(2);
    expect(tree.activeId).toBe("a");
    expect(tree.onChangeEvent).toBe("tabPicked");
  });

  it("rejects UiTabBar with empty tabs", () => {
    expect(() =>
      validateUiTree({
        kind: "TabBar",
        id: "tb",
        activeId: "a",
        tabs: [],
      }),
    ).toThrow(/tabs/);
  });

  it("rejects UiTabBar with duplicate tab ids", () => {
    expect(() =>
      validateUiTree({
        kind: "TabBar",
        id: "tb2",
        activeId: "a",
        tabs: [
          { id: "a", label: "A" },
          { id: "a", label: "A2" },
        ],
      }),
    ).toThrow(/duplicate tab id/);
  });

  it("rejects UiTabBar with activeId not in tabs", () => {
    expect(() =>
      validateUiTree({
        kind: "TabBar",
        id: "tb3",
        activeId: "z",
        tabs: [{ id: "a", label: "A" }],
      }),
    ).toThrow(/activeId/);
  });

  it("UiSearchField is valid with no fields set", () => {
    const tree = validateUiTree({ kind: "SearchField", id: "sf" });
    if (tree.kind !== "SearchField") throw new Error("unreachable");
    expect(tree.value).toBeUndefined();
    expect(tree.onChangeEvent).toBeUndefined();
  });

  it("UiSearchField round-trips value + placeholder + onChangeEvent", () => {
    const tree = validateUiTree({
      kind: "SearchField",
      id: "sf2",
      value: "ada",
      placeholder: "search…",
      onChangeEvent: "q",
    });
    if (tree.kind !== "SearchField") throw new Error("unreachable");
    expect(tree.value).toBe("ada");
    expect(tree.placeholder).toBe("search…");
    expect(tree.onChangeEvent).toBe("q");
  });

  it("UiCheckbox requires boolean value", () => {
    const tree = validateUiTree({
      kind: "Checkbox",
      id: "c",
      value: true,
      label: "Subscribe",
      onChangeEvent: "sub",
    });
    if (tree.kind !== "Checkbox") throw new Error("unreachable");
    expect(tree.value).toBe(true);
    expect(tree.label).toBe("Subscribe");
    expect(tree.onChangeEvent).toBe("sub");
  });

  it("rejects UiCheckbox without value", () => {
    expect(() =>
      validateUiTree({ kind: "Checkbox", id: "c2", label: "x" }),
    ).toThrow(/value/);
  });

  it("UiRadioGroup parses options + value + onChangeEvent", () => {
    const tree = validateUiTree({
      kind: "RadioGroup",
      id: "r",
      options: [
        { value: "x", label: "X" },
        { value: "y", label: "Y" },
      ],
      value: "x",
      onChangeEvent: "pick",
    });
    if (tree.kind !== "RadioGroup") throw new Error("unreachable");
    expect(tree.options).toHaveLength(2);
    expect(tree.value).toBe("x");
  });

  it("rejects UiRadioGroup with duplicate option values", () => {
    expect(() =>
      validateUiTree({
        kind: "RadioGroup",
        id: "r2",
        options: [
          { value: "x", label: "X" },
          { value: "x", label: "X2" },
        ],
      }),
    ).toThrow(/duplicate option value/);
  });

  it("rejects UiRadioGroup with value not in options", () => {
    expect(() =>
      validateUiTree({
        kind: "RadioGroup",
        id: "r3",
        options: [{ value: "x", label: "X" }],
        value: "z",
      }),
    ).toThrow(/value/);
  });

  it("UiSlider continuous (no step) is valid", () => {
    const tree = validateUiTree({
      kind: "Slider",
      id: "s",
      min: 0,
      max: 100,
      value: 50,
    });
    if (tree.kind !== "Slider") throw new Error("unreachable");
    expect(tree.step).toBeUndefined();
    expect(tree.value).toBe(50);
  });

  it("UiSlider stepped (step > 0) is valid", () => {
    const tree = validateUiTree({
      kind: "Slider",
      id: "s2",
      min: 0,
      max: 10,
      step: 1,
      value: 5,
      onChangeEvent: "moved",
    });
    if (tree.kind !== "Slider") throw new Error("unreachable");
    expect(tree.step).toBe(1);
    expect(tree.onChangeEvent).toBe("moved");
  });

  it("rejects UiSlider with min >= max", () => {
    expect(() =>
      validateUiTree({
        kind: "Slider",
        id: "s3",
        min: 5,
        max: 5,
        value: 5,
      }),
    ).toThrow(/min/);
  });

  it("rejects UiSlider with non-positive step", () => {
    expect(() =>
      validateUiTree({
        kind: "Slider",
        id: "s4",
        min: 0,
        max: 10,
        step: 0,
        value: 1,
      }),
    ).toThrow(/step/);
  });
});

describe("collectFileUrls walker (Batch 5 container coverage)", () => {
  // Every new Batch 5 container kind must recurse so a deeply-nested
  // `UiImage src='file://outside'` is still caught by the gate. Without
  // these cases the file:// security boundary would silently degrade.
  const outsideSrc = "file:///definitely/outside/the/workspace.png";

  function gateImageInside(wrapper: (img: object) => object) {
    return async () => {
      const image = { kind: "Image", id: "img", src: outsideSrc };
      const tree = validateUiTree(wrapper(image));
      // We pass `noActiveWorkspace=null` to assert the gate fired on the
      // file:// URL (without a workspace it would emit
      // `noActiveWorkspace`). Either non-ok code proves the walker
      // visited the leaf — the point is "the gate ran at all".
      const res = await validateFileUrlsAgainstWorkspace(tree, "read", null);
      expect(res.ok).toBe(false);
    };
  }

  it(
    "rejects file:// inside UiGrid",
    gateImageInside((img) => ({
      kind: "Grid",
      id: "g",
      columns: 2,
      children: [img],
    })),
  );

  it(
    "rejects file:// inside UiStack",
    gateImageInside((img) => ({
      kind: "Stack",
      id: "s",
      children: [img],
    })),
  );

  it(
    "rejects file:// inside UiAspect.child",
    gateImageInside((img) => ({
      kind: "Aspect",
      id: "a",
      ratio: 1,
      child: img,
    })),
  );

  it(
    "rejects file:// inside UiFlex.child",
    gateImageInside((img) => ({
      kind: "Flex",
      id: "f",
      flex: 1,
      child: img,
    })),
  );

  it(
    "rejects file:// inside UiScroll.child",
    gateImageInside((img) => ({
      kind: "Scroll",
      id: "sc",
      child: img,
    })),
  );

  it(
    "rejects file:// through several Batch 5 containers nested",
    gateImageInside((img) => ({
      kind: "Scroll",
      id: "sc-deep",
      child: {
        kind: "Grid",
        id: "g-deep",
        columns: 1,
        children: [
          {
            kind: "Aspect",
            id: "a-deep",
            ratio: 1,
            child: {
              kind: "Flex",
              id: "f-deep",
              flex: 1,
              child: img,
            },
          },
        ],
      },
    })),
  );
});

describe("file:// URL fs-gating (Batch 3)", () => {
  // Real workspace tempdir + a real "outside" tempdir so the gate's
  // `fs.realpath` discipline can be exercised end-to-end. The gate is
  // async and follows symlinks (matching `resolveCallerPath` in
  // workspace.ts) — a lexical check would let a symlink-inside-the-
  // workspace escape, which is the BLOCKER review fix.
  let ws: string;
  let outside: string;

  beforeEach(async () => {
    ws = await makeTempDir("openvsmobile-uigate-ws-");
    outside = await makeTempDir("openvsmobile-uigate-out-");
    // One real file inside the workspace so "accept" paths can be
    // realpath-resolved.
    await writeFile(join(ws, "logo.png"), "p");
    await mkdir(join(ws, "sub", "dir"), { recursive: true });
    await writeFile(join(ws, "sub", "dir", "logo.png"), "p");
    // One real file outside, used as the symlink target.
    await writeFile(join(outside, "secret"), "s");
  });

  afterEach(async () => {
    await rmTempDir(ws);
    await rmTempDir(outside);
  });

  // Helper: build a UiImage tree carrying the given src.
  function imageTree(src: string) {
    return validateUiTree({
      kind: "Column",
      id: "root",
      children: [{ kind: "Image", id: "img", src }],
    });
  }

  it("passes when no file:// URLs are present (data: URL)", async () => {
    const tree = imageTree("data:image/png;base64,iVBORw0KGgo=");
    const res = await validateFileUrlsAgainstWorkspace(tree, "none", ws);
    expect(res.ok).toBe(true);
  });

  it("rejects file:// when plugin has fs: none", async () => {
    const tree = imageTree(`file://${ws}/logo.png`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "none", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("capabilityNotDeclared");
  });

  it("accepts file:// when plugin has fs: read and path is inside workspace", async () => {
    const tree = imageTree(`file://${ws}/logo.png`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(true);
  });

  it("accepts file:// when plugin has fs: readwrite", async () => {
    const tree = imageTree(`file://${ws}/sub/dir/logo.png`);
    const res = await validateFileUrlsAgainstWorkspace(
      tree,
      "readwrite",
      ws,
    );
    expect(res.ok).toBe(true);
  });

  it("rejects file:// with ../ traversal that escapes workspace", async () => {
    // The traversal target doesn't exist, so realpath fails and we
    // collapse into `outsideWorkspace` — same UX as a path-outside.
    const tree = imageTree(`file://${ws}/sub/../../etc/passwd`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("rejects file:// with absolute path outside the workspace", async () => {
    const tree = imageTree(`file://${outside}/secret`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("rejects file:// when no workspace is active", async () => {
    const tree = imageTree(`file://${ws}/logo.png`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", null);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("noActiveWorkspace");
  });

  it("rejects file:// avoiding partial-prefix match (/tmp/ws vs /tmp/wsroot)", async () => {
    // Build a sibling directory whose name is a *prefix* of ws's
    // basename — without the separator guard a naive `startsWith`
    // would falsely accept. We construct that by suffixing ws's
    // basename with "root".
    const sibling = `${ws}root`;
    await mkdir(sibling, { recursive: true });
    try {
      await writeFile(join(sibling, "icon.png"), "p");
      const tree = imageTree(`file://${sibling}/icon.png`);
      const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
      expect(res.ok).toBe(false);
      if (res.ok) throw new Error("unreachable");
      expect(res.code).toBe("outsideWorkspace");
    } finally {
      await rmTempDir(sibling);
    }
  });

  it("REGRESSION: rejects file:// via symlink that escapes the workspace", async () => {
    // BLOCKER fix from review: workspace contains a symlink whose
    // target is outside the workspace. A lexical-only check would
    // pass (the symlink path starts with the workspace prefix), but
    // the realpath gate must reject — matching `fs.*` RPC isolation.
    await symlink(join(outside, "secret"), join(ws, "evil"));
    const tree = imageTree(`file://${ws}/evil`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("accepts a symlink whose target is itself inside the workspace", async () => {
    // Symlink-within-workspace is fine: realpath resolves to a path
    // still under the workspace root.
    await symlink(join(ws, "logo.png"), join(ws, "alias.png"));
    const tree = imageTree(`file://${ws}/alias.png`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(true);
  });

  it("gate also fires on UiAvatar with file:// src", async () => {
    const tree = validateUiTree({
      kind: "Avatar",
      id: "av",
      src: `file://${outside}/secret`,
      initial: "A",
    });
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("UiAvatar with no src (initial-only) is never gated", async () => {
    const tree = validateUiTree({
      kind: "Avatar",
      id: "av2",
      initial: "AB",
    });
    const res = await validateFileUrlsAgainstWorkspace(tree, "none", null);
    expect(res.ok).toBe(true);
  });

  it("walks nested containers and gates a deep file:// site", async () => {
    const tree = validateUiTree({
      kind: "Column",
      id: "c1",
      children: [
        {
          kind: "Section",
          id: "s1",
          children: [
            {
              kind: "ListTile",
              id: "tile",
              title: "Header",
              trailing: {
                kind: "Image",
                id: "deep-img",
                src: `file://${outside}/secret`,
              },
            },
          ],
        },
      ],
    });
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
    expect(res.message).toMatch(/trailing/);
  });

  it("rejects file:// pointing at a non-existent path inside the workspace", async () => {
    // Symmetric with `fs.readFile`'s ENOENT collapse: a path that
    // doesn't exist gets `outsideWorkspace` so the plugin can't
    // probe filesystem layout via differential errors.
    const tree = imageTree(`file://${ws}/no-such-file.png`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("malformed percent-encoding in file:// URL is dropped from the site list", async () => {
    // Trailing lone `%` is an invalid escape sequence that throws
    // from `decodeURIComponent`. The gate must NOT silently fall
    // through to a prefix check on the raw bytes — the comment in
    // the previous implementation lied. Now we drop the site, which
    // means the tree contains no `file://` URLs as far as the gate
    // is concerned and the call passes.
    const tree = imageTree(`file://%FF%FE%`);
    const res = await validateFileUrlsAgainstWorkspace(tree, "none", ws);
    expect(res.ok).toBe(true);
  });

  it("rejects a file:// URL whose decoded path is not absolute", async () => {
    // `file://relative/path` decodes to `relative/path` which isn't
    // absolute — reject rather than try to anchor it anywhere.
    const tree = imageTree("file://relative/path.png");
    const res = await validateFileUrlsAgainstWorkspace(tree, "read", ws);
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });
});

describe("UiPanelRegistry", () => {
  function makeReg(): {
    reg: UiPanelRegistry;
    pushes: Array<{ ws: WebSocket; method: string; params: unknown }>;
  } {
    const pushes: Array<{ ws: WebSocket; method: string; params: unknown }> = [];
    const reg = new UiPanelRegistry((ws, method, params) =>
      pushes.push({ ws, method, params }),
    );
    return { reg, pushes };
  }

  it("emits monotonic per-panel versions on repeated render", () => {
    const { reg, pushes } = makeReg();
    const sock = new FakeWebSocket() as unknown as WebSocket;
    reg.subscribe(sock);
    reg.render("p1", "home", { kind: "Text", id: "t", text: "a" });
    reg.render("p1", "home", { kind: "Text", id: "t", text: "b" });
    reg.render("p1", "home", { kind: "Text", id: "t", text: "c" });
    expect(pushes).toHaveLength(3);
    const versions = pushes.map(
      (p) => (p.params as UiPanelSnapshot).version,
    );
    expect(versions).toEqual([1, 2, 3]);
  });

  it("retirePlugin emits one tree:null push per panel and drops them", () => {
    const { reg, pushes } = makeReg();
    const sock = new FakeWebSocket() as unknown as WebSocket;
    reg.subscribe(sock);
    reg.render("p1", "home", { kind: "Text", id: "t", text: "a" });
    reg.render("p1", "settings", { kind: "Text", id: "t2", text: "b" });
    reg.render("other", "home", { kind: "Text", id: "t3", text: "x" });
    pushes.length = 0;
    const retired = reg.retirePlugin("p1");
    expect(retired).toHaveLength(2);
    for (const snap of retired) {
      expect(snap.tree).toBeNull();
      expect(snap.pluginId).toBe("p1");
    }
    // Other plugin's panels untouched, still active.
    expect(
      reg.activePanels().map((p) => `${p.pluginId}/${p.panelId}`),
    ).toEqual(["other/home"]);
    expect(pushes).toHaveLength(2);
    // Re-render under the same panelId after retirement → fresh version
    // must be strictly larger than the retire-push's version (monotonic
    // contract for any client that observed both).
    const lastRetired = retired[retired.length - 1].version;
    const fresh = reg.render("p1", "settings", {
      kind: "Text",
      id: "t2",
      text: "again",
    });
    expect(fresh.version).toBeGreaterThan(lastRetired);
  });
});

describe("ui.render dispatch (file:// gate end-to-end)", () => {
  it("returns -32011 capabilityNotDeclared to a plugin emitting file:// without fs cap", async () => {
    const harness = await buildHarness(["uifileurl"]);
    try {
      const logPath = join(harness.logDir, "uifileurl.stderr.log");
      const respLine = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<RESP>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const resp = JSON.parse(respLine) as {
        id: number;
        error?: { code: number; message: string };
      };
      expect(resp.id).toBe(99);
      expect(resp.error).toBeDefined();
      // Without an `fs` capability the host should short-circuit on
      // capabilityNotDeclared, regardless of whether a workspace is
      // active or where the path resolves to.
      expect(resp.error?.code).toBe(-32011);
      expect(resp.error?.message).toMatch(/capabilities\.fs|file:\/\//);
      // The render must not have landed.
      expect(harness.host.ui.activePanels()).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.render dispatch (validation)", () => {
  it("returns -32602 to a plugin that emits a tree with duplicate ids", async () => {
    const harness = await buildHarness(["uibadid"]);
    try {
      // The fixture echoes the host's response onto stderr wrapped in
      // <<RESP>>…<<END>>. Tail the captured log until that lands, then
      // assert the JSON-RPC error code.
      const logPath = join(harness.logDir, "uibadid.stderr.log");
      const respLine = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<RESP>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const resp = JSON.parse(respLine) as {
        id: number;
        error?: { code: number; message: string };
      };
      expect(resp.id).toBe(42);
      expect(resp.error).toBeDefined();
      expect(resp.error?.code).toBe(-32602);
      expect(resp.error?.message).toMatch(/duplicate node id/);
      // The duplicate-id panel must never have been registered.
      expect(harness.host.ui.activePanels()).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.subscribe + plugin-driven ui.render fan-out", () => {
  it("delivers 3 monotonic pushes for 3 plugin-emitted ui.render calls", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Subscribe FIRST (the harness socket joins the fan-out group). The
      // emitter fixture races to render on startup, so we have to wait
      // long enough for the host to receive + register all three trees
      // even if our subscribe lost the race for the very first one.
      const subRes = await call<{ ok: boolean }>(harness.ctx, "ui.subscribe");
      expect(subRes.ok).toBe(true);
      // The subscribe response is followed by a microtask-deferred
      // snapshot replay of currently-active panels — if any plugin
      // render already landed before subscribe, we get its snapshot now;
      // future pushes layer on top. Either way the LAST `ui.tree` we
      // observe must carry version 3 and the "third"-leaf text.
      const last = await waitFor(() => {
        const pushes = harness.sock.notifications("ui.tree");
        if (pushes.length === 0) return undefined;
        const tail = pushes[pushes.length - 1].params as UiPanelSnapshot;
        if (tail.version < 3) return undefined;
        return tail;
      }, 3000);
      expect(last.pluginId).toBe("uiemitter");
      expect(last.panelId).toBe("home");
      expect(last.tree).not.toBeNull();
      // The fixture mutates only the Text leaf between renders; assert the
      // current panel snapshot reflects the third render's label.
      const text = findText(last.tree!, "root-text");
      expect(text).toBe("third");
      // Versions across the captured push stream must be strictly increasing.
      const versions = harness.sock
        .notifications("ui.tree")
        .map((p) => (p.params as UiPanelSnapshot).version);
      for (let i = 1; i < versions.length; i++) {
        expect(versions[i]).toBeGreaterThan(versions[i - 1]);
      }
    } finally {
      harness.host.shutdown();
    }
  });

  it("re-subscribing replays the current snapshot for active panels", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Wait until the host has all three renders applied. We assert on
      // the registry's view, which doesn't need a live subscriber.
      const snap = await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        const home = panels.find((p) => p.panelId === "home");
        if (home === undefined || home.version < 3) return undefined;
        return home;
      }, 3000);
      expect(snap.version).toBe(3);
      // Now subscribe a fresh socket; the replay path should send one
      // ui.tree with the snapshot.
      const sock = new FakeWebSocket();
      const ctx: RpcContext = {
        ...harness.ctx,
        ws: sock as unknown as WebSocket,
      };
      await call<{ ok: boolean }>(ctx, "ui.subscribe");
      // Microtask flush.
      await Promise.resolve();
      await Promise.resolve();
      const pushes = sock.notifications("ui.tree");
      expect(pushes.length).toBe(1);
      const replay = pushes[0].params as UiPanelSnapshot;
      expect(replay.version).toBe(3);
      expect(findText(replay.tree!, "root-text")).toBe("third");
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.event round-trip", () => {
  it("forwards an app→backend ui.event into the owning plugin", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Wait until the fixture has emitted at least one tree — the
      // plugin's first stdout byte is what flips the host's FrameCodec
      // out of "unknown" / LSP into "newline" mode. Sending ui.event
      // before then would frame the payload as LSP and the fixture
      // (a bare newline parser) would never see it.
      await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        return panels.length > 0 ? panels : undefined;
      }, 3000);
      // Send a synthetic tap.
      await call(harness.ctx, "ui.event", {
        pluginId: "uiemitter",
        panelId: "home",
        nodeId: "submit-btn",
        type: "tap",
        payload: { from: "test" },
      });
      // Fixture surfaces the inbound event via stderr markers. Wait for
      // the marker line to land in the captured log.
      const logPath = join(harness.logDir, "uiemitter.stderr.log");
      const eventJson = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<UIEVT>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const evt = JSON.parse(eventJson) as {
        pluginId: string;
        panelId: string;
        nodeId: string;
        type: string;
        payload?: unknown;
      };
      expect(evt.pluginId).toBe("uiemitter");
      expect(evt.panelId).toBe("home");
      expect(evt.nodeId).toBe("submit-btn");
      expect(evt.type).toBe("tap");
      expect(evt.payload).toEqual({ from: "test" });
    } finally {
      harness.host.shutdown();
    }
  });

  it("rejects ui.event with -32602 for an unknown plugin", async () => {
    const harness = await buildHarness([]);
    try {
      await expect(
        call(harness.ctx, "ui.event", {
          pluginId: "no-such-plugin",
          panelId: "home",
          nodeId: "n",
          type: "tap",
        }),
      ).rejects.toBeInstanceOf(RpcError);
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("notification.reply routing", () => {
  it("loads the persisted reply target and forwards user text to that plugin", async () => {
    const harness = await buildHarness(["notify"]);
    try {
      const logPath = join(harness.logDir, "notify.stderr.log");
      await waitFor(async () => {
        try {
          const raw = await readFile(logPath, "utf8");
          return /<<RX>>/.test(raw) ? true : undefined;
        } catch {
          return undefined;
        }
      }, 3000);
      const { id } = harness.state.notificationHub.publish({
        source: "test",
        level: "info",
        title: "Reply requested",
        reply: {
          target: { kind: "plugin", pluginId: "notify", panelId: "home" },
          event: "reply",
          context: { runId: "r1" },
        },
      });

      await call(harness.ctx, "notification.reply", {
        id,
        text: "continue",
      });

      const frame = await waitFor(async () => {
        const raw = await readFile(logPath, "utf8");
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            method?: string;
            params?: Record<string, unknown>;
          };
          if (body.method === "notification.reply") return body;
        }
        return undefined;
      }, 3000);
      expect(frame.params).toEqual({
        pluginId: "notify",
        notificationId: id,
        text: "continue",
        panelId: "home",
        event: "reply",
        context: { runId: "r1" },
      });
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("plugin exit lifecycle", () => {
  it("emits ui.tree { tree: null } for every panel when a plugin's process exits", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      await call(harness.ctx, "ui.subscribe");
      await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        const home = panels.find((p) => p.panelId === "home");
        return home !== undefined && home.version >= 3 ? home : undefined;
      }, 3000);
      const beforeKills = harness.sock.notifications("ui.tree").length;
      // Kill the plugin process; `handlePluginExit` retires the panel.
      const entry = harness.host.get("uiemitter");
      expect(entry?.state).toBe("active");
      entry?.process?.kill();
      const retirementPush = await waitFor(() => {
        const pushes = harness.sock.notifications("ui.tree");
        for (let i = beforeKills; i < pushes.length; i++) {
          const snap = pushes[i].params as UiPanelSnapshot;
          if (snap.tree === null && snap.panelId === "home") return snap;
        }
        return undefined;
      }, 3000);
      expect(retirementPush.pluginId).toBe("uiemitter");
      expect(retirementPush.tree).toBeNull();
      expect(retirementPush.version).toBeGreaterThan(3);
      // After retirement the registry no longer lists the panel.
      expect(harness.host.ui.activePanels()).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});

// ---- Batch 4 imperative modal validators ----

describe("validateAlertDialog (Batch 4)", () => {
  it("accepts a well-formed dialog with primary + danger actions", () => {
    const alert = validateAlertDialog({
      id: "confirm-delete",
      title: "Delete note?",
      body: "This cannot be undone.",
      actions: [
        { label: "Cancel", eventId: "cancel" },
        { label: "Delete", eventId: "delete", variant: "danger" },
      ],
      dismissible: false,
    });
    expect(alert.id).toBe("confirm-delete");
    expect(alert.actions).toHaveLength(2);
    expect(alert.actions[1].variant).toBe("danger");
    expect(alert.dismissible).toBe(false);
  });

  it("rejects an empty actions list", () => {
    expect(() =>
      validateAlertDialog({ id: "x", title: "t", actions: [] }),
    ).toThrow(/actions/);
  });

  it("rejects duplicate action eventIds", () => {
    expect(() =>
      validateAlertDialog({
        id: "x",
        title: "t",
        actions: [
          { label: "A", eventId: "same" },
          { label: "B", eventId: "same" },
        ],
      }),
    ).toThrow(/duplicate eventId/);
  });

  it("rejects an unknown variant", () => {
    expect(() =>
      validateAlertDialog({
        id: "x",
        title: "t",
        actions: [{ label: "Go", eventId: "go", variant: "warning" }],
      }),
    ).toThrow(/variant/);
  });

  it("rejects a missing title", () => {
    expect(() =>
      validateAlertDialog({
        id: "x",
        actions: [{ label: "A", eventId: "a" }],
      }),
    ).toThrow(/title/);
  });
});

describe("validateActionSheet (Batch 4)", () => {
  it("accepts a sheet with icon + accent on actions", () => {
    const sheet = validateActionSheet({
      id: "refresh-picker",
      title: "Refresh interval",
      actions: [
        { label: "15s", eventId: "set:15", icon: "clock", accent: "info" },
        { label: "30s", eventId: "set:30", icon: "clock" },
      ],
      dismissEventId: "cancel",
    });
    expect(sheet.actions).toHaveLength(2);
    expect(sheet.actions[0].icon).toBe("clock");
    expect(sheet.actions[0].accent).toBe("info");
    expect(sheet.dismissEventId).toBe("cancel");
  });

  it("rejects empty actions", () => {
    expect(() =>
      validateActionSheet({ id: "x", actions: [] }),
    ).toThrow(/actions/);
  });

  it("rejects duplicate eventIds across sheet actions", () => {
    expect(() =>
      validateActionSheet({
        id: "x",
        actions: [
          { label: "A", eventId: "go" },
          { label: "B", eventId: "go" },
        ],
      }),
    ).toThrow(/duplicate eventId/);
  });
});

describe("validateBottomSheet (Batch 4)", () => {
  it("accepts a sheet whose child is a UiNode tree", () => {
    const sheet = validateBottomSheet({
      id: "details",
      title: "Note details",
      child: {
        kind: "Column",
        id: "bs-col",
        children: [{ kind: "Text", id: "bs-text", text: "hi" }],
      },
      dismissEventId: "close",
    });
    expect(sheet.id).toBe("details");
    expect(sheet.child.kind).toBe("Column");
    expect(sheet.dismissEventId).toBe("close");
  });

  it("rejects a missing child", () => {
    expect(() => validateBottomSheet({ id: "x" })).toThrow(/child/);
  });

  it("propagates UiNode validation errors from child", () => {
    expect(() =>
      validateBottomSheet({
        id: "x",
        child: { kind: "Unknown", id: "y" },
      }),
    ).toThrow(/unknown node kind/);
  });
});

describe("ui.showAlert / showActionSheet / showBottomSheet broadcast", () => {
  it("broadcasts ui.modal to every subscriber and returns delivered=true", async () => {
    // Drive the broadcast directly through the registry. We don't need
    // a child plugin process for this — the registry's `broadcastModal`
    // contract is the seam tested here; the host-level capability gating
    // is covered by ui.test.ts's existing pluginRpc end-to-end fixture.
    const pushes: { method: string; params: unknown }[] = [];
    const registry = new UiPanelRegistry((_, method, params) =>
      pushes.push({ method, params }),
    );
    const subA = new FakeWebSocket();
    const subB = new FakeWebSocket();
    registry.subscribe(subA as unknown as WebSocket);
    registry.subscribe(subB as unknown as WebSocket);
    const reach = registry.broadcastModal({
      kind: "alert",
      pluginId: "p",
      panelId: "home",
      alert: {
        id: "a1",
        title: "T",
        actions: [{ label: "OK", eventId: "ok" }],
      },
    });
    expect(reach).toBe(2);
    expect(pushes).toHaveLength(2);
    for (const p of pushes) {
      expect(p.method).toBe("ui.modal");
      const params = p.params as UiModalPush;
      expect(params.kind).toBe("alert");
      expect(params.pluginId).toBe("p");
      expect(params.panelId).toBe("home");
      if (params.kind !== "alert") throw new Error("unreachable");
      expect(params.alert.title).toBe("T");
    }
  });
});

describe("ui.showAlert end-to-end via fixture", () => {
  it("plugin's ui.showAlert returns { delivered: true } and pushes ui.modal", async () => {
    const harness = await buildHarness(["uimodals"]);
    try {
      // Subscribe so the fixture's broadcast lands on our socket.
      await call(harness.ctx, "ui.subscribe");
      // The fixture's stderr surfaces the host's response to its
      // `ui.showAlert` request as <<ALERTRESP>>{json}<<END>>.
      const logPath = join(harness.logDir, "uimodals.stderr.log");
      const respLine = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<ALERTRESP>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const resp = JSON.parse(respLine) as {
        id: number;
        result?: { delivered: boolean };
        error?: { code: number; message: string };
      };
      expect(resp.id).toBe(101);
      expect(resp.error).toBeUndefined();
      expect(resp.result?.delivered).toBe(true);
      // The subscribed socket must have received the ui.modal push.
      const modals = harness.sock.notifications("ui.modal");
      // The fixture races against subscribe — sub may have landed after
      // the modal push. waitFor a moment so it lands.
      const found = await waitFor(() => {
        const m = harness.sock.notifications("ui.modal");
        if (m.length === 0) return undefined;
        return m[0];
      }, 3000).catch(() => modals[0]);
      expect(found).toBeDefined();
      const payload = found.params as UiModalPush;
      expect(payload.kind).toBe("alert");
      if (payload.kind !== "alert") throw new Error("unreachable");
      expect(payload.pluginId).toBe("uimodals");
      expect(payload.panelId).toBe("home");
      expect(payload.alert.title).toBe("Delete note?");
      expect(payload.alert.actions).toHaveLength(2);
      expect(payload.alert.actions[1].variant).toBe("danger");
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.showBottomSheet file:// gate (Batch 4)", () => {
  // The Batch-3 file:// gate runs on `ui.render` panel trees only.
  // Batch 4 re-runs the gate on a BottomSheet's `child` at the
  // `ui.showBottomSheet` entry point, so a plugin can't ship
  // `/etc/passwd` via a BottomSheet to bypass the workspace boundary.
  // These three tests reuse validateFileUrlsAgainstWorkspace on the
  // BottomSheet child directly — same code path the host calls.

  let ws: string;
  let outside: string;

  beforeEach(async () => {
    ws = await makeTempDir("openvsmobile-bsgate-ws-");
    outside = await makeTempDir("openvsmobile-bsgate-out-");
    await writeFile(join(ws, "logo.png"), "p");
    await writeFile(join(outside, "secret"), "s");
  });

  afterEach(async () => {
    await rmTempDir(ws);
    await rmTempDir(outside);
  });

  it("rejects BottomSheet child with file:// outside workspace", async () => {
    const sheet = validateBottomSheet({
      id: "bs-evil",
      child: { kind: "Image", id: "bs-img", src: `file://${outside}/secret` },
    });
    const res = await validateFileUrlsAgainstWorkspace(
      sheet.child,
      "read",
      ws,
    );
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("rejects BottomSheet child via symlink escape", async () => {
    await symlink(join(outside, "secret"), join(ws, "evil"));
    const sheet = validateBottomSheet({
      id: "bs-escape",
      child: { kind: "Image", id: "bs-img", src: `file://${ws}/evil` },
    });
    const res = await validateFileUrlsAgainstWorkspace(
      sheet.child,
      "read",
      ws,
    );
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("unreachable");
    expect(res.code).toBe("outsideWorkspace");
  });

  it("accepts BottomSheet child with valid file:// + fs:read", async () => {
    const sheet = validateBottomSheet({
      id: "bs-ok",
      child: { kind: "Image", id: "bs-img", src: `file://${ws}/logo.png` },
    });
    const res = await validateFileUrlsAgainstWorkspace(
      sheet.child,
      "read",
      ws,
    );
    expect(res.ok).toBe(true);
  });
});

function findText(node: unknown, id: string): string | undefined {
  if (!node || typeof node !== "object") return undefined;
  const n = node as { id?: string; kind?: string; text?: string;
    children?: unknown[]; items?: unknown[] };
  if (n.kind === "Text" && n.id === id && typeof n.text === "string") {
    return n.text;
  }
  for (const arr of [n.children, n.items]) {
    if (!Array.isArray(arr)) continue;
    for (const c of arr) {
      const found = findText(c, id);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}
