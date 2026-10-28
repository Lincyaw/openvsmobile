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
