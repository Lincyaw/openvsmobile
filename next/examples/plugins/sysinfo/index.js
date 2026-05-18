// System Info — read-only snapshot of the host the backend runs on.
//
// All values come from `node:os` / `process` and the panel re-renders
// every 5 seconds with fixed node ids so the reconciler keeps things
// in place.
//
// Batch 5 (§4.3) widget dogfood:
//   * `ui.tabBar` — top-of-panel segmented control with CPU / Memory /
//     Disk / Network tabs. Disk and Network are stub views for v0
//     (`node:os` doesn't expose disk space without an extra dep and
//     `networkInterfaces()` is just IP info; we render a friendly
//     "not yet implemented" caption rather than fake numbers).
//   * `ui.grid` — "at-a-glance" 2x2 grid surfaces the four headline
//     numbers (host / uptime / mem% / cpu%) in compact tiles so the
//     user sees the whole picture without scrolling.
//   * `ui.section { collapsible: true }` — the bottom "Diagnostics"
//     section is collapsed by default so a user looking at metrics
//     isn't distracted by node version + process info that only
//     matters when filing a bug.

import { cpus, freemem, hostname, loadavg, totalmem, uptime } from "node:os";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "info";
const REFRESH_MS = 5000;
const TABS = [
  { id: "cpu", label: "CPU" },
  { id: "memory", label: "Memory" },
  { id: "disk", label: "Disk" },
  { id: "network", label: "Network" },
];

let firstSampleReady = false;
let activeTab = "cpu";

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

function sample() {
  const free = freemem();
  const total = totalmem();
  const used = total - free;
  const memFraction = total > 0 ? used / total : 0;
  const cpuCount = Math.max(1, cpus().length);
  const loadRaw = loadavg()[0];
  const cpuFraction = Math.min(1, Math.max(0, loadRaw / cpuCount));
  return { used, total, memFraction, cpuCount, loadRaw, cpuFraction };
}

function accentForFraction(f) {
  if (f > 0.9) return "danger";
  if (f > 0.7) return "warning";
  return "success";
}

// 2x2 at-a-glance grid: each tile carries one headline number on its
// own monospaced surface so the grid reads as a dashboard rather than
// a wall of text.
function atGlanceGrid(s) {
  function tile(id, caption, value) {
    return ui.section({
      id: `sysinfo-tile-${id}`,
      variant: "card",
      children: [
        ui.text({
          id: `sysinfo-tile-${id}-caption`,
          text: caption,
          style: "caption",
        }),
        ui.text({
          id: `sysinfo-tile-${id}-value`,
          text: value,
          style: "mono",
        }),
      ],
    });
  }
  return ui.grid({
    id: "sysinfo-at-glance",
    columns: 2,
    gap: "sm",
    children: [
      tile("host", "HOST", hostname()),
      tile("uptime", "UPTIME", formatUptime(uptime())),
      tile("mem", "MEMORY", `${(s.memFraction * 100).toFixed(0)}%`),
      tile("cpu", "CPU", `${(s.cpuFraction * 100).toFixed(0)}%`),
    ],
  });
}

function cpuBody(s) {
  return ui.column({
    id: "sysinfo-cpu-body",
    gap: "md",
    children: [
      ui.progress({
        id: "sysinfo-cpu-bar",
        value: s.cpuFraction,
        variant: "linear",
        accent: accentForFraction(s.cpuFraction),
        label: `load ${s.loadRaw.toFixed(2)} / ${s.cpuCount} cores  (${(s.cpuFraction * 100).toFixed(0)}%)`,
      }),
      ui.text({
        id: "sysinfo-cpu-detail",
        text: `cores ${s.cpuCount}`,
        style: "caption",
      }),
    ],
  });
}

function memoryBody(s) {
  return ui.column({
    id: "sysinfo-mem-body",
    gap: "md",
    children: [
      ui.progress({
        id: "sysinfo-mem-bar",
        value: s.memFraction,
        variant: "linear",
        accent: accentForFraction(s.memFraction),
        label: `${bytesToGb(s.used)} / ${bytesToGb(s.total)} GB  (${(s.memFraction * 100).toFixed(0)}%)`,
      }),
    ],
  });
}

function stubBody(id, label) {
  return ui.text({
    id: `sysinfo-${id}-stub`,
    text: `${label} stats not exposed in v0`,
    style: "caption",
  });
}

function bodyForTab(s) {
  switch (activeTab) {
    case "memory":
      return memoryBody(s);
    case "disk":
      return stubBody("disk", "Disk");
    case "network":
      return stubBody("network", "Network");
    case "cpu":
    default:
      return cpuBody(s);
  }
}

function render(ctx) {
  if (!firstSampleReady) {
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
  const s = sample();
  ctx.renderPanel(
    PANEL_ID,
    ui.column({
      id: "sysinfo-root",
      gap: "md",
      children: [
        ui.section({
          id: "sysinfo-glance-section",
          title: "At a glance",
          children: [atGlanceGrid(s)],
        }),
        ui.tabBar({
          id: "sysinfo-tabs",
          tabs: TABS,
          activeId: activeTab,
          onChangeEvent: "tab-picked",
        }),
        ui.section({
          id: "sysinfo-tab-body",
          children: [bodyForTab(s)],
        }),
        // Diagnostics collapsed by default — useful for bug reports but
        // not for the day-to-day metrics view.
        ui.section({
          id: "sysinfo-diag",
          title: "Diagnostics",
          variant: "inset",
          collapsible: true,
          children: [
            ui.text({
              id: "sysinfo-diag-node",
              text: `node ${process.version}`,
              style: "mono",
            }),
            ui.text({
              id: "sysinfo-diag-pid",
              text: `pid ${process.pid}`,
              style: "mono",
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
    setImmediate(() => {
      firstSampleReady = true;
      render(ctx);
    });
    timer = setInterval(() => render(ctx), REFRESH_MS);
    if (typeof timer.unref === "function") timer.unref();
  },
  onUiEvent(ctx, event) {
    if (event.panelId !== PANEL_ID) return;
    if (event.nodeId === "sysinfo-tabs" && event.type === "tab-picked") {
      const tabId = event.payload && event.payload.tabId;
      if (typeof tabId === "string" && TABS.some((t) => t.id === tabId)) {
        activeTab = tabId;
        render(ctx);
      }
    }
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
