# Self-hosted Iroh relay

By default the backend and the app use n0's public Iroh infrastructure:
the n0 relay map (several relays worldwide, each probed for latency) plus
n0's DNS/pkarr address discovery (`dns.iroh.link`). On an intranet that
cannot reach those hosts, every probe fails and is retried, which network
monitoring can flag as scanning.

Pointing the backend at your own relay switches both sides to *only* that
relay and turns n0 discovery off. Direct peer-to-peer paths stay enabled:
the relay carries the first packets and stays as the fallback path, and
the connection moves to a direct IP path as soon as one works.

## Download with curl

For an existing certificate, run the standalone script directly without cloning
this repository (Docker Engine, Compose, Python 3.11+ and curl must be installed):

```sh
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/next/backend/pkg/relay.py | python3 - \
  --domain relay.example.com \
  --https-port 9443 \
  --quic-port 9842 \
  --tls-cert /path/to/fullchain.pem \
  --tls-key /path/to/privkey.pem
```

The Aliyun DNS helper requires both Python files in the same directory. Download
both before using the DNS-01 instructions below:

```sh
mkdir -p ~/.local/share/openvsmobile-relay-tools
cd ~/.local/share/openvsmobile-relay-tools
curl -fsSLO https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/next/backend/pkg/relay.py
curl -fsSLO https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/next/backend/pkg/relay-aliyun.py
```

Replace `main` in these URLs with a commit SHA to pin the scripts to a specific
revision. Persistent relay state is stored separately from the downloaded code.

## One-command setup

On the relay machine, install Docker Engine with the Compose plugin, Python
3.11+, and curl. The script pulls the pinned official `n0computer/iroh-relay:v1.0.3`
image; no Rust build is needed. From this repository:

```sh
python3 next/backend/pkg/relay.py --domain relay.example.com --email ops@example.com
```

Point the domain's DNS records at the machine first and allow inbound TCP 80/443
and UDP 7842 in the host firewall and cloud security group. The script handles
TLS via Let's Encrypt (or supplied certificates on custom ports), generates a relay token, starts the container, and waits
for a verified HTTPS health check. DNS should point directly to the host for the
TLS-ALPN certificate challenge. It does not modify DNS or firewall rules.

Default state directory: `~/.local/share/openvsmobile-relay/`. Repeat the same
command (or run it without options) to reuse the token and certificate storage;
configuration changes recreate the container. Docker's `unless-stopped` restart
policy keeps the relay running when the Docker daemon restarts. Use the same
`--dir` for all commands if you override the directory. Separate directories use
separate Compose project names.

```sh
python3 next/backend/pkg/relay.py status
python3 next/backend/pkg/relay.py logs
python3 next/backend/pkg/relay.py down
python3 next/backend/pkg/relay.py                    # start again
# Generate files without pulling an image or starting a service:
python3 next/backend/pkg/relay.py --domain relay.example.com --email ops@example.com --configure-only
```

If the current user cannot access Docker, run the commands with `sudo`; the
default state directory then belongs to root. Use an explicit absolute `--dir`
when switching between sudo and non-sudo invocations. The script never installs
Docker, changes Docker group membership, or touches an existing backend service.

For trusted intranet HTTP without a domain or certificates:

```sh
python3 next/backend/pkg/relay.py --http --host 10.20.0.5 --port 3340
```

HTTP sends the relay access token in cleartext; use HTTPS on public networks.
`--host` is the address clients use; `--bind` selects the local IP on which Docker
publishes ports (default `0.0.0.0`). For a local smoke test, use `--host 127.0.0.1
--bind 127.0.0.1`. HTTP disables QAD.

All generated credential files have mode 0600, and the state directory has mode
0700. Tokens are never printed. After a successful start, configure each backend
using either generated file:

- `backend.env`: shell exports for a source-run backend or `install.sh`.
- `openvsmobile-relay.conf`: a drop-in for the existing Linux backend user service.

Copy `openvsmobile-relay.conf` securely to the **backend machine**, then, as the
user running that backend:

```sh
mkdir -p ~/.config/systemd/user/openvsmobile.service.d
install -m 600 /secure/openvsmobile-relay.conf ~/.config/systemd/user/openvsmobile.service.d/relay.conf
systemctl --user daemon-reload
systemctl --user restart openvsmobile.service
```

Alternatively, source `backend.env` before starting the backend or running the
backend installer with its required version argument. Exporting variables in a
shell does not change an already-running systemd service.

Finally re-pair the app, or import the backend's updated runtime JSON in the CLI:

```sh
ssh dev 'cat ~/.local/state/openvsmobile-next/runtime.json' | ./bin/ovsm host import dev
```

The generated relay files contain relay credentials only; they are not backend
pairing payloads. A health check proves relay HTTP/TLS readiness. If first-time
certificate issuance exceeds `--timeout` (default 120 seconds), the command
fails and leaves the container available for diagnosis with `logs`. QAD/NAT
traversal still depends on UDP reachability and the clients' networks.

## What changes on the wire

Measured on one host over 20 s, endpoint idle after start:

