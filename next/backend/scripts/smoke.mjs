#!/usr/bin/env node
// Smoke test for the openvsmobile-next backend.
//
// Exercises every public method + waits for terminal.data and
// terminal.exit notifications. Exits non-zero on any failure.
//
// Usage:
//   node scripts/smoke.mjs                  # uses default port 7860 + auto token
//   PORT=7861 TOKEN=abc node scripts/smoke.mjs
//
// If TOKEN is unset, the script reads ~/.config/openvsmobile-next/config.json
// to discover the token the backend wrote on first start.

import WebSocket from "ws";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  mkdtempSync,
  writeFileSync,
  mkdirSync,
  symlinkSync,
  realpathSync,
} from "node:fs";

const PORT = Number(process.env.PORT ?? 7860);
const HOST = process.env.HOST ?? "127.0.0.1";

function resolveToken() {
  if (process.env.TOKEN) return process.env.TOKEN;
  if (process.env.OPENVSMOBILE_TOKEN) return process.env.OPENVSMOBILE_TOKEN;
  const cfgPath = join(homedir(), ".config", "openvsmobile-next", "config.json");
  try {
    const raw = readFileSync(cfgPath, "utf8");
    const { token } = JSON.parse(raw);
    if (typeof token === "string") return token;
  } catch {
    // Fall through to error below.
  }
  throw new Error(
    `no token: set TOKEN=... or ensure the backend has been started at least once`,
  );
}

class Client {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.notifs = [];
    this.notifWaiters = [];
  }
  async connect() {
    this.ws = new WebSocket(this.url);
    await new Promise((res, rej) => {
      this.ws.once("open", res);
      this.ws.once("error", rej);
    });
    this.ws.on("message", (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.id !== undefined) {
        const c = this.pending.get(m.id);
        if (!c) return;
        this.pending.delete(m.id);
        if (m.error) c.rej(m.error);
        else c.res(m.result);
        return;
      }
      this.notifs.push({ method: m.method, params: m.params });
      for (const w of this.notifWaiters.splice(0)) w();
    });
  }
  call(method, params) {
    const id = this.nextId++;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }
  async waitNotif(predicate, timeoutMs = 3000) {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const idx = this.notifs.findIndex(predicate);
      if (idx >= 0) return this.notifs.splice(idx, 1)[0];
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error("notification timeout");
      await new Promise((res) => {
        const t = setTimeout(res, remaining);
        this.notifWaiters.push(() => {
          clearTimeout(t);
          res();
        });
      });
    }
  }
  close() {
    this.ws.close();
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error("ASSERT: " + msg);
}

