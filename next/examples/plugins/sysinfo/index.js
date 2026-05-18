// System Info — read-only snapshot of the host the backend runs on.
//
// All values come from `node:os` / `process` and the panel re-renders
// every 5 seconds with fixed node ids so the reconciler keeps things
// in place. Mono-styled text keeps the numeric columns visually
// aligned without needing a Table widget (which the §4.3 vocabulary
// doesn't currently expose — see report).
//
// Batch 3 (§4.3) widget dogfood: we now render
//   * `ui.spinner` during the very first activation tick (before the
//     `loadavg()` sample has stabilized) — the "warming up" caption
//     gives the user something to see for the second the indicator
//     lives on screen.
//   * `ui.progress` (linear, with `value`) for memory and CPU 1-minute
//     load utilization, instead of raw numbers buried in a mono row.
//     Numeric companion text keeps the precise reading visible.

import { cpus, freemem, hostname, loadavg, totalmem, uptime } from "node:os";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "info";
const REFRESH_MS = 5000;
// Used as the "first paint is still warming up" guard so the spinner
// appears for one render-tick before real samples land.
let firstSampleReady = false;

function formatUptime(seconds) {
  const s = Math.floor(seconds);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${d}d ${h}h ${m}m`;
}

function bytesToGb(bytes) {
  return (bytes / (1024 * 1024 * 1024)).toFixed(1);
}

function render(ctx) {
  if (!firstSampleReady) {
    // Activation tick — show only the spinner until the second render
    // pumps real samples in. The user perceives "loading" instead of
    // "blank".
    ctx.renderPanel(
      PANEL_ID,
      ui.section({
        id: "sysinfo-section",
        title: "System",
        children: [
          ui.spinner({
            id: "sysinfo-spinner",
            label: "Sampling host metrics…",
            size: "md",
          }),
        ],
      }),
    );
    return;
  }
  const free = freemem();
  const total = totalmem();
  const used = total - free;
  const memFraction = total > 0 ? used / total : 0;
  // 1-minute load average normalized by cpu count — gives a 0..1
  // utilization-style figure for the progress bar. Clamp so a spike
  // over 1.0 doesn't tip the bar past 100%.
  const cpuCount = Math.max(1, cpus().length);
  const loadRaw = loadavg()[0];
  const cpuFraction = Math.min(1, Math.max(0, loadRaw / cpuCount));
  ctx.renderPanel(
    PANEL_ID,
    ui.section({
      id: "sysinfo-section",
      title: "System",
      children: [
        ui.column({
          id: "sysinfo-col",
          gap: "md",
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
            // Memory bar — colored by tier so a near-full system reads
            // as warning at a glance, even before the user looks at
            // the absolute numbers in the caption underneath.
            ui.progress({
              id: "sysinfo-mem-bar",
              value: memFraction,
              variant: "linear",
              accent:
                memFraction > 0.9
                  ? "danger"
                  : memFraction > 0.7
                    ? "warning"
                    : "success",
              label: `mem  ${bytesToGb(used)} / ${bytesToGb(total)} GB  (${(memFraction * 100).toFixed(0)}%)`,
            }),
            // CPU 1-min load normalized by cpu count. Same accent tiers.
            ui.progress({
              id: "sysinfo-cpu-bar",
              value: cpuFraction,
              variant: "linear",
              accent:
                cpuFraction > 0.9
                  ? "danger"
                  : cpuFraction > 0.7
                    ? "warning"
                    : "success",
              label: `cpu  load ${loadRaw.toFixed(2)} / ${cpuCount} cores  (${(cpuFraction * 100).toFixed(0)}%)`,
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
    // First paint: spinner only.
    render(ctx);
    // Flip the flag and render again on the next tick of the event
    // loop so the spinner is observable for one frame even on a fast
    // host where the activation handler runs in a few microseconds.
    setImmediate(() => {
      firstSampleReady = true;
      render(ctx);
    });
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
