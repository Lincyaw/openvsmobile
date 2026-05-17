// Hello World — reference plugin built on @openvsmobile/sdk.
//
// Renders one panel `home` with a greeting, a name input, and a Greet
// button. Each `ui.event` updates the in-memory name and re-renders;
// node ids stay stable across renders so the TextField's focus + value
// survive (design §4.3 reconciliation rule).
//
// Doubles as the platform's end-to-end integration coverage — see the
// "hello plugin end-to-end" tests in next/backend/test/hello.test.ts.

import { createPlugin, ui } from "@openvsmobile/sdk";

let name = "";

function renderHome(ctx) {
  ctx.renderPanel(
    "home",
    ui.section({
      id: "home-section",
      title: "Hello World",
      children: [
        ui.text({
          id: "greeting",
          text: name.length > 0 ? `Hello, ${name}!` : "Hello, stranger.",
          style: "title",
        }),
        ui.textField({
          id: "name-field",
          label: "Your name",
          value: name,
          placeholder: "Type a name",
        }),
        ui.button({ id: "greet-btn", label: "Greet", style: "primary" }),
      ],
    }),
  );
}

const plugin = createPlugin({
  onActivate(ctx) {
    renderHome(ctx);
  },
  onUiEvent(ctx, event) {
    if (event.nodeId === "name-field" && event.type === "changed") {
      const value = event.payload && event.payload.value;
      name = typeof value === "string" ? value : "";
      return;
    }
    if (event.nodeId === "greet-btn" && event.type === "tap") {
      renderHome(ctx);
    }
  },
});

plugin.run();
