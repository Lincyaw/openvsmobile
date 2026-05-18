// Hello World — reference plugin built on @openvsmobile/sdk.
//
// Renders one panel `home` with a greeting, a name input, and a Greet
// button. Each `ui.event` updates the in-memory name and re-renders;
// node ids stay stable across renders so the TextField's focus + value
// survive (design §4.3 reconciliation rule).
//
// Doubles as the platform's end-to-end integration coverage — see the
// "hello plugin end-to-end" tests in next/backend/test/hello.test.ts.
//
// Batch 3 (§4.3) widget dogfood: this panel also demonstrates three
// of the new rich-display vocabulary additions:
//   * `ui.image` — a 16x16 brand-color square decoded from an inline
//     `data:image/png;base64,…` URL. Exercises the data:-URL path
//     without requiring network access or any new dependency.
//   * `ui.markdown` — an "About this plugin" intro block. Strict
//     subset: heading + paragraph + bold/italic + inline code. Out-
//     of-subset constructs would degrade to plain text, so the body
//     stays safe.
//   * `ui.codeBlock` — a copy-pasteable snippet that mirrors what a
//     plugin author would write to recreate the panel. `language:
//     javascript` activates the highlight stack the app already
//     ships for the read-only file viewer.
//
// Batch 5 (§4.3) layout-widget dogfood: this panel additionally
// exercises four pure-layout widgets that don't have dedicated demos
// elsewhere. We bunch them up here on purpose — sysinfo / notes are
// task-shaped plugins and would feel contrived hosting these:
//   * `ui.aspect` — pins the brand logo to a 1:1 box so the icon
//     shape stays consistent regardless of the surrounding row size.
//   * `ui.stack` — overlays a "DEMO" badge in the top-right of the
//     aspect-clamped logo to prove z-axis stacking works against an
//     image child.
//   * `ui.flex` — inside the "Layout demo" section, a row splits a
//     label (flex:2) and value (flex:1) so the proportional sizing
//     contract is visible.
//   * `ui.scroll` — a horizontal carousel of accent-tagged badges
//     sized past the viewport width, scrollable inside the panel's
//     vertical scroller.

import { createPlugin, ui } from "@openvsmobile/sdk";

// 16x16 PNG of the app's brand green. Tiny enough (~100 bytes
// base64) to inline; generated offline with a fixed RGBA payload.
const BRAND_LOGO_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR42mOoedz9nxLMMGrAqAGjBgwXAwAMN+kfbUWfVAAAAABJRU5ErkJggg==";

const ABOUT_MARKDOWN = [
  "## About this plugin",
  "",
  "**Hello World** is the reference plugin for the openvsmobile platform.",
  "It demonstrates the *minimum useful surface*: one `ui.section`, one",
  "`ui.textField`, one `ui.button`, and a single `ui.event` round-trip.",
  "",
  "Use it as the template for new plugins.",
].join("\n");

const SAMPLE_SNIPPET = `import { createPlugin, ui } from "@openvsmobile/sdk";

const plugin = createPlugin({
  onActivate(ctx) {
    ctx.renderPanel("home", ui.text({ id: "hi", text: "Hello!" }));
  },
});
plugin.run();
`;

let name = "";
// Batch 5 dogfood — the "Playground" section drives a Slider, a
// Checkbox, and a RadioGroup so each Batch-5 input widget has a
// visible test. State is purely local; the values are rendered back
// into a caption so the user can see the round-trip working.
let volume = 50;
let agreed = false;
let theme = "auto";

