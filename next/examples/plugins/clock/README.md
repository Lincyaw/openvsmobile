# clock — wall clock

Single panel (`time`) showing the current time (HH:MM:SS) and date. The
plugin re-renders once per second using fixed node ids so the Flutter
reconciler keeps the surrounding panel state intact.

## Install

This plugin is seeded by `install.sh` on first install — if you're
reading the README at
`~/.local/share/openvsmobile-next/plugins/clock/`, it was copied there
automatically. Delete this directory to uninstall; re-running
`install.sh` will **not** re-seed it, because the parent plugins dir is
no longer in its first-install state (sentinel `.seeded`).

To install manually from a checkout:

```
cp -R . ~/.local/share/openvsmobile-next/plugins/clock/
```

Then restart the backend; the plugin activates on startup.
