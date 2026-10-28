# openvsmobile

Mobile-native code workbench with a thin phone client and a per-user backend.

## Install Backend

Install or upgrade the backend on Linux or macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | bash -s -- <version>
```

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | bash -s -- 0.4.12
```

The installer downloads the matching backend tarball, installs a per-user
service (`systemd --user` on Linux, LaunchAgent on macOS), starts the backend,
and prints a pairing QR code in interactive terminals. In the Android app:

```text
Backends -> Add backend -> Scan QR
```

Iroh is bundled and enabled by default. Use `OPENVSMOBILE_IROH=0` only when
you explicitly need a WebSocket-only backend for debugging.

More details: [next/README.md](next/README.md).

## Self-hosted Iroh relay

By default the backend and the app use n0's public Iroh relays and DNS
discovery. To use only your own relay instead (no traffic to n0 at all):

1. Run `iroh-relay` 1.x on a host both sides can reach
   (`cargo install iroh-relay --version '^1' --features server`):

   ```toml
   # iroh-relay.toml — plain HTTP, any port
   enable_relay = true
   http_bind_addr = "0.0.0.0:3340"
   enable_quic_addr_discovery = false
   enable_metrics = false
   access.shared_token = ["<long random token>"]
   ```

   ```bash
   iroh-relay -c iroh-relay.toml
   ```

2. Install (or re-install) the backend with the relay settings. They are
   persisted into the service unit and kept by later upgrades, including
   upgrades run from the app's SSH bootstrap (set a variable to an empty
   value to remove it):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | \
     OPENVSMOBILE_IROH_RELAY_URLS=http://<relay-host>:3340 \
     OPENVSMOBILE_IROH_RELAY_TOKEN=<token> \
     bash -s -- 0.4.12
   ```

3. Pair the app again (scan the QR, or SSH bootstrap). The relay URL and
   token travel with the pairing data, and the app then uses only that relay.

Direct peer-to-peer paths stay on; the relay is the fallback. An `http://`
relay cannot do QUIC address discovery, so across NATs traffic mostly stays
on the relay. For NAT holepunching, run the relay with TLS and QAD; for that,
custom ports, and all options, see [docs/iroh-relay.md](docs/iroh-relay.md).

## Development

Backend:

```bash
cd next/backend
pnpm install --frozen-lockfile
pnpm dev
```

Android app:

```bash
cd next/app
flutter pub get
flutter run
```
