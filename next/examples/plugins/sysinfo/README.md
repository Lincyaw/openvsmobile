# sysinfo — host snapshot

Single panel (`info`) showing hostname, uptime, load average, memory
usage, and the Node version. Refreshes every 5 seconds. All values
come from `node:os` / `process` — no extra processes spawned, no
filesystem reads.

## Install

```
cp -R . ~/.local/share/openvsmobile-next/plugins/sysinfo/
```

Then restart the backend; the plugin activates on startup.
