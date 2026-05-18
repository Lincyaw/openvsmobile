# notes — quick scratchpad

Single panel (`home`) with a `TextField` + Save button backed by
`~/.openvsmobile/notes.md`. Demonstrates the user-input → filesystem
round-trip: hydrate on activate, buffer keystrokes in memory, flush on
Save, surface fs errors in the caption.

The `fs` capability is declared as `"readwrite"` so the manifest parser
accepts it. v0 host does not yet enforce capabilities at call sites; the
declaration is documentation + future-proofing.

## Install

```
cp -R . ~/.local/share/openvsmobile-next/plugins/notes/
```

Then restart the backend; the plugin activates on startup.
