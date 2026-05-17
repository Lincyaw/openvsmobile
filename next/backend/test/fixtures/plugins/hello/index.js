// Minimal newline-delimited JSON plugin. Emits one `host.log` notification
// then sits idle on a long timer so the host sees it as `active`.
process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "host.log",
    params: { level: "info", msg: "hello" },
  }) + "\n",
);
// Keep the event loop alive long enough for the host's assertion
// window; the test kills us during shutdown.
setTimeout(() => {}, 60_000);
