# openvsmobile

Mobile-native code workbench with a thin phone client and a per-user backend.

## Install Backend

Install or upgrade the backend on Linux or macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | bash -s -- <version>
```

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | bash -s -- 0.4.10
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
