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
// Batch 2 (§4.3) widget dogfood: this panel demonstrates the four
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
//
// Batch 4 (§4.3) widget dogfood: three new pieces here:
//   * `UiListTile.swipeActions` — the "Recent notes" list (one row per
//     persisted note title) gets Archive + Delete swipe actions. Archive
//     is a no-op stub for now (logged via host.log); Delete confirms
//     through `ctx.showAlert` with a `variant: 'danger'` action before
//     actually removing the note.
//   * `ctx.showAlert` — destructive-action confirmation. The danger
//     variant on the Delete button is what makes the confirm
//     visually distinct from "Cancel".
//   * `ctx.showBottomSheet` — "Note info" affordance on the metadata
//     row that surfaces the file path + last-saved timestamp + a
//     word-count caption in a draggable sheet (a natural place for
//     "tap-for-more-detail" without bloating the main panel).

import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
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
//
// `archived` is a transient set of "archived" titles — Archive is a
// stub that just moves a row out of the recent list until next reload.
const state = {
  buffer: "",
  lastSavedSnapshot: "",
  lastSavedIso: null,
  statusMessage: null,
  private: false,
  // Batch 5 dogfood: a small snippet list with a SearchField filter on
  // top. The list is canned (curated note templates a plugin might
  // ship) so the filter has something concrete to operate on; tapping
  // a snippet appends its body to the buffer.
  snippetQuery: "",
  // Batch 4 dogfood: set of archived note titles so the Recent list
  // can hide them after a swipe-Archive action.
  archived: new Set(),
};

const SNIPPETS = [
  { id: "todo", title: "TODO", body: "- [ ] " },
  { id: "meeting", title: "Meeting notes", body: "# Meeting\nAttendees:\nDecisions:\n" },
  { id: "journal", title: "Journal entry", body: `${new Date().toISOString().slice(0, 10)} — ` },
  { id: "command", title: "Shell command", body: "```sh\n\n```" },
  { id: "quote", title: "Quote", body: "> " },
  { id: "link", title: "Link", body: "[]()" },
];

function filteredSnippets() {
  const q = state.snippetQuery.trim().toLowerCase();
  if (q.length === 0) return SNIPPETS;
  return SNIPPETS.filter(
    (s) =>
      s.title.toLowerCase().includes(q) || s.body.toLowerCase().includes(q),
  );
}

function isDirty() {
  return state.buffer !== state.lastSavedSnapshot;
}

function metadataCaption() {
  if (state.statusMessage !== null) return state.statusMessage;
  if (state.lastSavedIso !== null) return `Last saved: ${state.lastSavedIso}`;
  return `Saved to ${NOTES_PATH}`;
}

// Synthesize a per-line "recent notes" list from the saved buffer.
// Real Notes apps store one file per note; this scratch plugin only
// owns a single file, so we split on blank-line boundaries to get
// note-shaped rows for the swipe-action dogfood. Empty buffer → no
// rows (the swipe-action demo is just absent when there's nothing
// to swipe on).
function recentNoteTitles() {
  const blocks = state.lastSavedSnapshot
    .split(/\n\s*\n/)
    .map((b) => b.trim())
    .filter((b) => b.length > 0);
  const titles = [];
  for (const b of blocks) {
    const first = b.split("\n", 1)[0].trim();
    if (first.length === 0) continue;
    if (state.archived.has(first)) continue;
    titles.push(first);
    if (titles.length >= 6) break;
  }
  return titles;
}

