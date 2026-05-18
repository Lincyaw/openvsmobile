// Unit tests for @openvsmobile/sdk.
//
// Two responsibilities the SDK absolutely must get right, per the
// issue's acceptance criteria:
//
//   1. `ctx.renderPanel(...)` produces the wire shape the host's
//      `ui.render` handler expects (panelId + tree as a typed UiNode).
//   2. An inbound `ui.event` from the host is demuxed into the
//      `onUiEvent` callback with the same payload.
//
// Both are exercised by feeding the SDK a `PassThrough` for stdin /
// stdout instead of forking a child process — that keeps these tests
// fast and avoids depending on the SDK's build artifacts (vitest runs
// the TypeScript source directly).

import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import {
  createPlugin,
  ui,
  type AccentToken,
  type PluginContext,
  type SizeToken,
  type SpacingToken,
  type StyleSlot,
  type UiAppGrid,
  type UiAppTile,
  type UiAspect,
  type UiBadge,
  type UiCheckbox,
  type UiDivider,
  type UiEventInput,
  type UiFlex,
  type UiGrid,
  type UiIcon,
  type UiInlineBanner,
  type UiListTile,
  type UiRadioGroup,
  type UiScroll,
  type UiSearchField,
  type UiSection,
  type UiSelect,
  type UiSlider,
  type UiStack,
  type UiSwitch,
  type UiTabBar,
} from "../src/index.js";

interface Harness {
  stdinIn: PassThrough;
  stdoutOut: PassThrough;
  outboundLines: string[];
  /// Resolves once the SDK has flushed at least `n` outbound lines.
  /// Watcher discipline: vitest test timeout (20s) is the outer fence —
  /// we don't add our own timer here, the test will just fail if the
  /// SDK never writes.
  waitForOutbound(n: number): Promise<string[]>;
  /// Push a JSON-RPC message into the SDK as if the host sent it.
  pushInbound(msg: object): void;
  /// Close stdin so the SDK's "stay alive" condition ends and Node can
  /// drain. Tests that don't want to keep the SDK running call this.
  close(): void;
}

const harnesses: Harness[] = [];

afterEach(() => {
  for (const h of harnesses.splice(0)) h.close();
});

function buildHarness(): Harness {
  const stdinIn = new PassThrough();
  const stdoutOut = new PassThrough();
  const outboundLines: string[] = [];

  const waiters: Array<{ n: number; resolve: (v: string[]) => void }> = [];

  stdoutOut.setEncoding("utf8");
  let pending = "";
  stdoutOut.on("data", (chunk: string) => {
    pending += chunk;
    let nl: number;
    while ((nl = pending.indexOf("\n")) !== -1) {
      const line = pending.slice(0, nl);
      pending = pending.slice(nl + 1);
      if (line.length === 0) continue;
      outboundLines.push(line);
      for (const w of waiters.splice(0)) {
        if (outboundLines.length >= w.n) {
          w.resolve(outboundLines.slice());
        } else {
          waiters.push(w);
        }
      }
    }
  });

  const h: Harness = {
    stdinIn,
    stdoutOut,
    outboundLines,
    waitForOutbound(n: number): Promise<string[]> {
      if (outboundLines.length >= n) return Promise.resolve(outboundLines.slice());
      return new Promise<string[]>((resolve) => {
        waiters.push({ n, resolve });
      });
    },
    pushInbound(msg: object): void {
      stdinIn.write(JSON.stringify(msg) + "\n");
    },
    close(): void {
      stdinIn.end();
      stdoutOut.end();
    },
  };
  harnesses.push(h);
  return h;
}

