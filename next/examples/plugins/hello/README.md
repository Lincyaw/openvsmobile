# hello — reference plugin

Minimal node plugin demonstrating `@openvsmobile/sdk`. Renders one panel
(`home`) with a greeting, a name `TextField`, and a `Greet` `Button`.
Tap Greet → the greeting re-renders with the typed name; node ids stay
stable so the TextField keeps focus and its value across renders.

This plugin doubles as the platform's plugin-host end-to-end smoke
test (`next/backend/test/hello.test.ts`). Drop the directory into
`OPENVSMOBILE_PLUGINS_DIR` (default `~/.local/share/openvsmobile-next/plugins/`)
and the backend will activate it at startup.