function wordCount(s) {
  const trimmed = s.trim();
  if (trimmed.length === 0) return 0;
  return trimmed.split(/\s+/).length;
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

  // Explicit divider between the editor and the recent-notes block —
  // the dividers inside `inset` are internal-only, so we use the
  // standalone `ui.divider` here to show the spec-defined separator
  // outside that context.
  children.push(ui.divider({ id: "notes-section-divider" }));

  // Snippets list with a SearchField filter on top. Tap a snippet
  // tile to append its body to the editor. The list is plugin-side
  // state — `snippet-search`'s `changed` event re-renders with a
  // filtered set (Batch 5 dogfood for UiSearchField + UiListTile + a
  // collapsible UiSection).
  const snippets = filteredSnippets();
  children.push(
    ui.section({
      id: "notes-snippets-section",
      title: "Snippets",
      variant: "inset",
      collapsible: true,
      children: [
        ui.searchField({
          id: "snippet-search",
          value: state.snippetQuery,
          placeholder: "Filter snippets…",
          onChangeEvent: "snippet-query",
        }),
        ...snippets.map((s) =>
          ui.listTile({
            id: `snippet-${s.id}`,
            title: s.title,
            subtitle: s.body.split("\n")[0].slice(0, 40),
            onTapEvent: "snippet-tap",
          }),
        ),
        // If the filter has no matches, surface a muted caption rather
        // than just nothing — the user knows it's working.
        ...(snippets.length === 0
          ? [
              ui.text({
                id: "snippet-empty",
                text: "No snippets match.",
                style: "caption",
              }),
            ]
          : []),
      ],
    }),
  );

  // Recent-notes list. Each row is a ListTile carrying two
  // swipeActions: Archive (info) and Delete (danger). Delete fires a
  // confirm via `ctx.showAlert` before actually removing the note.
  // The list only appears when there's something to show — an empty
  // recent list would just look like a styling bug.
  const titles = recentNoteTitles();
  if (titles.length > 0) {
    children.push(
      ui.section({
        id: "notes-recent-section",
        title: "Recent",
        variant: "inset",
        children: titles.map((title) =>
          ui.listTile({
            id: `notes-recent-${title}`,
            title,
            swipeActions: [
              {
                label: "Archive",
                icon: "folder",
                eventId: `archive:${title}`,
                accent: "info",
              },
              {
                label: "Delete",
                icon: "trash-2",
                eventId: `delete:${title}`,
                accent: "danger",
              },
            ],
          }),
        ),
      }),
    );
  }

  // Metadata as a final inset section. Caption type for the status
  // line — `text` with `style: 'caption'` carries the muted /
  // secondary-text role that pairs naturally with the inset surface.
  // Batch 3 dogfood: an avatar derived from the host user's initial
  // sits as the leading element of a ListTile so the metadata row
  // looks like an iOS Settings "signed in as" header.
  // Batch 4 dogfood: tapping the row opens a "Note info" bottom sheet
  // with details (path / last saved / word count).
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
          onTapEvent: "show-info",
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

// Remove a note from the persisted buffer by stripping the block whose
// first line matches `title`. The split-rejoin mirrors `recentNoteTitles`
// so a row removed here will not re-appear on the next render.
async function deleteNote(ctx, title) {
  const blocks = state.lastSavedSnapshot
    .split(/\n\s*\n/)
    .map((b) => b.trim())
    .filter((b) => b.length > 0);
  const filtered = blocks.filter(
    (b) => b.split("\n", 1)[0].trim() !== title,
  );
  state.lastSavedSnapshot = filtered.join("\n\n");
  state.buffer = state.lastSavedSnapshot;
  await save(ctx);
}

async function showNoteInfo(ctx) {
  // The bottom sheet's child is a small composed widget tree: file
  // path (mono), last-saved timestamp, word-count caption. Building it
  // with the SDK constructors guarantees the host validator passes
  // without us hand-rolling the wire shape.
  let mtimeIso = "(not yet saved)";
  let size = 0;
  try {
    const st = await stat(NOTES_PATH);
    mtimeIso = st.mtime.toISOString();
    size = st.size;
  } catch {
    // First-run / ENOENT — the defaults above are correct.
  }
  await ctx.showBottomSheet(PANEL_ID, {
    id: "notes-info-sheet",
    title: "Note info",
    child: ui.column({
      id: "notes-info-col",
      gap: "md",
      children: [
        ui.text({
          id: "notes-info-path",
          text: `path  ${NOTES_PATH}`,
          style: "mono",
        }),
        ui.text({
          id: "notes-info-mtime",
          text: `last saved  ${mtimeIso}`,
          style: "mono",
        }),
        ui.text({
          id: "notes-info-size",
          text: `${wordCount(state.lastSavedSnapshot)} words · ${size} bytes`,
          style: "caption",
        }),
      ],
    }),
    dismissEventId: "info-dismissed",
  });
}

async function confirmDelete(ctx, title) {
  // Imperative alert with a danger-variant Delete action. The user's
  // pick comes back through `onUiEvent` as one of two eventIds:
  //   * 'cancel'        → no-op
  //   * `confirm:<title>` → the actual delete happens
  // We encode the title inside the eventId so the on-pick handler
  // doesn't need to remember which row we asked about.
  await ctx.showAlert(PANEL_ID, {
    id: `notes-confirm-delete:${title}`,
    title: "Delete this note?",
    body: `"${title}" will be permanently removed.`,
    actions: [
      { label: "Cancel", eventId: "cancel" },
      {
        label: "Delete",
        eventId: `confirm:${title}`,
        variant: "danger",
      },
    ],
    dismissible: true,
  });
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
    if (event.nodeId === "snippet-search" && event.type === "snippet-query") {
      const value = event.payload && event.payload.value;
      state.snippetQuery = typeof value === "string" ? value : "";
      render(ctx);
      return;
    }
    if (
      typeof event.nodeId === "string" &&
      event.nodeId.startsWith("snippet-") &&
      event.type === "snippet-tap"
    ) {
      const id = event.nodeId.slice("snippet-".length);
      const snippet = SNIPPETS.find((s) => s.id === id);
      if (snippet !== undefined) {
        // Append the snippet body to whatever the user is already
        // editing; preserves their work and demonstrates the snippet
        // tap fired correctly.
        state.buffer = `${state.buffer}${state.buffer.length > 0 ? "\n" : ""}${snippet.body}`;
        render(ctx);
      }
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
      return;
    }
    // Batch 4 paths -----------------------------------------------
    if (event.nodeId === "notes-owner-tile" && event.type === "show-info") {
      await showNoteInfo(ctx);
      return;
    }
    // Swipe actions on recent-notes rows. The event.type carries the
    // op + title encoded as "archive:Foo" or "delete:Foo".
    if (event.type.startsWith("archive:")) {
      const title = event.type.slice("archive:".length);
      state.archived.add(title);
      render(ctx);
      ctx.log("info", `archived "${title}" (in-memory only)`);
      return;
    }
    if (event.type.startsWith("delete:")) {
      const title = event.type.slice("delete:".length);
      await confirmDelete(ctx, title);
      return;
    }
    // Confirmation reply from the showAlert above.
    if (event.type.startsWith("confirm:")) {
      const title = event.type.slice("confirm:".length);
      await deleteNote(ctx, title);
      render(ctx);
      return;
    }
    if (event.type === "cancel") {
      // User backed out of the confirm. No state change.
      return;
    }
    if (event.type === "info-dismissed") {
      // Bottom sheet was dismissed. No state change.
      return;
    }
  },
});

plugin.run();
