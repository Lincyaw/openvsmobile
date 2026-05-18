# sysinfo — host snapshot

Single panel (`info`) showing hostname, uptime, load average, memory
usage, and the Node version. Refreshes every 5 seconds. All values
come from `node:os` / `process` — no extra processes spawned, no
filesystem reads.

## Install

This plugin is seeded by `install.sh` on first install — if you're
reading the README at
`~/.local/share/openvsmobile-next/plugins/sysinfo/`, it was copied
there automatically. Delete this directory to uninstall; re-running
`install.sh` will **not** re-seed it, because the parent plugins dir is
no longer in its first-install state (sentinel `.seeded`).

To install manually from a checkout:

```
cp -R . ~/.local/share/openvsmobile-next/plugins/sysinfo/
```

Then restart the backend; the plugin activates on startup.
