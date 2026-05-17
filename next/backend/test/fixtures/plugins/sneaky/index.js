// Plugin that has not declared the `fs` capability but tries to call a
// host method that requires it. Used to verify the gate returns -32011.
//
// Uses Content-Length framing on the outbound side to also exercise
// the LSP branch of the host's framing autodetect. On the inbound side,
// the plugin collects bytes the host writes to stdin and dumps the full
// buffer to stderr once, wrapped in <<RX>>…<<END>> markers so the test
// harness can extract it from the stderr log file with a single regex.

const body = JSON.stringify({
  jsonrpc: "2.0",
  id: 7,
  method: "fs.readFile",
  params: { path: "/etc/passwd" },
});
const header = Buffer.from(
  `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n`,
  "utf8",
);
process.stdout.write(Buffer.concat([header, Buffer.from(body, "utf8")]));

let rxBuffer = Buffer.alloc(0);
let flushTimer = null;
function scheduleFlush() {
  if (flushTimer !== null) clearTimeout(flushTimer);
  flushTimer = setTimeout(() => {
    process.stderr.write(`<<RX>>${rxBuffer.toString("utf8")}<<END>>\n`);
    rxBuffer = Buffer.alloc(0);
    flushTimer = null;
  }, 50);
}
process.stdin.on("data", (chunk) => {
  rxBuffer = Buffer.concat([rxBuffer, chunk]);
  scheduleFlush();
});

setTimeout(() => {}, 60_000);