async function main() {
  const token = resolveToken();
  const c = new Client(`ws://${HOST}:${PORT}/rpc`);
  await c.connect();

  // 1. Handshake
  const hs = await c.call("auth.handshake", {
    token,
    protocolVersion: "1.0",
    client: { name: "smoke", version: "0" },
  });
  assert(hs.ok === true, "handshake ok");
  assert(typeof hs.serverVersion === "string", "serverVersion present");
  assert(typeof hs.defaultCwd === "string" && hs.defaultCwd.length > 0,
    `defaultCwd present, got ${hs.defaultCwd}`);
  console.log("[ok] auth.handshake (defaultCwd=%s)", hs.defaultCwd);

  // 1b. system.ping
  const ping = await c.call("system.ping", {});
  assert(typeof ping.now === "number" && ping.now > 0, "ping returns numeric now");
  console.log("[ok] system.ping");

  // 2. workspace.list (empty)
  const empty = await c.call("workspace.list", {});
  assert(Array.isArray(empty.active), "active is array");
  assert(Array.isArray(empty.recents), "recents is array");
  console.log("[ok] workspace.list (active=%d, recents=%d)", empty.active.length, empty.recents.length);

  // 3. Open a fresh scratch dir so we don't depend on /tmp ownership.
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "openvsmobile-smoke-")));
  writeFileSync(join(scratch, "hello.txt"), "hello world\n");
  writeFileSync(join(scratch, "tiny.bin"), Buffer.from([0, 1, 2, 0, 3]));

  const opened = await c.call("workspace.open", { root: scratch });
  assert(opened.workspace?.id, "workspace has id");
  assert(opened.workspace.root === scratch, "workspace root matches");
  console.log("[ok] workspace.open -> %s", opened.workspace.id);

  // 4. workspace.current
  const cur = await c.call("workspace.current", {});
  assert(cur.workspace?.id === opened.workspace.id, "current matches opened");
  console.log("[ok] workspace.current");

  // 5. fs.listDir (workspace-scoped)
  const ls = await c.call("fs.listDir", {
    workspaceId: opened.workspace.id,
    path: scratch,
  });
  const names = ls.entries.map((e) => e.name).sort();
  assert(names.includes("hello.txt"), "lists hello.txt");
  assert(names.includes("tiny.bin"), "lists tiny.bin");
  console.log("[ok] fs.listDir (workspace-scoped)");

  // 6. fs.listDir picker
  const picker = await c.call("fs.listDir", { path: "/", picker: true });
  assert(Array.isArray(picker.entries), "picker returns entries");
  console.log("[ok] fs.listDir picker (root has %d entries)", picker.entries.length);

  // 7. fs.listDir refuses outside workspace
  let denied = false;
  try {
    await c.call("fs.listDir", {
      workspaceId: opened.workspace.id,
      path: "/etc",
    });
  } catch (e) {
    denied = true;
    assert(e.code === -32602, `denied code is invalidParams, got ${e.code}`);
  }
  assert(denied, "fs.listDir refused path outside workspace");
  console.log("[ok] fs.listDir refuses outside path");

  // 8. fs.readFile text
  const text = await c.call("fs.readFile", {
    workspaceId: opened.workspace.id,
    path: join(scratch, "hello.txt"),
  });
  assert(text.encoding === "utf8", `text encoding is utf8, got ${text.encoding}`);
  assert(Buffer.from(text.contentBase64, "base64").toString() === "hello world\n", "text content matches");
  console.log("[ok] fs.readFile text");

  // 9. fs.readFile binary
  const bin = await c.call("fs.readFile", {
    workspaceId: opened.workspace.id,
    path: join(scratch, "tiny.bin"),
  });
  assert(bin.encoding === "binary", `binary encoding is binary, got ${bin.encoding}`);
  console.log("[ok] fs.readFile binary");

  // 9b. Symlink escape: a symlink INSIDE the workspace that points OUTSIDE
  //     must not allow reading the target.
  const outside = realpathSync(mkdtempSync(join(tmpdir(), "openvsmobile-outside-")));
  writeFileSync(join(outside, "secret.txt"), "should not be readable\n");
  symlinkSync(outside, join(scratch, "escape"));
  let symEscaped = false;
  try {
    await c.call("fs.readFile", {
      workspaceId: opened.workspace.id,
      path: join(scratch, "escape", "secret.txt"),
    });
  } catch (e) {
    symEscaped = true;
    assert(e.code === -32602, `symlink-escape code is invalidParams, got ${e.code}`);
  }
  assert(symEscaped, "fs.readFile through symlink-out is refused");
  console.log("[ok] symlink escape refused");

  // 9c. Workspace root that is itself a symlink to a real dir — normal
  //     in-scope reads still work because the boundary realpaths on open.
  const realDir = realpathSync(mkdtempSync(join(tmpdir(), "openvsmobile-real-")));
  writeFileSync(join(realDir, "inside.txt"), "hi from real\n");
  const symRoot = join(tmpdir(), `openvsmobile-symroot-${Date.now()}`);
  symlinkSync(realDir, symRoot);
  const symOpened = await c.call("workspace.open", { root: symRoot });
  assert(symOpened.workspace.root === realDir,
    `workspace root is realpath'd, got ${symOpened.workspace.root}`);
  const symRead = await c.call("fs.readFile", {
    workspaceId: symOpened.workspace.id,
    path: join(realDir, "inside.txt"),
  });
  assert(Buffer.from(symRead.contentBase64, "base64").toString() === "hi from real\n",
    "read through symlink'd root works");
  // Reading via the symlink form also works (realpath happens on each call).
  const symRead2 = await c.call("fs.readFile", {
    workspaceId: symOpened.workspace.id,
    path: join(symRoot, "inside.txt"),
  });
  assert(Buffer.from(symRead2.contentBase64, "base64").toString() === "hi from real\n",
    "read via symlink alias of root works");
  await c.call("workspace.close", { id: symOpened.workspace.id });
  await c.waitNotif((n) =>
    n.method === "workspace.closed" && n.params.id === symOpened.workspace.id);
  // Make sure `opened` is the current focus again before later assertions.
  await c.call("workspace.activate", { id: opened.workspace.id });
  console.log("[ok] symlinked workspace root resolves on open");

  // 10. Second workspace + activate
  const scratch2 = realpathSync(mkdtempSync(join(tmpdir(), "openvsmobile-smoke2-")));
  const opened2 = await c.call("workspace.open", { root: scratch2 });
  assert(opened2.workspace.id !== opened.workspace.id, "second workspace id differs");
  const list2 = await c.call("workspace.list", {});
  assert(list2.active.length === 2, `expect 2 active, got ${list2.active.length}`);
  console.log("[ok] workspace open #2 (active=%d)", list2.active.length);

  const act = await c.call("workspace.activate", { id: opened.workspace.id });
  assert(act.workspace.id === opened.workspace.id, "activated workspace 1");
  console.log("[ok] workspace.activate");

  // 10b. workspace.open with activate:false — currentId must NOT change.
  const beforeCur = await c.call("workspace.current", {});
  const beforeId = beforeCur.workspace?.id;
  const scratch3 = realpathSync(mkdtempSync(join(tmpdir(), "openvsmobile-smoke3-")));
  const opened3 = await c.call("workspace.open", {
    root: scratch3,
    activate: false,
  });
  assert(opened3.workspace?.id, "third workspace has id");
  const afterCur = await c.call("workspace.current", {});
  assert(afterCur.workspace?.id === beforeId,
    `current unchanged with activate:false; before=${beforeId} after=${afterCur.workspace?.id}`);
  // Cleanup — close the inactive one so the rest of the script's invariants hold.
  await c.call("workspace.close", { id: opened3.workspace.id });
  await c.waitNotif((n) =>
    n.method === "workspace.closed" && n.params.id === opened3.workspace.id);
  console.log("[ok] workspace.open { activate: false } leaves current unchanged");

  // 11. Terminal: create, write, wait for echo, dispose
  const term = await c.call("terminal.create", {
    workspaceId: opened.workspace.id,
    cols: 80,
    rows: 24,
  });
  assert(term.sessionId, "terminal has sessionId");
  assert(term.workspaceId === opened.workspace.id, "terminal carries workspaceId");
  console.log("[ok] terminal.create -> %s", term.sessionId);

  // Wait for any data so we know the PTY actually started (shell prompt, etc).
  await c.waitNotif(
    (n) => n.method === "terminal.data" && n.params.sessionId === term.sessionId,
  );
  console.log("[ok] terminal.data notification received");

  await c.call("terminal.write", {
    sessionId: term.sessionId,
    dataBase64: Buffer.from("echo hello-smoke && exit\n").toString("base64"),
  });

  // Wait for exit
  const exit = await c.waitNotif(
    (n) => n.method === "terminal.exit" && n.params.sessionId === term.sessionId,
    5000,
  );
  assert(typeof exit.params.exitCode === "number", "exit carries exitCode");
  assert(exit.params.workspaceId === opened.workspace.id || exit.params.workspaceId === null, "exit workspaceId routed");
  console.log("[ok] terminal.exit (code=%d)", exit.params.exitCode);

  // 12. terminal.list
  const empty2 = await c.call("terminal.list", { workspaceId: opened.workspace.id });
  assert(empty2.sessions.length === 0, "terminal list empty after exit");
  console.log("[ok] terminal.list");

  // 13. workspace.close (the inactive one)
  await c.call("workspace.close", { id: opened2.workspace.id });
  const closedNotif = await c.waitNotif(
    (n) => n.method === "workspace.closed" && n.params.id === opened2.workspace.id,
  );
  assert(closedNotif, "workspace.closed notification");
  console.log("[ok] workspace.close + notification");

  // 14. Close the current workspace — current should become null.
  await c.call("workspace.close", { id: opened.workspace.id });
  const finalCur = await c.call("workspace.current", {});
  assert(finalCur.workspace === null, "current is null after closing last workspace");
  console.log("[ok] workspace.close (last) clears current");

  c.close();
  console.log("\nALL PASS");
}

main().catch((err) => {
  console.error("FAIL:", err);
  process.exit(1);
});
