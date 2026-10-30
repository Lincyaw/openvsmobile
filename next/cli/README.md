# Command-line client (`ovsm`)

A second client for the existing backend, using the same authenticated JSON-RPC
stream as the Android app, over Iroh or WebSocket. This implements terminal,
workspace discovery, and pairing concerns in design §2; it adds no backend RPCs
or AI runtime.

## Run from source

Requires Node >=25 and pnpm. From `next/backend`:

```bash
pnpm install --frozen-lockfile
pnpm build
./bin/ovsm --help
# During development:
pnpm cli --help
```

Backend tarballs built from a revision containing this CLI include `bin/ovsm`,
which uses the bundled Node runtime. Older releases may predate the CLI; build
from source if your bundle does not contain it.
Invoke it by its path inside the extracted bundle. No backend needs to run on the
client machine. For source builds, `bin/ovsm` uses Node from PATH. Linux and macOS
are supported by the launcher; Windows packaging is deferred.

## Quick start

A relay forwards encrypted traffic. An OpenVSMobile backend owns workspaces and
terminal sessions. Run the backend on each machine whose terminals you want to
use; the relay alone does not provide a shell or a session list. See
[private relay setup](../../docs/iroh-relay.md) if using your own relay.

After building the CLI, run these commands from `next/backend`. Replace `dev`
with the SSH destination for the **backend machine and user running that
backend**, then choose any local machine alias, such as `work`:

```bash
# Import the backend ticket, backend token and relay settings together.
ssh dev 'cat ~/.local/state/openvsmobile-next/runtime.json' | ./bin/ovsm host import work
./bin/ovsm host list
./bin/ovsm --host work session list
./bin/ovsm --host work connect
```

If the backend has no terminal sessions yet, create one explicitly:

```bash
./bin/ovsm --host work --json session create
./bin/ovsm --host work session attach SESSION_UUID
```

Use the `sessionId` returned by `session create` as `SESSION_UUID`. To create a
session in an existing workspace, first list workspaces and pass its UUID:

```bash
./bin/ovsm --host work --json workspace list
./bin/ovsm --host work --json session create --workspace WORKSPACE_UUID
```

`Ctrl-]` detaches without ending the remote session. `Ctrl-C` is sent to the
remote process. Repeat the import under another alias to connect another
backend, then use `--host ALIAS` to select it. The same session UUID on a
different backend is a different target, so scripts should always specify the
host alias as well as the session UUID.

## Use an existing private relay