function renderHome(ctx) {
  ctx.renderPanel(
    "home",
    ui.column({
      id: "home-col",
      gap: "md",
      children: [
        ui.section({
          id: "home-section",
          title: "Hello World",
          children: [
            ui.row({
              id: "home-greeting-row",
              gap: "md",
              children: [
                // Brand-color tile sourced from a `data:image/png;…`
                // URL — proves the inline-image path works without any
                // network access or `fs` capability.
                //
                // Wrapped in `ui.stack` to overlay a "DEMO" badge on
                // top, and the image itself is wrapped in `ui.aspect`
                // so the tile stays a strict 1:1 box regardless of the
                // row's cross-axis height.
                ui.stack({
                  id: "home-logo-stack",
                  alignment: "topEnd",
                  children: [
                    ui.aspect({
                      id: "home-logo-aspect",
                      ratio: 1,
                      child: ui.image({
                        id: "home-logo",
                        src: BRAND_LOGO_PNG,
                        fit: "cover",
                        size: "lg",
                      }),
                    }),
                    ui.badge({
                      id: "home-logo-badge",
                      text: "DEMO",
                      accent: "brand",
                      variant: "pill",
                    }),
                  ],
                }),
                ui.text({
                  id: "greeting",
                  text:
                    name.length > 0 ? `Hello, ${name}!` : "Hello, stranger.",
                  style: "title",
                }),
              ],
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
        // Markdown intro — strict subset, paired with a code snippet
        // so a plugin author exploring the example can immediately see
        // how the panel above was authored.
        ui.section({
          id: "home-about-section",
          title: "About",
          variant: "card",
          children: [
            ui.markdown({ id: "home-about", markdown: ABOUT_MARKDOWN }),
            ui.codeBlock({
              id: "home-snippet",
              code: SAMPLE_SNIPPET,
              language: "javascript",
            }),
          ],
        }),
        // Playground — Batch 5 input demo. Each control's state is
        // mirrored back to a caption so the round-trip is visible
        // without needing to dig into logs.
        ui.section({
          id: "home-playground-section",
          title: "Playground",
          variant: "inset",
          children: [
            ui.text({
              id: "home-playground-summary",
              text: `volume=${volume}  agreed=${agreed}  theme=${theme}`,
              style: "mono",
            }),
            ui.slider({
              id: "home-volume",
              min: 0,
              max: 100,
              step: 5,
              value: volume,
              onChangeEvent: "volume-changed",
            }),
            ui.checkbox({
              id: "home-agree",
              label: "I agree to be greeted",
              value: agreed,
              onChangeEvent: "agree-changed",
            }),
            ui.radioGroup({
              id: "home-theme",
              value: theme,
              onChangeEvent: "theme-changed",
              options: [
                { value: "auto", label: "Auto" },
                { value: "light", label: "Light" },
                { value: "dark", label: "Dark" },
              ],
            }),
          ],
        }),
        // Layout demo — exercises `ui.flex` and `ui.scroll` in their
        // canonical use shapes. Bundled here (rather than scattered
        // through other plugins) so the dogfood stays grouped with
        // the other widget showcases.
        ui.section({
          id: "home-layout-demo",
          title: "Layout demo",
          variant: "card",
          children: [
            // Flex split: label claims 2/3 of the row, value claims 1/3.
            ui.row({
              id: "home-flex-row",
              gap: "sm",
              children: [
                ui.flex({
                  id: "home-flex-label",
                  flex: 2,
                  child: ui.text({
                    id: "home-flex-label-text",
                    text: "Active name",
                    style: "caption",
                  }),
                }),
                ui.flex({
                  id: "home-flex-value",
                  flex: 1,
                  child: ui.text({
                    id: "home-flex-value-text",
                    text: name.length > 0 ? name : "(empty)",
                    style: "mono",
                  }),
                }),
              ],
            }),
            // Horizontal carousel: a row of accent badges wider than
            // the viewport, wrapped in `ui.scroll { axis: 'horizontal' }`
            // so the panel's vertical scroller stays out of the way.
            ui.scroll({
              id: "home-accents-scroll",
              axis: "horizontal",
              child: ui.row({
                id: "home-accents-row",
                gap: "sm",
                children: [
                  "brand",
                  "info",
                  "success",
                  "warning",
                  "danger",
                  "muted",
                  "info",
                  "success",
                ].map((accent, i) =>
                  ui.badge({
                    id: `home-accent-${i}`,
                    text: accent,
                    accent,
                    variant: "pill",
                  }),
                ),
              }),
            }),
          ],
        }),
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
      return;
    }
    if (event.nodeId === "home-volume" && event.type === "volume-changed") {
      const v = event.payload && event.payload.value;
      if (typeof v === "number" && Number.isFinite(v)) {
        volume = Math.round(v);
        renderHome(ctx);
      }
      return;
    }
    if (event.nodeId === "home-agree" && event.type === "agree-changed") {
      const v = event.payload && event.payload.value;
      agreed = v === true;
      renderHome(ctx);
      return;
    }
    if (event.nodeId === "home-theme" && event.type === "theme-changed") {
      const v = event.payload && event.payload.value;
      if (typeof v === "string") {
        theme = v;
        renderHome(ctx);
      }
    }
  },
});

plugin.run();
