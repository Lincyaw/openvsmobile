// Fixture used by ui.test.ts to exercise the host's wire-level
// validation. Emits one ui.render whose tree contains duplicate node
// ids, then mirrors the host's error response to stderr so the test
// can assert -32602 came back.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 42,
    method: "ui.render",
    params: {
      panelId: "home",
      tree: {
        kind: "Column",
        id: "dup",
        children: [{ kind: "Text", id: "dup", text: "twin id" }],
      },
    },
  }) + "\n",
);

const buf = [];
process.stdin.on("data", (chunk) => {
  buf.push(chunk);
  let merged = Buffer.concat(buf).toString("utf8");
  let nl;
  while ((nl = merged.indexOf("\n")) !== -1) {
    const line = merged.slice(0, nl);
    merged = merged.slice(nl + 1);
    if (line.trim().length === 0) continue;
    process.stderr.write(`<<RESP>>${line}<<END>>\n`);
  }
  buf.length = 0;
  if (merged.length > 0) buf.push(Buffer.from(merged, "utf8"));
});

setTimeout(() => {}, 60_000);
