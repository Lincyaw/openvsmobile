// System Info — read-only snapshot of the host the backend runs on.
//
// All values come from `node:os` / `process` and the panel re-renders
// every 5 seconds with fixed node ids so the reconciler keeps things
// in place.
//
// Batch 3 (§4.3) widget dogfood: we now render
//   * `ui.spinner` during the very first activation tick (before the
//     `loadavg()` sample has stabilized) — the "warming up" caption
//     gives the user something to see for the second the indicator
//     lives on screen.
//   * `ui.progress` (linear, with `value`) for memory and CPU 1-minute
//     load utilization, instead of raw numbers buried in a mono row.
//     Numeric companion text keeps the precise reading visible.
//
// Batch 4 (§4.3) widget dogfood: the panel now sports a
// "Refresh interval…" button that opens an imperative ActionSheet
// (15s / 30s / 1m / 5m). Picking an option tweaks the local
// `refreshMs` timer in-process; no persistence because the panel
// rebinds the interval on the next activation cycle anyway. The
// pattern proves out the picker-style imperative modal in a real
// plugin without polluting the main panel chrome.
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

// Mutable: the Batch-4 action sheet rewrites this when the user picks
// a different cadence.
let refreshMs = 5000;

const TABS = [
  { id: "cpu", label: "CPU" },
  { id: "memory", label: "Memory" },
  { id: "disk", label: "Disk" },
  { id: "network", label: "Network" },
];

// Used as the "first paint is still warming up" guard so the spinner
// appears for one render-tick before real samples land.
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
            // Batch 4 trigger: tap to open the refresh-interval picker.
            ui.button({
              id: "sysinfo-interval-btn",
              label: `Refresh interval… (current: ${formatInterval(refreshMs)})`,
              style: "secondary",
            }),
          ],
        }),
      ],
    }),
  );
}

function formatInterval(ms) {
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  return `${Math.round(ms / 60_000)}m`;
}

const INTERVAL_OPTIONS = [
  { label: "15s", ms: 15_000 },
  { label: "30s", ms: 30_000 },
  { label: "1 minute", ms: 60_000 },
  { label: "5 minutes", ms: 300_000 },
];

async function openIntervalSheet(ctx) {
  await ctx.showActionSheet(PANEL_ID, {
    id: "sysinfo-interval-picker",
    title: "Refresh interval",
    actions: INTERVAL_OPTIONS.map((o) => ({
      label: o.label,
      icon: "clock",
      eventId: `set-interval:${o.ms}`,
    })),
    dismissEventId: "interval-cancel",
  });
}

function applyIntervalChange(ctx, ms) {
  refreshMs = ms;
  if (timer !== null) {
    clearInterval(timer);
    timer = null;
  }
  timer = setInterval(() => render(ctx), refreshMs);
  if (typeof timer.unref === "function") timer.unref();
  // Re-render now so the button label reflects the new cadence
  // immediately — without this the user only sees the update on the
  // next interval tick.
  render(ctx);
}

let timer = null;

const plugin = createPlugin({
  onActivate(ctx) {
    render(ctx);
    setImmediate(() => {
      firstSampleReady = true;
      render(ctx);
    });
    timer = setInterval(() => render(ctx), refreshMs);
    if (typeof timer.unref === "function") timer.unref();
  },
  async onUiEvent(ctx, event) {
    if (event.panelId !== PANEL_ID) return;
    if (event.nodeId === "sysinfo-tabs" && event.type === "tab-picked") {
      const tabId = event.payload && event.payload.tabId;
      if (typeof tabId === "string" && TABS.some((t) => t.id === tabId)) {
        activeTab = tabId;
        render(ctx);
      }
      return;
    }
    if (
      event.nodeId === "sysinfo-interval-btn" &&
      event.type === "tap"
    ) {
      await openIntervalSheet(ctx);
      return;
    }
    if (event.type.startsWith("set-interval:")) {
      const ms = Number(event.type.slice("set-interval:".length));
      if (!Number.isFinite(ms) || ms <= 0) return;
      applyIntervalChange(ctx, ms);
      return;
    }
    if (event.type === "interval-cancel") {
      // User dismissed the sheet without picking. No-op.
      return;
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
