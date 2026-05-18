// Exercise the Phase-0 workspace surface: emit a workspace.current
// request right after spawn, and dump every inbound JSON-RPC frame
// (including the host's response and any workspace.activated
// notifications) to stderr inside <<RX>>…<<END>> markers so the test
// can scrape them with a single regex.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "workspace.current",
    params: {},
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
