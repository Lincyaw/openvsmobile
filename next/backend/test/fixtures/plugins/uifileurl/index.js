// Fixture used by ui.test.ts to exercise the Batch-3 file:// URL gate
// end-to-end. Emits one ui.render with a UiImage carrying a file:// src
// and mirrors the host's response onto stderr so the test can assert
// the -32011 capabilityNotDeclared frame came back.
//
// Manifest has `ui: true` but NOT `fs: read`, so the host must reject.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 99,
    method: "ui.render",
    params: {
      panelId: "home",
      tree: {
        kind: "Image",
        id: "fimg",
        src: "file:///etc/passwd",
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
