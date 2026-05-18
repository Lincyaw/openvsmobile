// System Info — read-only snapshot of the host the backend runs on.
//
// All values come from `node:os` / `process` and the panel re-renders
// every 5 seconds with fixed node ids so the reconciler keeps things
// in place. Mono-styled text keeps the numeric columns visually
// aligned without needing a Table widget (which the §4.3 vocabulary
// doesn't currently expose — see report).

import { freemem, hostname, loadavg, totalmem, uptime } from "node:os";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "info";
const REFRESH_MS = 5000;

function formatUptime(seconds) {
  const s = Math.floor(seconds);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${d}d ${h}h ${m}m`;
}

function formatLoad(avg) {
  return avg.map((n) => n.toFixed(2)).join("  ");
}

function bytesToGb(bytes) {
  return (bytes / (1024 * 1024 * 1024)).toFixed(1);
}

function render(ctx) {
  const free = freemem();
  const total = totalmem();
  ctx.renderPanel(
    PANEL_ID,
    ui.section({
      id: "sysinfo-section",
      title: "System",
      children: [
        ui.column({
          id: "sysinfo-col",
          gap: 8,
          children: [
            ui.text({
              id: "sysinfo-host",
              text: `host    ${hostname()}`,
              style: "mono",
            }),
            ui.text({
              id: "sysinfo-uptime",
              text: `uptime  ${formatUptime(uptime())}`,
              style: "mono",
            }),
            ui.text({
              id: "sysinfo-load",
              text: `load    ${formatLoad(loadavg())}`,
              style: "mono",
            }),
            ui.text({
              id: "sysinfo-mem",
              text: `mem     ${bytesToGb(total - free)} / ${bytesToGb(total)} GB`,
              style: "mono",
            }),
            ui.text({
              id: "sysinfo-node",
              text: `node ${process.version}`,
              style: "caption",
            }),
          ],
        }),
      ],
    }),
  );
}

let timer = null;

const plugin = createPlugin({
  onActivate(ctx) {
    render(ctx);
    timer = setInterval(() => render(ctx), REFRESH_MS);
    if (typeof timer.unref === "function") timer.unref();
  },
});

plugin.run();

function shutdown() {
  if (timer !== null) {
    clearInterval(timer);
    timer = null;
  }
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("beforeExit", shutdown);