describe("ui.* constructors", () => {
  it("auto-generates ids when omitted and round-trips supplied ones", () => {
    const auto = ui.text({ text: "hi" });
    const fixed = ui.text({ id: "stable-id", text: "hi" });
    expect(auto.id.length).toBeGreaterThan(0);
    expect(fixed.id).toBe("stable-id");
  });

  it("rejects malformed widget by absence (TS surface) but accepts the §4.3 vocabulary", () => {
    // No runtime assertion of "unknown kinds" — that's the host's
    // validator. The SDK trusts what its caller passes. The test here
    // is really documenting: the canonical happy-path tree round-
    // trips into the JSON shape the host accepts.
    const tree = ui.column({
      id: "root",
      gap: 8,
      children: [
        ui.section({
          id: "sec",
          title: "Greet",
          children: [
            ui.text({ id: "msg", text: "Hello" }),
            ui.textField({ id: "name", label: "Your name", value: "" }),
            ui.button({ id: "go", label: "Greet", style: "primary" }),
          ],
        }),
        ui.spacer({ id: "sp", size: 16 }),
      ],
    });
    expect(tree.kind).toBe("Column");
    expect(tree.gap).toBe(8);
    expect(tree.children).toHaveLength(2);
    const section = tree.children[0];
    if (section.kind !== "Section") throw new Error("unreachable");
    expect(section.title).toBe("Greet");
    expect(section.children.map((c) => c.kind)).toEqual([
      "Text",
      "TextField",
      "Button",
    ]);
  });
});

