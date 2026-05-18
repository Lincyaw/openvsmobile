// Quick Notes — a one-file scratchpad persisted under the user's home.
//
// Exercises the user-input → fs round-trip: onActivate hydrates the
// TextField from disk, `changed` events update in-memory state without
// touching disk, and a Save button flushes the buffer. Errors are
// caught and reflected in a banner / status caption so a broken fs path
// can't crash the process — a crashed plugin freezes its last UI by
// design (see CLAUDE.md "One process per plugin; no automatic restart
// on crash"), and we'd rather surface the message than disappear.
//
// Batch 2 (§4.3) widget dogfood: this panel now demonstrates the four
// new vocabulary additions in their natural setting:
//   * `ui.section { variant: 'inset' }` for the iOS-Settings-style
//     editor group + the metadata group below it.
//   * `ui.toggle` for a "private" flag (in-memory only — the file is
//     still saved either way; the flag is a placeholder for the future
//     fs.encrypt capability and is what makes the panel demonstrative).
//   * `ui.banner` (accent: 'warning') for the unsaved-changes notice
//     and `ui.banner` (accent: 'danger') for fs errors. Both carry an
//     `action` that wires back into the existing Save flow.
//   * `ui.divider` between the editor section and the metadata section
//     when the panel is in its "dirty" state — pure-decoration, but
//     shows the widget rendering outside an inset context.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir, userInfo } from "node:os";
import { dirname, join } from "node:path";

import { createPlugin, ui } from "@openvsmobile/sdk";

const PANEL_ID = "home";
const NOTES_DIR = join(homedir(), ".openvsmobile");
const NOTES_PATH = join(NOTES_DIR, "notes.md");

// Resolved once at module load. The username drives the initial-
// fallback avatar so the metadata row has a stable visual identity
// without requiring any user input. Falls back to "?" if the host
// can't read userInfo() (e.g. in some container environments).
function ownerInitial() {
  try {
    const u = userInfo().username;
    if (typeof u === "string" && u.length > 0) return u.slice(0, 1);
  } catch {
    // Some sandboxed environments (e.g. Android) throw from userInfo().
    // Fall through to the default.
  }
  return "?";
}

// In-memory state. The buffer is what the user is currently editing;
// `lastSavedSnapshot` is the buffer at the time of the last successful
// save — comparing against `buffer` tells us whether the panel is dirty
// without a separate flag. `lastSavedIso` is the canonical "Last saved"
// timestamp; `statusMessage` overrides the metadata caption when set
// and is used to surface fs errors without losing the rest of the panel.
const state = {
  buffer: "",
  lastSavedSnapshot: "",
  lastSavedIso: null,
  statusMessage: null,
  private: false,
};

function isDirty() {
  return state.buffer !== state.lastSavedSnapshot;
}

function metadataCaption() {
  if (state.statusMessage !== null) return state.statusMessage;
  if (state.lastSavedIso !== null) return `Last saved: ${state.lastSavedIso}`;
  return `Saved to ${NOTES_PATH}`;
}

function buildTree() {
  const children = [];

  // Dirty-state warning banner with a primary action wired to Save.
  // Authored as a Batch-2 inline banner so the renderer paints the
  // standard warning chrome (icon + colored wash + action button).
  if (isDirty()) {
    children.push(
      ui.banner({
        id: "notes-dirty-banner",
        title: "Unsaved changes",
        body: "Your buffer has edits that aren't on disk yet.",
        accent: "warning",
        action: { label: "Save now", eventId: "save" },
      }),
    );
  }

  // fs error gets a louder banner. Dismiss eventId clears the message
  // locally so the panel doesn't get stuck if the user understands the
  // error and moves on.
  if (state.statusMessage !== null) {
    children.push(
      ui.banner({
        id: "notes-error-banner",
        title: "Could not access notes file",
        body: state.statusMessage,
        accent: "danger",
        dismissEventId: "clear-error",
      }),
    );
  }

  // Editor block as an inset section so the textfield + save button +
  // private toggle read as a single grouped surface — the same visual
  // pattern as iOS Settings detail pages.
  children.push(
    ui.section({
      id: "notes-editor-section",
      title: "Editor",
      variant: "inset",
      children: [
        ui.textField({
          id: "note-input",
          label: "Notes",
          value: state.buffer,
          placeholder: "Jot something down…",
        }),
        ui.toggle({
          id: "private-toggle",
          label: "Private",
          value: state.private,
          onChangeEvent: "toggle-private",
        }),
        ui.button({ id: "save-btn", label: "Save", style: "primary" }),
      ],
    }),
  );

  // Explicit divider between the editor and the metadata block — the
  // dividers inside `inset` are internal-only, so we use the standalone
  // `ui.divider` here to show the spec-defined separator outside that
  // context.
  children.push(ui.divider({ id: "notes-section-divider" }));

  // Metadata as a second inset section. Caption type for the status
  // line — `text` with `style: 'caption'` carries the muted /
  // secondary-text role that pairs naturally with the inset surface.
  // Batch 3 dogfood: an avatar derived from the host user's initial
  // sits as the leading element of a ListTile so the metadata row
  // looks like an iOS Settings "signed in as" header. The avatar's
  // color is hashed from the initial, so the same machine always
  // shows the same hue.
  children.push(
    ui.section({
      id: "notes-meta-section",
      title: "Status",
      variant: "inset",
      children: [
        ui.listTile({
          id: "notes-owner-tile",
          title: "Local notes",
          subtitle: metadataCaption(),
          leading: ui.avatar({
            id: "notes-owner-avatar",
            initial: ownerInitial(),
            size: "md",
          }),
        }),
      ],
    }),
  );

  return ui.column({
    id: "notes-root",
    children,
  });
}

function render(ctx) {
  ctx.renderPanel(PANEL_ID, buildTree());
}

async function hydrate(ctx) {
  try {
    state.buffer = await readFile(NOTES_PATH, "utf8");
    state.lastSavedSnapshot = state.buffer;
  } catch (err) {
    // ENOENT is the expected first-run case — leave buffer empty and
    // don't surface anything to the user. Anything else gets logged
    // and shown in the danger banner.
    if (err && err.code === "ENOENT") return;
    state.statusMessage = `Could not read notes: ${err.message ?? String(err)}`;
    ctx.log("warn", state.statusMessage);
  }
}

async function save(ctx) {
  try {
    await mkdir(dirname(NOTES_PATH), { recursive: true });
    await writeFile(NOTES_PATH, state.buffer, "utf8");
    state.lastSavedSnapshot = state.buffer;
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
      const prevDirty = isDirty();
      state.buffer = typeof value === "string" ? value : "";
      // Re-render only when the dirty state crossed a boundary — the
      // banner needs to appear/disappear, but otherwise keystrokes
      // shouldn't fight the user's cursor with re-renders.
      if (prevDirty !== isDirty()) {
        render(ctx);
      }
      return;
    }
    if (event.nodeId === "private-toggle" && event.type === "toggle-private") {
      const value = event.payload && event.payload.value;
      state.private = value === true;
      render(ctx);
      return;
    }
    if (event.nodeId === "notes-error-banner" && event.type === "clear-error") {
      state.statusMessage = null;
      render(ctx);
      return;
    }
    // The dirty banner's action and the Save button share the same
    // event name ("save"); accept either source.
    if (event.type === "save") {
      await save(ctx);
      render(ctx);
      return;
    }
    if (event.nodeId === "save-btn" && event.type === "tap") {
      await save(ctx);
      render(ctx);
    }
  },
});

plugin.run();
