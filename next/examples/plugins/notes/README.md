# notes — quick scratchpad

Single panel (`home`) with a `TextField` + Save button backed by
`~/.openvsmobile/notes.md`. Demonstrates the user-input → filesystem
round-trip: hydrate on activate, buffer keystrokes in memory, flush on
Save, surface fs errors in the caption.

The `fs` capability is declared as `"readwrite"` so the manifest parser
accepts it. v0 host does not yet enforce capabilities at call sites; the
declaration is documentation + future-proofing.

## Install

This plugin is seeded by `install.sh` on first install — if you're
reading the README at
`~/.local/share/openvsmobile-next/plugins/notes/`, it was copied there
automatically. Delete this directory to uninstall; re-running
`install.sh` will **not** re-seed it, because the parent plugins dir is
no longer in its first-install state (sentinel `.seeded`).

To install manually from a checkout:

```
cp -R . ~/.local/share/openvsmobile-next/plugins/notes/
```

Then restart the backend; the plugin activates on startup.
