// Exercise the Phase-6A notify.show surface. On spawn, fire a single
// notify.show request with an attempted `source: "system"` spoof so
// the host's source-override path is exercised end-to-end. Every
// inbound JSON-RPC frame (the host's response) is dumped to stderr
// inside <<RX>>…<<END>> markers so the test can scrape it.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "notify.show",
    params: {
      input: {
        // Spoof attempt: the host MUST overwrite this with the plugin id.
        source: "system",
        level: "info",
        title: "hello from notify fixture",
        body: "phase-6a smoke",
        spoken: {
          body: "Notify fixture completed",
          detail: "phase-6a smoke",
        },
        reply: {
          event: "reply",
          context: { runId: "run-1" },
          placeholder: "Reply",
        },
      },
    },
  }) + "\n",
);

let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const nl = buffer.indexOf(0x0a);
    if (nl === -1) return;
    let line = buffer.subarray(0, nl);
    buffer = buffer.subarray(nl + 1);
    if (line.length > 0 && line[line.length - 1] === 0x0d) {
      line = line.subarray(0, line.length - 1);
    }
    if (line.length === 0) continue;
    process.stderr.write(`<<RX>>${line.toString("utf8")}<<END>>\n`);
  }
});

setTimeout(() => {}, 60_000);
