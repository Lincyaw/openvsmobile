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
  type NotificationInput,
  type NotificationReplyInput,
  type PluginContext,
  type SizeToken,
  type SpacingToken,
  type StyleSlot,
  type UiActionSheet,
  type UiAlertDialog,
  type UiAppGrid,
  type UiAppTile,
  type UiAspect,
  type UiBadge,
  type UiBottomSheet,
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
  type WorkspaceRef,
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

  it("attaches eyes-free metadata to any constructed node", () => {
    const node = ui.withMetadata(ui.text({ id: "status", text: "Done" }), {
      accessibilityLabel: "Agent status",
      spokenValue: "Agent finished",
      focusRole: "status",
      focusOrder: 1,
      voiceInputEvent: "voice.reply",
      voiceShortcut: true,
    });
    expect(node).toMatchObject({
      kind: "Text",
      id: "status",
      text: "Done",
      accessibilityLabel: "Agent status",
      spokenValue: "Agent finished",
      focusRole: "status",
      focusOrder: 1,
      voiceInputEvent: "voice.reply",
      voiceShortcut: true,
    });
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

  it("forwards inbound notification.reply to onNotificationReply", async () => {
    const h = buildHarness();
    const captured: NotificationReplyInput[] = [];
    const plugin = createPlugin({
      onNotificationReply(_ctx, reply): void {
        captured.push(reply);
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      id: 9,
      method: "notification.reply",
      params: {
        pluginId: "agent",
        notificationId: "n1",
        text: "continue",
        panelId: "home",
        event: "reply",
        context: { runId: "r1" },
      },
    });
    const [ack] = await h.waitForOutbound(1);
    expect(captured).toEqual([
      {
        pluginId: "agent",
        notificationId: "n1",
        text: "continue",
        panelId: "home",
        event: "reply",
        context: { runId: "r1" },
      },
    ]);
    const ackMsg = JSON.parse(ack as string) as {
      id?: unknown;
      result?: unknown;
      error?: unknown;
    };
    expect(ackMsg.id).toBe(9);
    expect(ackMsg.result).toBeDefined();
    expect(ackMsg.error).toBeUndefined();
  });

  it("ctx.showAlert serializes ui.showAlert request and resolves on host's reply", async () => {
    const h = buildHarness();
    let activated: PluginContext | null = null;
    const plugin = createPlugin({
      onActivate(ctx): void {
        activated = ctx;
        void ctx.showAlert("home", {
          id: "confirm",
          title: "Delete?",
          actions: [
            { label: "Cancel", eventId: "cancel" },
            { label: "Delete", eventId: "delete", variant: "danger" },
          ],
        });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    expect(activated).not.toBeNull();
    const msg = JSON.parse(first as string) as {
      id?: number;
      method?: string;
      params?: {
        panelId?: string;
        alert?: UiAlertDialog;
      };
    };
    expect(msg.method).toBe("ui.showAlert");
    expect(msg.id).toBeTypeOf("number");
    expect(msg.params?.panelId).toBe("home");
    expect(msg.params?.alert?.title).toBe("Delete?");
    expect(msg.params?.alert?.actions).toHaveLength(2);
  });

  it("ctx.showActionSheet + ctx.showBottomSheet serialize their wire shapes", async () => {
    const h = buildHarness();
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx.showActionSheet("home", {
          id: "picker",
          actions: [
            { label: "15s", eventId: "i:15" },
            { label: "1m", eventId: "i:60" },
          ],
        });
        void ctx.showBottomSheet("home", {
          id: "details",
          title: "Details",
          child: ui.text({ id: "bs-t", text: "info" }),
        });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const lines = await h.waitForOutbound(2);
    const parsed = lines.map((l) => JSON.parse(l) as {
      id?: number;
      method?: string;
      params?: {
        panelId?: string;
        sheet?: UiActionSheet | UiBottomSheet;
      };
    });
    const sheetMsg = parsed.find((p) => p.method === "ui.showActionSheet");
    const bsMsg = parsed.find((p) => p.method === "ui.showBottomSheet");
    expect(sheetMsg).toBeDefined();
    expect(bsMsg).toBeDefined();
    expect(sheetMsg?.params?.panelId).toBe("home");
    expect((sheetMsg?.params?.sheet as UiActionSheet).actions).toHaveLength(2);
    expect(bsMsg?.params?.panelId).toBe("home");
    expect((bsMsg?.params?.sheet as UiBottomSheet).title).toBe("Details");
    expect((bsMsg?.params?.sheet as UiBottomSheet).child).toBeDefined();
  });

  it("ui.alertDialog / actionSheet / bottomSheet constructors produce the right shapes", () => {
    const alert = ui.alertDialog({
      id: "a",
      title: "T",
      body: "B",
      actions: [{ label: "OK", eventId: "ok", variant: "primary" }],
      dismissible: false,
    });
    expect(alert.id).toBe("a");
    expect(alert.body).toBe("B");
    expect(alert.dismissible).toBe(false);
    expect(alert.actions[0].variant).toBe("primary");

    const sheet = ui.actionSheet({
      id: "s",
      title: "Pick",
      actions: [{ label: "A", eventId: "a", icon: "clock", accent: "info" }],
      dismissEventId: "cancel",
    });
    expect(sheet.title).toBe("Pick");
    expect(sheet.actions[0].icon).toBe("clock");
    expect(sheet.dismissEventId).toBe("cancel");

    const bs = ui.bottomSheet({
      id: "bs",
      child: ui.text({ id: "bs-t", text: "x" }),
      dismissEventId: "close",
    });
    expect(bs.id).toBe("bs");
    expect(bs.child).toBeDefined();
    expect(bs.dismissEventId).toBe("close");
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

describe("Phase-0 workspace surface", () => {
  it("ctx.currentWorkspace serializes a workspace.current request and unwraps the host's payload", async () => {
    const h = buildHarness();
    let resolved: WorkspaceRef | null | undefined;
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx.currentWorkspace().then((ws) => {
          resolved = ws;
        });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const req = JSON.parse(first as string) as {
      jsonrpc: string;
      id?: number;
      method?: string;
      params?: unknown;
    };
    expect(req.jsonrpc).toBe("2.0");
    expect(req.method).toBe("workspace.current");
    expect(req.id).toBeTypeOf("number");
    // Simulate the host's response.
    h.pushInbound({
      jsonrpc: "2.0",
      id: req.id,
      result: {
        workspace: { id: "ws-uuid", root: "/tmp/repo", label: "repo" },
      },
    });
    // Yield to flush the resolved-promise microtask.
    await new Promise((r) => setTimeout(r, 5));
    expect(resolved).toEqual({
      id: "ws-uuid",
      root: "/tmp/repo",
      label: "repo",
    });
  });

  it("ctx.currentWorkspace resolves null when the host reports no active workspace", async () => {
    const h = buildHarness();
    let resolved: WorkspaceRef | null | undefined = undefined;
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx.currentWorkspace().then((ws) => {
          resolved = ws;
        });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const req = JSON.parse(first as string) as { id?: number };
    h.pushInbound({
      jsonrpc: "2.0",
      id: req.id,
      result: { workspace: null },
    });
    await new Promise((r) => setTimeout(r, 5));
    expect(resolved).toBeNull();
  });

  it("onWorkspaceActivated fires with a workspace payload, then with null", async () => {
    const h = buildHarness();
    const seen: Array<WorkspaceRef | null> = [];
    const plugin = createPlugin({
      onWorkspaceActivated(_ctx, ws): void {
        seen.push(ws);
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    // Wait one microtask so the stdin data listener is wired.
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      method: "workspace.activated",
      params: {
        workspace: { id: "ws-a", root: "/tmp/a", label: "a" },
      },
    });
    h.pushInbound({
      jsonrpc: "2.0",
      method: "workspace.activated",
      params: { workspace: null },
    });
    // Notifications carry no id → no ack. Give the SDK a tick to drain.
    await new Promise((r) => setTimeout(r, 10));
    expect(seen).toHaveLength(2);
    expect(seen[0]).toEqual({ id: "ws-a", root: "/tmp/a", label: "a" });
    expect(seen[1]).toBeNull();
  });

  it("an unhandled workspace.activated notification is dropped without throwing or logging", async () => {
    const h = buildHarness();
    // No callback. The notification should be a no-op — no methodNotFound
    // frame, no host.log noise, no thrown error.
    const plugin = createPlugin({});
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    await Promise.resolve();
    h.pushInbound({
      jsonrpc: "2.0",
      method: "workspace.activated",
      params: { workspace: null },
    });
    await new Promise((r) => setTimeout(r, 10));
    // No outbound frame whatsoever — the notification has no id so the SDK
    // does not ack, and there is no callback to throw or log.
    expect(h.outboundLines).toEqual([]);
  });
});

describe("Phase-6A notify.show surface", () => {
  it("ctx.showNotification serializes a notify.show request and resolves with {id} on the host's reply", async () => {
    const h = buildHarness();
    let resolved: { id: string } | undefined;
    const input: NotificationInput = {
      // `source` is host-overridden but the SDK type still requires it;
      // any string is fine, the host overwrites it before validation.
      source: "ignored",
      level: "info",
      title: "Build green",
      body: "All checks passed",
    };
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx.showNotification(input).then((r) => {
          resolved = r;
        });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const req = JSON.parse(first as string) as {
      jsonrpc: string;
      id?: number;
      method?: string;
      params?: { input?: NotificationInput };
    };
    expect(req.jsonrpc).toBe("2.0");
    expect(req.method).toBe("notify.show");
    expect(req.id).toBeTypeOf("number");
    expect(req.params?.input?.title).toBe("Build green");
    expect(req.params?.input?.level).toBe("info");
    // Simulate the host's success-shaped reply.
    h.pushInbound({
      jsonrpc: "2.0",
      id: req.id,
      result: { id: "notif-abc-123" },
    });
    await new Promise((r) => setTimeout(r, 5));
    expect(resolved).toEqual({ id: "notif-abc-123" });
  });

  it("ctx.showNotification rejects when the host returns an error frame", async () => {
    const h = buildHarness();
    let caught: Error | null = null;
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx
          .showNotification({
            source: "ignored",
            level: "info",
            // Empty title → host's validator would reject in the wild.
            // We just need the host to *reply* with an error frame; the
            // SDK has no validation of its own.
            title: "",
          })
          .catch((err) => {
            caught = err as Error;
          });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const req = JSON.parse(first as string) as { id?: number };
    h.pushInbound({
      jsonrpc: "2.0",
      id: req.id,
      error: { code: -32602, message: "title required" },
    });
    await new Promise((r) => setTimeout(r, 5));
    expect(caught).not.toBeNull();
    expect((caught as unknown as Error).message).toContain("title required");
  });

  it("ctx.showNotification rejects when the host's reply omits a string id", async () => {
    const h = buildHarness();
    let caught: Error | null = null;
    const plugin = createPlugin({
      onActivate(ctx): void {
        void ctx
          .showNotification({
            source: "ignored",
            level: "info",
            title: "x",
          })
          .catch((err) => {
            caught = err as Error;
          });
      },
    });
    plugin.run({ stdin: h.stdinIn, stdout: h.stdoutOut });
    const [first] = await h.waitForOutbound(1);
    const req = JSON.parse(first as string) as { id?: number };
    h.pushInbound({
      jsonrpc: "2.0",
      id: req.id,
      result: {}, // missing id
    });
    await new Promise((r) => setTimeout(r, 5));
    expect(caught).not.toBeNull();
    expect((caught as unknown as Error).message).toContain("missing string id");
  });
});
