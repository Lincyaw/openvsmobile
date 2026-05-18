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
  type UiBadge,
  type UiEventInput,
  type UiIcon,
  type UiListTile,
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
