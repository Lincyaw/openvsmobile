# clock — wall clock

Single panel (`time`) showing the current time (HH:MM:SS) and date. The
plugin re-renders once per second using fixed node ids so the Flutter
reconciler keeps the surrounding panel state intact.

## Install

```
cp -R . ~/.local/share/openvsmobile-next/plugins/clock/
```

Then restart the backend; the plugin activates on startup.