describe("Batch 1 widgets (UiIcon / UiBadge / UiListTile / UiAppGrid)", () => {
  it("ui.icon round-trips a tokenized size and accent", () => {
    const icon: UiIcon = ui.icon({
      id: "i",
      name: "home",
      size: "md" satisfies StyleSlot<SizeToken>,
      accent: "brand" satisfies AccentToken,
    });
    expect(icon.kind).toBe("Icon");
    expect(icon.name).toBe("home");
    expect(icon.size).toBe("md");
    expect(icon.accent).toBe("brand");
  });

  it("ui.badge defaults to pill variant when omitted", () => {
    const b: UiBadge = ui.badge({ id: "b", text: "12" });
    expect(b.kind).toBe("Badge");
    expect(b.variant).toBe("pill");
    expect(b.text).toBe("12");
  });

  it("ui.badge honors variant + count + accent overrides", () => {
    const b: UiBadge = ui.badge({
      id: "b2",
      variant: "dot",
      count: 0,
      accent: "danger",
    });
    expect(b.variant).toBe("dot");
    expect(b.count).toBe(0);
    expect(b.accent).toBe("danger");
  });

  it("ui.listTile carries leading + trailing + swipeActions (plumbed)", () => {
    const tile: UiListTile = ui.listTile({
      id: "row",
      title: "Hello",
      subtitle: "world",
      leading: ui.icon({ id: "row.lead", name: "user" }),
      trailing: ui.badge({ id: "row.trail", variant: "dot", accent: "info" }),
      onTapEvent: "open",
      swipeActions: [
        { label: "Delete", eventId: "row.delete", accent: "danger" },
      ],
    });
    expect(tile.kind).toBe("ListTile");
    expect(tile.title).toBe("Hello");
    expect(tile.subtitle).toBe("world");
    expect((tile.leading as UiIcon).kind).toBe("Icon");
    expect((tile.trailing as UiBadge).kind).toBe("Badge");
    expect(tile.onTapEvent).toBe("open");
    expect(tile.swipeActions).toHaveLength(1);
    expect(tile.swipeActions?.[0].label).toBe("Delete");
  });

  it("ui.appGrid carries items + optional columns + onLaunchEvent", () => {
    const tile: UiAppTile = {
      id: "t1",
      name: "Notes",
      icon: "file-text",
      accent: "brand",
    };
    const grid: UiAppGrid = ui.appGrid({
      id: "g",
      items: [tile],
      columns: 4,
      onLaunchEvent: "launch",
    });
    expect(grid.kind).toBe("AppGrid");
    expect(grid.items).toHaveLength(1);
    expect(grid.items[0].name).toBe("Notes");
    expect(grid.items[0].icon).toBe("file-text");
    expect(grid.columns).toBe(4);
    expect(grid.onLaunchEvent).toBe("launch");
  });

  it("ui.appGrid accepts the { uri } icon variant for Batch 3 forward-compat", () => {
    const grid = ui.appGrid({
      id: "g2",
      items: [
        {
          id: "t",
          name: "Custom",
          icon: { uri: "https://example/icon.png" },
        },
      ],
    });
    expect(grid.items[0].icon).toEqual({ uri: "https://example/icon.png" });
  });

  it("StyleSlot<SpacingToken> still accepts raw numbers (back-compat)", () => {
    // The new typed shape continues to honor the legacy number form for
    // one minor version. This test pins the contract.
    const slot: StyleSlot<SpacingToken> = 8;
    const slotTok: StyleSlot<SpacingToken> = "sm";
    expect(typeof slot).toBe("number");
    expect(typeof slotTok).toBe("string");
    const col = ui.column({ id: "c", gap: slotTok, children: [] });
    expect(col.gap).toBe("sm");
    const colNum = ui.column({ id: "c2", gap: 8, children: [] });
    expect(colNum.gap).toBe(8);
  });

  it("ui.section.variant round-trips plain | card | inset", () => {
    const plain: UiSection = ui.section({ id: "p", children: [] });
    const card: UiSection = ui.section({
      id: "c",
      variant: "card",
      children: [],
    });
    const inset: UiSection = ui.section({
      id: "i",
      variant: "inset",
      title: "Settings",
      children: [],
    });
    expect(plain.variant).toBeUndefined();
    expect(card.variant).toBe("card");
    expect(inset.variant).toBe("inset");
    expect(inset.title).toBe("Settings");
  });

  it("ui.toggle emits kind=Switch with value + label + onChangeEvent", () => {
    const sw: UiSwitch = ui.toggle({
      id: "sw",
      label: "Private",
      value: true,
      onChangeEvent: "toggled",
    });
    expect(sw.kind).toBe("Switch");
    expect(sw.value).toBe(true);
    expect(sw.label).toBe("Private");
    expect(sw.onChangeEvent).toBe("toggled");
  });

  it("ui.select carries options + label + value + onChangeEvent", () => {
    const sel: UiSelect = ui.select({
      id: "sel",
      label: "Theme",
      options: [
        { value: "system", label: "System" },
        { value: "light", label: "Light" },
        { value: "dark", label: "Dark" },
      ],
      value: "light",
      onChangeEvent: "themePicked",
    });
    expect(sel.kind).toBe("Select");
    expect(sel.options).toHaveLength(3);
    expect(sel.value).toBe("light");
    expect(sel.onChangeEvent).toBe("themePicked");
  });

  it("ui.banner requires title + accent and accepts action + dismissEventId", () => {
    const b: UiInlineBanner = ui.banner({
      id: "b",
      title: "Unsaved",
      body: "Save before navigating away.",
      accent: "warning",
      action: { label: "Save", eventId: "save" },
      dismissEventId: "dismiss",
    });
    expect(b.kind).toBe("Banner");
    expect(b.title).toBe("Unsaved");
    expect(b.accent).toBe("warning");
    expect(b.action?.eventId).toBe("save");
    expect(b.dismissEventId).toBe("dismiss");
  });

  it("ui.divider defaults orientation to undefined", () => {
    const d: UiDivider = ui.divider();
    expect(d.kind).toBe("Divider");
    expect(d.orientation).toBeUndefined();
    const v: UiDivider = ui.divider({ orientation: "vertical" });
    expect(v.orientation).toBe("vertical");
  });

  it("ui.column / ui.row / ui.spacer accept a bare token string for gap/size", () => {
    // Direct literal — no intermediate `as StyleSlot<...>` cast. If the
    // constructor parameter narrows back to `number`, this fails TS
    // compile before the runtime assertion ever runs.
    const col = ui.column({ id: "tc", gap: "sm", children: [] });
    const row = ui.row({ id: "tr", gap: "lg", children: [] });
    const sp = ui.spacer({ id: "ts", size: "md" });
    expect(col.gap).toBe("sm");
    expect(row.gap).toBe("lg");
    expect(sp.size).toBe("md");
    // Numeric path still compiles for the same constructors.
    const colNum = ui.column({ id: "tcn", gap: 12, children: [] });
    expect(colNum.gap).toBe(12);
  });
});