Configure the **backend machine** first using the relay's private connection
settings. For the native systemd deployment, these live in
`/etc/openvsmobile-relay/backend.env` on the relay host. For Docker deployments,
they live in the setup script's state directory. Copy that file securely to the
backend machine, then follow the
[backend service configuration steps](../../docs/iroh-relay.md#2-point-the-backend-at-it).
The backend's next `runtime.json` and pairing QR will carry the custom relay
settings, including the relay access token.

Import that updated runtime file with the quick-start command above. Do not
import `backend.env` into `ovsm`: it configures a backend process, while
`host import` expects the backend's JSON pairing data. Do not use the relay's
HTTPS URL as a WebSocket backend URL; they speak different protocols.

There are two credentials: the **relay token** authorizes access to the relay;
the **backend token** authorizes the CLI/app to access terminal and workspace
RPCs. Importing the backend pairing JSON carries both without manually mixing
them. A bare `host add NAME iroh:TICKET` uses public n0 relay defaults and is not
the setup command for a private relay.

## Live validation

The CLI has been exercised against a private public-facing relay with the test
backend and CLI in separate local network namespaces. The namespaces prevented
direct UDP connections between the peers, and every selected connection path
reported `isRelay: true` and `isIp: false`. The checks covered session creation
and listing, command input and actual shell output, interactive attachment,
forced disconnect/reconnect, and session survival after local detach. Temporary
test backends and PTYs were removed afterward.

These are CLI/backend transport checks. They do not constitute an Android
on-device UI or background-service test. Public relay access requires HTTPS/TLS
and the correct token; QAD-based direct-path discovery also needs the configured
UDP port to be reachable.

## Machines and sessions

Save named endpoints once; the token is the same bearer token used by the app.
Iroh is the preferred remote transport; WebSocket is available for local/LAN use.
Supply it through the environment or stdin so it does not appear in argv:

```bash
export OPENVSMOBILE_TOKEN  # populate from your secret manager or shell environment
./bin/ovsm host add workstation wss://work.example.com/rpc
./bin/ovsm host add lab ws://127.0.0.1:17860/rpc --token-stdin < /secure/lab-token
unset OPENVSMOBILE_TOKEN
./bin/ovsm host list
./bin/ovsm --host workstation session list
./bin/ovsm --host workstation connect
./bin/ovsm --host lab session attach SESSION_UUID
```

Running with no command chooses a machine, then a session. A single candidate is
automatically selected. The session picker shows its title, workspace label or
working directory, and UUID. Explicit IDs also accept an unambiguous prefix.
Choices always go to stderr; pipes never receive interactive prompts. No global
workspace activation is performed, so selecting a session does not change the
phone's active workspace.

`Ctrl-]` leaves the connection and keeps the remote session running. `Ctrl-C`
goes to the remote process. To switch machines, detach and run `connect` again.
Detach does not call `terminal.detach` or `terminal.dispose`: those would affect
other clients sharing the PTY. Normal remote exit ends attachment.

Output is pushed, never polled. Attach subscribes only to the selected session,
loads history, and deduplicates buffered live output using byte offsets. On a
connection loss it pauses input and makes five reconnect attempts with backoff;
a successful reconnect clears the local screen and restores a fresh history
baseline (including after a zellij byte-counter reset). Previously sent or
unacknowledged keystrokes are never retried. If retries fail, run attach again.
History is bounded by the backend scrollback cap, so old output may be unavailable.

The app and CLI share one backend PTY and therefore one size: the last client's
resize wins. For independent layouts, use separate sessions. Reconnecting to a
zellij-backed session can wake its backend PTY. Resuming after a backend restart
requires zellij persistence; plain shell sessions survive client disconnects only.

## Iroh remote access

Import the existing backend runtime JSON, installer success JSON, or the app's
pairing payload (JSON or `ovsm1.` compressed text) through stdin. This preserves
the ticket, bearer token, ALPN and relay settings, including private relay tokens:

```bash
# On a machine where the service's runtime.json is available:
./bin/ovsm host import dev < ~/.local/state/openvsmobile-next/runtime.json
# Or fetch it over an existing SSH connection:
ssh dev 'cat ~/.local/state/openvsmobile-next/runtime.json' | ./bin/ovsm host import dev
./bin/ovsm --host dev connect
./bin/ovsm --host dev --json session list
```

Import saves only the pairing fields needed by the client. Treat the input as a
credential; host listings omit tickets, bearer tokens and relay secrets. For a
public n0 relay setup, a ticket and token can also be configured directly:

```bash
# OPENVSMOBILE_TOKEN must already be populated.
./bin/ovsm host add dev "iroh:TICKET_FROM_BACKEND"
```

Direct ticket configuration defaults to ALPN `openvsmobile.rpc.v1` and n0 relays.
For custom ALPNs, private relays, staging or LAN-only mode, use import so the CLI
receives the backend's exact settings. Custom/disabled modes use the minimal
preset and do not enable n0 discovery. The CLI creates an ephemeral local Iroh
identity per connection and still performs the same bearer-token handshake.
Failed Iroh connections never silently fall back to WebSocket.

The Iroh stream uses the backend's existing newline-delimited JSON-RPC framing;
all session commands, local detach and reconnect behave the same on either
transport. QUIC provides connection liveness; WebSocket uses ping/pong control
frames. Iroh requires no SSH tunnel when its direct or relay path is reachable.

## WebSocket and SSH access

Use an existing reachable WebSocket endpoint (including a VPN), or forward a port
with SSH in a separate terminal:

```bash
ssh -N -L 17860:127.0.0.1:7860 lab
./bin/ovsm --host lab connect
```

`http(s)` URLs normalize to `ws(s)`, and a bare origin gets `/rpc`. Credentials,
queries and fragments in URLs are rejected. Automatic SSH provisioning and an embedded TUI are deferred.

Machine profiles live in `$XDG_CONFIG_HOME/openvsmobile-next/client.json`
(default `~/.config/openvsmobile-next/client.json`), separate from server config.
Updates are atomic and mode 0600. `OPENVSMOBILE_CLIENT_CONFIG` overrides that path.
`OPENVSMOBILE_URL` plus `OPENVSMOBILE_TOKEN` makes a one-off WebSocket connection without
saving a profile; it cannot be combined with `--host`. Saved hosts use their own
saved token. Listing profiles never prints tokens.

## Scripts and agent skills

Use explicit host/session IDs and `--json`. `--json` emits a result on stdout or
`{ "error": { "code", "message" } }` on stderr, with exit code 1 on failure.
RPC errors preserve their numeric code; local failures use `CLI_ERROR`. Success
is exit code 0. Interactive attach cannot be combined with `--json`.

```bash
./bin/ovsm --host lab --json workspace list
./bin/ovsm --host lab --json session list
./bin/ovsm --host lab --json session create --workspace WORKSPACE_UUID
./bin/ovsm --host lab --json session external
./bin/ovsm --host lab --json session adopt my-zellij --workspace WORKSPACE_UUID
./bin/ovsm --host lab --json session history SESSION_UUID
printf '%s' 'git status' | ./bin/ovsm --host lab --json session send SESSION_UUID --enter
```

A skill can use these commands as its tool contract: discover the configured
machine and session, inspect history, then send bytes only to the explicitly
chosen session. `send` reads stdin as bytes (up to 1 MiB); `--enter` appends CR.
Without `--enter`, bytes are sent unchanged, including newline/control bytes.
History in JSON is the backend base64 snapshot with byte-offset metadata; without
`--json`, history is raw terminal bytes (including ANSI escape sequences).

A successful `send` acknowledges delivery to the PTY, not completion of the shell
command. There is no command exit-code inference, automatic retry of writes, or
polling loop. A request timeout leaves the write outcome uncertain; inspect the
session before deciding whether to send it again. There is deliberately no
session-delete shortcut in this initial client.
