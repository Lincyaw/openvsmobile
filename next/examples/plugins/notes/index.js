// Quick Notes — a one-file scratchpad persisted under the user's home.
//
// Exercises the user-input → fs round-trip: onActivate hydrates the
// TextField from disk, `changed` events update in-memory state without
// touching disk, and a Save button flushes the buffer. Errors are
// caught and reflected in the caption so a broken fs path can't crash
// the process — a crashed plugin freezes its last UI by design (see
// CLAUDE.md "One process per plugin; no automatic restart on crash"),
// and we'd rather surface the message than disappear.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "home";
const NOTES_DIR = join(homedir(), ".openvsmobile");
const NOTES_PATH = join(NOTES_DIR, "notes.md");

// In-memory state. The buffer is what the user is currently editing;
// `lastSavedIso` is null until the first successful save and is the
// canonical "Last saved" timestamp afterwards. `statusMessage` overrides
// the caption when set — used to surface fs errors without losing the
// rest of the panel.
const state = {
  buffer: "",
  lastSavedIso: null,
  statusMessage: null,
};

function captionText() {
  if (state.statusMessage !== null) return state.statusMessage;
  if (state.lastSavedIso !== null) return `Last saved: ${state.lastSavedIso}`;
  return `Saved to ${NOTES_PATH}`;
}

function render(ctx) {
  ctx.renderPanel(
    PANEL_ID,
    ui.section({
      id: "notes-section",
      title: "Quick Notes",
      children: [
        ui.textField({
          id: "note-input",
          label: "Notes",
          value: state.buffer,
          placeholder: "Jot something down…",
        }),
        ui.button({ id: "save-btn", label: "Save", style: "primary" }),
        ui.text({ id: "notes-caption", text: captionText(), style: "caption" }),
      ],
    }),
  );
}

async function hydrate(ctx) {
  try {
    state.buffer = await readFile(NOTES_PATH, "utf8");
  } catch (err) {
    // ENOENT is the expected first-run case — leave buffer empty and
    // don't surface anything to the user. Anything else gets logged
    // and shown in the caption.
    if (err && err.code === "ENOENT") return;
    state.statusMessage = `Could not read notes: ${err.message ?? String(err)}`;
    ctx.log("warn", state.statusMessage);
  }
}

async function save(ctx) {
  try {
    await mkdir(dirname(NOTES_PATH), { recursive: true });
    await writeFile(NOTES_PATH, state.buffer, "utf8");
    state.lastSavedIso = new Date().toISOString();
    state.statusMessage = null;
  } catch (err) {
    state.statusMessage = `Save failed: ${err.message ?? String(err)}`;
    ctx.log("warn", state.statusMessage);
  }
}

const plugin = createPlugin({
  async onActivate(ctx) {
    await hydrate(ctx);
    render(ctx);
  },
  async onUiEvent(ctx, event) {
    if (event.panelId !== PANEL_ID) return;
    if (event.nodeId === "note-input" && event.type === "changed") {
      const value = event.payload && event.payload.value;
      state.buffer = typeof value === "string" ? value : "";
      // No re-render: the TextField already reflects the user's input
      // locally. Re-rendering on every keystroke would fight the
      // user's cursor.
      return;
    }
    if (event.nodeId === "save-btn" && event.type === "tap") {
      await save(ctx);
      render(ctx);
    }
  },
});

plugin.run();
