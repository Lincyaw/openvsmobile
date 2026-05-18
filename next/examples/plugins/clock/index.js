// Clock — second-resolution wall clock.
//
// Exercises the §4.3 reconciliation rule: every node id is fixed across
// renders, so when the SDK pushes a new `ui.render` every second the
// Flutter side reuses the existing widgets in place rather than tearing
// them down. If the ids were per-render UUIDs the clock would still be
// correct on screen but any scroll position, animation, or focus
// elsewhere in the panel tree would get reset once per second — which
// is exactly the failure mode the design doc calls out.

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "time";

function pad2(n) {
  return n < 10 ? `0${n}` : String(n);
}

function formatTime(d) {
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function formatDate(d) {
  // YYYY-MM-DD, weekday name — locale-stable enough for an example.
  const iso = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()];
  return `${iso} ${weekday}`;
}

function render(ctx) {
  const now = new Date();
  ctx.renderPanel(
    PANEL_ID,
    ui.section({
      id: "clock-section",
      title: "Clock",
      children: [
        ui.text({ id: "clock-time", text: formatTime(now), style: "title" }),
        ui.text({ id: "clock-date", text: formatDate(now), style: "caption" }),
      ],
    }),
  );
}

let timer = null;

const plugin = createPlugin({
  onActivate(ctx) {
    render(ctx);
    timer = setInterval(() => render(ctx), 1000);
    // Don't keep the event loop alive just for the tick — when the host
    // closes stdin we want to exit promptly. The stdin `data` listener
    // (inside the SDK) is what keeps the process alive in normal use.
    if (typeof timer.unref === "function") timer.unref();
  },
});

plugin.run();

// Best-effort cleanup if the process is signalled.
function shutdown() {
  if (timer !== null) {
    clearInterval(timer);
    timer = null;
  }
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("beforeExit", shutdown);
