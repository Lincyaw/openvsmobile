// Plugin that echoes `command.invoke` arguments. Understands both wire
// framings (LSP Content-Length + newline-delimited JSON) because the
// host's outbound framing follows whatever it detected on this plugin's
// stdout — and stdout might not have emitted anything by the time the
// first inbound frame arrives. Emitting a tiny startup notification
// pushes the host's codec into newline mode in the common case; the
// LSP branch below covers the race.

process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    method: "host.log",
    params: { level: "info", msg: "cmd-ready" },
  }) + "\n",
);

let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  drain();
});

function drain() {
  while (true) {
    if (buffer.length === 0) return;
    if (buffer[0] === 0x43 || buffer[0] === 0x63) {
      // 'C' / 'c' — LSP framing.
      const headerEnd = buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = buffer.subarray(0, headerEnd).toString("ascii");
      const match = /Content-Length:\s*(\d+)/i.exec(header);
      if (match === null) {
        buffer = buffer.subarray(headerEnd + 4);
        continue;
      }
      const len = Number(match[1]);
      const bodyStart = headerEnd + 4;
      if (buffer.length < bodyStart + len) return;
      const body = buffer.subarray(bodyStart, bodyStart + len);
      buffer = buffer.subarray(bodyStart + len);
      handleLine(body.toString("utf8"));
      continue;
    }
    // Newline-delimited.
    const nl = buffer.indexOf(0x0a);
    if (nl === -1) return;
    const line = buffer.subarray(0, nl).toString("utf8");
    buffer = buffer.subarray(nl + 1);
    if (line.length > 0) handleLine(line);
  }
}

function handleLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.method === "command.invoke" && msg.id !== undefined) {
    const args = msg.params && msg.params.args;
    const commandId = msg.params && msg.params.id;
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id: msg.id,
      result: { echoed: args, commandId },
    });
    process.stdout.write(body + "\n");
  }
}

// Stay alive long enough for the test to exercise us.
setTimeout(() => {}, 60_000);