| Outbound traffic | n0 default | custom relay |
| --- | --- | --- |
| DNS queries | 10 | 0 |
| QUIC address-discovery probes to n0 relays (UDP 7842) | 49, to 4 relays | 0 |
| HTTPS to n0 | yes | 0 |
| Port mapping (UPnP SSDP multicast, PCP/NAT-PMP to the gateway) | yes | yes |

Port mapping cannot be turned off with the stock `@number0/iroh` /
`computer.iroh:iroh` 1.0 bindings; see [Not yet supported](#not-yet-supported).

## 1. Run the relay

The relay is `iroh-relay` from the iroh project, version 1.x:

```sh
cargo install iroh-relay --version '^1' --features server
```

### Aliyun DNS-01: no existing certificate, ports 80/443 occupied

Use the helper to issue the certificate through Aliyun DNS, then start the relay
with TCP 8443 and UDP 9842. It uses the pinned official acme.sh image and the
[`dns_ali` provider](https://github.com/acmesh-official/acme.sh/wiki/dnsapi#11-use-aliyun-domain-api-to-automatically-issue-cert).
DNS-01 creates and removes a TXT record; no listener on port 80 or 443 is needed.

Create an Aliyun RAM AccessKey with permission to read, add and delete the DNS
records needed for the zone. Store it **on the relay machine** in a mode-0600
file, for example `~/.config/openvsmobile-relay/aliyun.env`, with these two lines
(unquoted values, no `export` prefix):

```text
Ali_Key=YOUR_ACCESS_KEY_ID
Ali_Secret=YOUR_ACCESS_KEY_SECRET
```

```sh
chmod 600 ~/.config/openvsmobile-relay/aliyun.env
python3 next/backend/pkg/relay-aliyun.py \
  --domain relay.example.com \
  --email YOUR_EMAIL \
  --credentials ~/.config/openvsmobile-relay/aliyun.env \
  --https-port 8443 \
  --quic-port 9842
```

Replace `YOUR_EMAIL` with the certificate account email. The helper registers a
Let's Encrypt account, issues an EC certificate using DNS-01, exports its chain
and key, and invokes `relay.py` with those files. It does not change the domain's
A/AAAA records or existing web services. Allow TCP 8443 and UDP 9842 to the relay
host, and point the domain at it.

State is kept in `~/.local/share/openvsmobile-relay-aliyun/`; use the same `--dir`
when overriding it. Credentials, ACME account state, keys and diagnostic logs
stay private. DNS credentials are passed through a Docker env file, never argv
or terminal output. The relay configuration and backend connection files are
in the `relay/` subdirectory. API credentials are not copied into the relay
container or backend connection files.

```sh
python3 next/backend/pkg/relay-aliyun.py status
python3 next/backend/pkg/relay-aliyun.py logs
python3 next/backend/pkg/relay-aliyun.py down
python3 next/backend/pkg/relay-aliyun.py             # start again using saved settings
python3 next/backend/pkg/relay-aliyun.py renew       # renew if due; restart only on change
```

No renewal timer is installed. Run `renew` periodically using your existing
scheduler (daily is sufficient); it keeps the relay running when the certificate
has not changed. On certificate failure the old relay stays running, and the
private `acme.log` contains diagnostics. Rerunning the original setup command
also checks renewal. `--configure-only` writes the private DNS certificate plan
without calling DNS/ACME or starting containers, so it works before Docker is
available. The helper requires both Python scripts from this repository.

### HTTPS when ports 80/443 are occupied

Use a different TCP port with an existing publicly trusted full-chain certificate
and matching unencrypted PEM key covering the relay domain (a wildcard is also
valid when it covers the domain). For example:

```sh
python3 next/backend/pkg/relay.py \
  --domain relay.example.com \
  --https-port 8443 \
  --quic-port 9842 \
  --tls-cert /path/to/fullchain.pem \
  --tls-key /path/to/privkey.pem
```

This publishes only **TCP 8443** and **UDP 9842**. The container's internal HTTP
listener is not published, so the host's ports 80/443 remain available to existing
services. The generated backend configuration uses
`https://relay.example.com:8443` and QAD port `9842`; reapply that configuration
and re-pair clients after a port change. HTTPS health checks verify the domain's
certificate at the chosen port.

If no certificate exists yet, issue one with DNS-01 using your existing ACME
client; DNS-01 does not require ports 80/443 on this host. The relay's built-in
Let's Encrypt mode uses TLS-ALPN on public port 443, so the script requires
`--tls-cert` and `--tls-key` for a non-443 HTTPS port.

The script validates the certificate/key pair and copies the PEM files into its
private state directory. It remembers the original paths (including symlinks).
After renewal, rerun the script with the same `--dir` to copy the updated files
and recreate the container; configure this command as the ACME deploy hook if
you want it automated. Keep the original files accessible to that user. The
relay reads its private copies with `cert_mode = "Reloading"`. Source certificate
files are never modified.

### Plain HTTP (intranet or public)

```toml
# /etc/iroh-relay.toml
enable_relay = true
http_bind_addr = "0.0.0.0:3340"
enable_quic_addr_discovery = false
enable_metrics = false
access.shared_token = ["<long random token>"]
```

```sh
iroh-relay -c /etc/iroh-relay.toml
```

Relay traffic stays end-to-end encrypted between the backend and the
phone (QUIC with their endpoint keys); the relay only forwards packets.
Plain HTTP exposes connection metadata to the network, not content. It
does expose the relay token: anyone on the path can capture it and use
your relay (but not read your traffic).

The URL may be an IP address; no domain is needed. The relay can share a
host with other services, such as a Tailscale `derper`, as long as the
ports differ.

Without TLS the relay cannot offer QUIC address discovery (QAD), so the
endpoints only learn their own interface addresses. Direct paths still
work wherever those addresses are routable between the phone and the
backend, which is the usual intranet case. Across NATs (backend behind a
home router, phone on mobile data) traffic mostly stays on the relay,
unless the router grants a UPnP port mapping.

### With TLS and QAD

QAD lets each endpoint learn its public address so the two can holepunch
a direct path through NATs. It needs TLS on the relay:

```toml
enable_relay = true
http_bind_addr = "0.0.0.0:80"
enable_quic_addr_discovery = true      # UDP 7842
enable_metrics = false
access.shared_token = ["<long random token>"]

[tls]
cert_mode = "LetsEncrypt"   # or "Manual" with manual_cert_path / manual_key_path
hostname = "relay.example.com"
contact = "admin@example.com"
https_bind_addr = "0.0.0.0:443"
```

The certificate must chain to a public CA: the app and backend verify the
relay with the bundled web PKI roots. Self-signed and internal-CA relay
certificates are not supported yet.

### Custom ports

All three listeners can move:

```toml
http_bind_addr = "0.0.0.0:8080"

[tls]
https_bind_addr = "0.0.0.0:8443"   # relay
quic_bind_addr  = "0.0.0.0:9842"   # QAD (UDP)
```

Then put the port in the relay URL and set the QAD port on the backend:
`OPENVSMOBILE_IROH_RELAY_URLS=https://relay.example.com:8443` and
`OPENVSMOBILE_IROH_RELAY_QUIC_PORT=9842`. Both reach the app through
pairing.

The built-in `cert_mode = "LetsEncrypt"` validates over TLS-ALPN on port
443, so it only works when the relay listens on 443. On any other port,
obtain the certificate separately (for example `acme.sh` with a DNS
challenge) and point the relay at the files:

```toml
[tls]
cert_mode = "Reloading"    # re-reads the files, so renewals need no restart
manual_cert_path = "/etc/iroh-relay/cert.pem"
manual_key_path  = "/etc/iroh-relay/key.pem"
https_bind_addr = "0.0.0.0:8443"
```

`access.shared_token` restricts the relay to clients that present the
token. Leave it out only on a network where anyone may use the relay.

## 2. Point the backend at it

Set these when running `install.sh`. They are persisted into the service
unit, and a later `install.sh` run without them, such as an upgrade from
the app's SSH bootstrap, keeps the persisted values. Set a variable to an
empty value (`OPENVSMOBILE_IROH_RELAY_URLS=`) to remove it.

| Variable | Meaning |
| --- | --- |
| `OPENVSMOBILE_IROH_RELAY_URLS` | Comma-separated relay URLs, `http://` or `https://`. Setting it disables n0 relays and n0 discovery. |
| `OPENVSMOBILE_IROH_RELAY_TOKEN` | Token matching the relay's `access.shared_token`. |
| `OPENVSMOBILE_IROH_RELAY_QUIC_PORT` | QAD port on `https://` relays. Default `7842`; `off` disables QAD probes. Ignored for `http://` relays. |
| `OPENVSMOBILE_IROH_RELAY_MODE=disabled` | No relay at all: no n0 discovery, direct LAN addresses only. |

```sh
OPENVSMOBILE_IROH_RELAY_URLS=http://10.20.0.5:3340 \
OPENVSMOBILE_IROH_RELAY_TOKEN=<token> \
bash install.sh
```

A malformed URL or port makes the backend fail at start instead of
silently falling back to n0. On success, `runtime.json` shows
`iroh.relayUrl` set to your relay and an `iroh.relay` object with the
resolved settings.

## 3. Pair the app

SSH bootstrap and the pairing QR (`openvsmobile-pairing-qr`) carry
`iroh.relay`, token included, to the app. The app then builds its Iroh
endpoint with only those relays and without n0 discovery. A backend that
does not send `iroh.relay` keeps the n0 behaviour.

For a backend added by hand, the editor's **Relay URLs** field takes the
same comma-separated list. Leave it empty for n0, or enter `none` for
LAN-only. A relay token and a non-default QAD port can only arrive through
pairing.

## Not yet supported

The stock 1.0 bindings do not expose these iroh builder options. They
need a patched `iroh-ffi` with natives built for the backend tarballs and
the Android app:

- turning off port mapping (UPnP / PCP / NAT-PMP);
- limiting which local interfaces are advertised as direct addresses (a
  host with many bridge interfaces advertises all of them, and the peer
  holepunches each one);
- relay-only mode (no direct paths at all);
- trusting a self-signed or internal-CA relay certificate.