describe("createPlugin: renderPanel round-trip", () => {
  it("ctx.renderPanel emits a single ui.render request with the supplied panelId and tree", async () => {
    const h = buildHarness();
    let activated: PluginContext | null = null;
    const plugin = createPlugin({
      onActivate(ctx): void {
        activated = ctx;
        ctx.renderPanel(
          "home",
          ui.column({
            id: "root",
            children: [ui.text({ id: "greeting", text: "Hello" })],
          }),
        );
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    expect(activated).not.toBeNull();
    const msg = JSON.parse(first as string) as {
      jsonrpc: string;
      method?: string;
      params?: { panelId?: string; tree?: { kind?: string; id?: string } };
    };
    expect(msg.jsonrpc).toBe("2.0");
    expect(msg.method).toBe("ui.render");
    expect(msg.params?.panelId).toBe("home");
    expect(msg.params?.tree?.kind).toBe("Column");
    expect(msg.params?.tree?.id).toBe("root");
  });

  it("ctx.log emits a host.log notification with the supplied level + msg", async () => {
    const h = buildHarness();
    const plugin = createPlugin({
      onActivate(ctx): void {
        ctx.log("warn", "watch out");
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const msg = JSON.parse(first as string) as {
      method?: string;
      params?: { level?: string; msg?: string };
    };
    expect(msg.method).toBe("host.log");
    expect(msg.params).toEqual({ level: "warn", msg: "watch out" });
  });
});

describe("createPlugin: ui.event dispatch", () => {
  it("forwards inbound ui.event to onUiEvent with the same payload", async () => {
    const h = buildHarness();
    const captured: UiEventInput[] = [];
    const plugin = createPlugin({
      onUiEvent(_ctx, event): void {
        captured.push(event);
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    // Give the SDK a microtask to wire the listener before we push.
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      id: 42,
      method: "ui.event",
      params: {
        panelId: "home",
        nodeId: "name",
        type: "changed",
        payload: { value: "Ada" },
      },
    });
    // SDK acks every request — wait for the ack to know the event has
    // been demuxed and the callback finished.
    const [ack] = await h.waitForOutbound(1);
    expect(captured).toHaveLength(1);
    expect(captured[0]).toEqual({
      panelId: "home",
      nodeId: "name",
      type: "changed",
      payload: { value: "Ada" },
    });
    const ackMsg = JSON.parse(ack as string) as {
      id?: unknown;
      result?: unknown;
      error?: unknown;
    };
    expect(ackMsg.id).toBe(42);
    expect(ackMsg.result).toBeDefined();
    expect(ackMsg.error).toBeUndefined();
  });

  it("acks a command.invoke and returns the handler's result", async () => {
    const h = buildHarness();
    const plugin = createPlugin({
      onCommand(_ctx, commandId, args): unknown {
        return { commandId, args };
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      id: 7,
      method: "command.invoke",
      params: { id: "hello.greet", args: { who: "world" } },
    });
    const [ack] = await h.waitForOutbound(1);
    const ackMsg = JSON.parse(ack as string) as {
      id?: unknown;
      result?: { commandId?: string; args?: { who?: string } };
    };
    expect(ackMsg.id).toBe(7);
    expect(ackMsg.result?.commandId).toBe("hello.greet");
    expect(ackMsg.result?.args?.who).toBe("world");
  });

  it("replies methodNotFound when the host calls an unknown method", async () => {
    const h = buildHarness();
    const plugin = createPlugin({});
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      id: 99,
      method: "totally.bogus",
      params: {},
    });
    const [ack] = await h.waitForOutbound(1);
    const ackMsg = JSON.parse(ack as string) as {
      id?: unknown;
      error?: { code?: number; message?: string };
    };
    expect(ackMsg.id).toBe(99);
    expect(ackMsg.error?.code).toBe(-32601);
  });
});

describe("Batch 5 widgets (long tail)", () => {
  it("ui.grid carries children + columns + gap", () => {
    const g: UiGrid = ui.grid({
      id: "g",
      columns: 3,
      gap: "md",
      children: [
        ui.text({ id: "t1", text: "a" }),
        ui.text({ id: "t2", text: "b" }),
      ],
    });
    expect(g.kind).toBe("Grid");
    expect(g.columns).toBe(3);
    expect(g.gap).toBe("md");
    expect(g.children).toHaveLength(2);
  });

  it("ui.grid accepts the 'adaptive' columns sentinel", () => {
    const g = ui.grid({ id: "g2", columns: "adaptive", children: [] });
    expect(g.columns).toBe("adaptive");
  });

  it("ui.stack carries children + alignment", () => {
    const s: UiStack = ui.stack({
      id: "s",
      alignment: "bottomEnd",
      children: [ui.text({ id: "x", text: "x" })],
    });
    expect(s.kind).toBe("Stack");
    expect(s.alignment).toBe("bottomEnd");
  });

  it("ui.aspect carries ratio + child", () => {
    const a: UiAspect = ui.aspect({
      id: "a",
      ratio: 16 / 9,
      child: ui.text({ id: "t", text: "hi" }),
    });
    expect(a.kind).toBe("Aspect");
    expect(a.ratio).toBeCloseTo(16 / 9);
    expect(a.child.kind).toBe("Text");
  });

  it("ui.flex carries flex + child", () => {
    const f: UiFlex = ui.flex({
      id: "f",
      flex: 2,
      child: ui.text({ id: "t", text: "x" }),
    });
    expect(f.kind).toBe("Flex");
    expect(f.flex).toBe(2);
  });

  it("ui.scroll defaults axis to undefined", () => {
    const s: UiScroll = ui.scroll({
      id: "sc",
      child: ui.text({ id: "t", text: "x" }),
    });
    expect(s.kind).toBe("Scroll");
    expect(s.axis).toBeUndefined();
    const h = ui.scroll({
      id: "sc2",
      axis: "horizontal",
      child: ui.text({ id: "t2", text: "x" }),
    });
    expect(h.axis).toBe("horizontal");
  });

  it("ui.tabBar carries tabs + activeId + onChangeEvent", () => {
    const tb: UiTabBar = ui.tabBar({
      id: "tb",
      activeId: "a",
      onChangeEvent: "tabPicked",
      tabs: [
        { id: "a", label: "Alpha", icon: "home" },
        { id: "b", label: "Beta" },
      ],
    });
    expect(tb.kind).toBe("TabBar");
    expect(tb.tabs).toHaveLength(2);
    expect(tb.tabs[0].icon).toBe("home");
    expect(tb.activeId).toBe("a");
    expect(tb.onChangeEvent).toBe("tabPicked");
  });

  it("ui.searchField defaults all optional fields to undefined", () => {
    const s: UiSearchField = ui.searchField();
    expect(s.kind).toBe("SearchField");
    expect(s.value).toBeUndefined();
    const populated = ui.searchField({
      id: "sf",
      value: "ada",
      placeholder: "search…",
      onChangeEvent: "q",
    });
    expect(populated.value).toBe("ada");
    expect(populated.placeholder).toBe("search…");
    expect(populated.onChangeEvent).toBe("q");
  });

  it("ui.checkbox carries value + label + onChangeEvent", () => {
    const c: UiCheckbox = ui.checkbox({
      id: "c",
      value: true,
      label: "Subscribe",
      onChangeEvent: "sub",
    });
    expect(c.kind).toBe("Checkbox");
    expect(c.value).toBe(true);
    expect(c.label).toBe("Subscribe");
    expect(c.onChangeEvent).toBe("sub");
  });

  it("ui.radioGroup carries options + value + onChangeEvent", () => {
    const r: UiRadioGroup = ui.radioGroup({
      id: "r",
      value: "x",
      onChangeEvent: "pick",
      options: [
        { value: "x", label: "X" },
        { value: "y", label: "Y" },
      ],
    });
    expect(r.kind).toBe("RadioGroup");
    expect(r.options).toHaveLength(2);
    expect(r.value).toBe("x");
    expect(r.onChangeEvent).toBe("pick");
  });

  it("ui.slider carries min + max + step + value + onChangeEvent", () => {
    const s: UiSlider = ui.slider({
      id: "s",
      min: 0,
      max: 100,
      step: 5,
      value: 50,
      onChangeEvent: "moved",
    });
    expect(s.kind).toBe("Slider");
    expect(s.min).toBe(0);
    expect(s.max).toBe(100);
    expect(s.step).toBe(5);
    expect(s.value).toBe(50);
    expect(s.onChangeEvent).toBe("moved");
    // Continuous variant: step omitted.
    const cont = ui.slider({ id: "s2", min: 0, max: 1, value: 0.5 });
    expect(cont.step).toBeUndefined();
  });

  it("ui.section carries the new collapsible flag", () => {
    const s = ui.section({ id: "s", collapsible: true, children: [] });
    expect(s.collapsible).toBe(true);
    const omitted = ui.section({ id: "s2", children: [] });
    expect(omitted.collapsible).toBeUndefined();
  });
});
