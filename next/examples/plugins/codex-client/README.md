# Codex Client

Mobile-native client for the stable surface of the Codex app-server protocol.
It supports new and resumed threads, streamed assistant messages, turn steering
and interruption, command/file-change approvals, workspace-scoped history, and
replyable completion notifications.

The plugin talks to app-server directly. It does not parse the Codex terminal
UI and it does not add Codex-specific RPCs to the OpenVS Mobile core.

For an existing backend install, copy the bundled example into the live plugin
directory and restart the backend:

```bash
cp -R \
  "$HOME/.local/share/openvsmobile/current/openvsmobile-backend/share/example-plugins/codex-client" \
  "$HOME/.local/share/openvsmobile-next/plugins/"
systemctl --user restart openvsmobile.service
```

Fresh installs seed it automatically with the other example plugins.

## Recommended topology

Run Codex app-server on the same machine as the OpenVS Mobile backend and keep
the Codex listener on loopback:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

The plugin defaults to `ws://127.0.0.1:4500`. The phone still reaches this
machine through OpenVS Mobile's authenticated transport; the experimental
Codex WebSocket listener is not exposed to the LAN or Internet.

Codex app-server uses the Codex login/configuration on that host. No OpenAI API
key is copied to the phone or stored by this plugin.

## Configuration

Only `OPENVSMOBILE_PLUGIN_*` environment variables are passed into plugin
processes.

| Variable                                    | Default                        | Purpose                                                 |
| ------------------------------------------- | ------------------------------ | ------------------------------------------------------- |
| `OPENVSMOBILE_PLUGIN_CODEX_CONNECT`         | `ws://127.0.0.1:4500`          | app-server WebSocket URL                                |
| `OPENVSMOBILE_PLUGIN_CODEX_CREDENTIAL_FILE` | unset                          | File containing the WebSocket bearer token              |
| `OPENVSMOBILE_PLUGIN_CODEX_CWD`             | active OpenVS Mobile workspace | Override when the Codex host uses a different path      |
| `OPENVSMOBILE_PLUGIN_CODEX_MODEL`           | app-server default             | Optional model override for new threads                 |
| `OPENVSMOBILE_PLUGIN_CODEX_APPROVAL_POLICY` | `on-request`                   | `untrusted`, `on-request`, or `never`                   |
| `OPENVSMOBILE_PLUGIN_CODEX_SANDBOX`         | `workspace-write`              | `read-only`, `workspace-write`, or `danger-full-access` |

Restart the OpenVS Mobile backend after changing its plugin environment.
For a systemd user install, add the variables with `systemctl --user edit
openvsmobile.service`, then run `systemctl --user daemon-reload && systemctl
--user restart openvsmobile.service`.

The host deliberately strips raw environment variables whose names look like
secrets. Put the bearer token in a mode-0600 file and pass only its path:

```bash
install -m 600 /dev/null "$HOME/.config/openvsmobile-next/codex-app-server.token"
printf '%s' "$CODEX_REMOTE_TOKEN" > "$HOME/.config/openvsmobile-next/codex-app-server.token"
```

Do not put credentials in `CODEX_CONNECT`; the plugin rejects URL user-info and
never displays the configured credential file path.

## Connecting across machines

Plain `ws://` is accepted only for loopback, including an SSH local-forward.
For a real remote listener, use `wss://` plus Codex WebSocket authentication.
For example, app-server can verify a capability token:

```bash
codex app-server \
  --listen ws://0.0.0.0:4500 \
  --ws-auth capability-token \
  --ws-token-file "$HOME/.codex/app-server-token"
```

Terminate TLS in front of that listener and configure the plugin with the
resulting `wss://` URL and its local credential-file copy. Codex documents the
WebSocket transport as experimental and unsupported, so pinning/upgrading the
Codex CLI deliberately and running this plugin's smoke test against the target
version is recommended.

The MVP handles command and file-change approvals. Other server-initiated
forms (for example MCP elicitation and structured `requestUserInput`) are
declined as unsupported instead of leaving a Codex turn blocked indefinitely.
