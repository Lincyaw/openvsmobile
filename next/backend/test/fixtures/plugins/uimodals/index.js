// Fixture for the Batch-4 imperative modal RPCs. Emits one
// `ui.showAlert` request on startup; mirrors the host's response
// onto stderr as `<<ALERTRESP>>{json}<<END>>` so the test can assert
// `{ delivered: true }` came back.
//
// Manifest has `ui: true` so the capability gate passes.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 101,
    method: "ui.showAlert",
    params: {
      panelId: "home",
      alert: {
        id: "confirm-delete",
        title: "Delete note?",
        body: "This cannot be undone.",
        actions: [
          { label: "Cancel", eventId: "cancel" },
          { label: "Delete", eventId: "delete", variant: "danger" },
        ],
        dismissible: true,
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
    process.stderr.write(`<<ALERTRESP>>${line}<<END>>\n`);
  }
  buf.length = 0;
  if (merged.length > 0) buf.push(Buffer.from(merged, "utf8"));
});

setTimeout(() => {}, 60_000);
