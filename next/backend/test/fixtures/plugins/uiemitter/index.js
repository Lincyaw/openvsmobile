// Fixture used by ui.test.ts.
//
// 1. Emits THREE `ui.render` requests in succession against the same
//    panelId so the test can assert monotonic versions and "latest wins".
//    Each tree mutates only a leaf Text node — the parent Section's id
//    stays stable so a reconciler verifies identity preservation.
// 2. Listens for inbound `ui.event` requests from the host and writes
//    a stderr marker line of the form  <<UIEVT>>{json}<<END>>
//    so the test (which tails the captured stderr log) can confirm the
//    round-trip. Replies with `{ ok: true }` so the host's response
//    router has something to discard.
//
// Newline-delimited JSON framing on both directions — same as the
// `hello` fixture. The host's FrameCodec auto-detects on the first byte.

const buf = [];

function emit(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function tree(label) {
  return {
    kind: "Section",
    id: "root-section",
    title: "Hello",
    children: [
      { kind: "Text", id: "root-text", text: label, style: "body" },
      { kind: "Button", id: "submit-btn", label: "Send", style: "primary" },
    ],
  };
}

let nextId = 1;
emit({
  jsonrpc: "2.0",
  id: nextId++,
  method: "ui.render",
  params: { panelId: "home", tree: tree("first") },
});
emit({
  jsonrpc: "2.0",
  id: nextId++,
  method: "ui.render",
  params: { panelId: "home", tree: tree("second") },
});
emit({
  jsonrpc: "2.0",
  id: nextId++,
  method: "ui.render",
  params: { panelId: "home", tree: tree("third") },
});

process.stdin.on("data", (chunk) => {
  buf.push(chunk);
  drain();
});

function drain() {
  let merged = Buffer.concat(buf).toString("utf8");
  let nl;
  while ((nl = merged.indexOf("\n")) !== -1) {
    const line = merged.slice(0, nl);
    merged = merged.slice(nl + 1);
    if (line.trim().length === 0) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    handle(msg);
  }
  buf.length = 0;
  if (merged.length > 0) buf.push(Buffer.from(merged, "utf8"));
}

function handle(msg) {
  if (msg.method !== "ui.event") return;
  // Surface the event payload via stderr so the test can assert the
  // round-trip without depending on a request/response handshake.
  process.stderr.write(`<<UIEVT>>${JSON.stringify(msg.params)}<<END>>\n`);
  if (msg.id !== undefined) {
    emit({ jsonrpc: "2.0", id: msg.id, result: { ok: true } });
  }
}

// Keep the event loop alive for the assertion window.
setTimeout(() => {}, 60_000);
