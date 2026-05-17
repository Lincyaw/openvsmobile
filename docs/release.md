# Releases

The repo publishes two independent release streams via GitHub Actions:

- **`backend-v<semver>`** — Linux tarballs for the Node backend, built per arch on native runners. Driven by `.github/workflows/release-backend.yml`.
- **`app-v<semver>`** — Android APKs for the Flutter client (per-ABI splits + a universal APK). Driven by `.github/workflows/release-app.yml`.

Both flows detect `-rc` / `-beta` / `-alpha` suffixes in the tag and flip the GitHub Release `prerelease` flag accordingly.

## Tagging convention

The two streams version independently: a backend bug fix does not require a new app release, and vice versa. The client pins itself to a specific backend release through the constant `kBackendVersion` in [`next/app/lib/version.dart`](../next/app/lib/version.dart) — the SSH-bootstrap installer downloads the matching `openvsmobile-backend-linux-<arch>.tar.gz` from the GitHub Release named `backend-v${kBackendVersion}`.

When cutting a coupled release (e.g. a wire-protocol change that touches both halves):

1. Land the protocol change on `main`.
2. Tag `backend-v<new>` first; wait for the backend release to publish.
3. Bump `kBackendVersion` in `next/app/lib/version.dart` to the new backend version. Commit.
4. Tag `app-v<new>`; wait for the APK release to publish.

When the change only touches one half, only that half gets a new tag.

## Setting up release signing (optional)

The `release-app` workflow degrades gracefully. If the four signing secrets below are **not** configured, the workflow emits a warning and produces a **debug-signed** APK — installable, but cannot coexist with a release-signed install of the same app. For internal smoke testing this is fine; for any user-facing distribution, configure real signing.

### 1. Generate a release keystore

Use `keytool` (bundled with the JDK). The keystore is a long-lived secret — back it up offline; **losing it means you can never publish an update to the existing app installs.**

```bash
keytool -genkey -v \
  -keystore openvsmobile-release.jks \
  -keyalg RSA -keysize 4096 \
  -validity 10000 \
  -alias openvsmobile
```

Pick a strong store password and key password (they may be the same). Note the alias (`openvsmobile` above) — you'll need it in step 3.

### 2. Encode the keystore as base64

GitHub Actions secrets are text; the binary keystore needs to be base64-encoded:

```bash
base64 -w 0 openvsmobile-release.jks > openvsmobile-release.jks.b64
```

(`-w 0` disables line wrapping; the workflow uses `base64 -d` which accepts either, but unwrapped is unambiguous.)

### 3. Add four GitHub Secrets

In the repo settings, under **Settings → Secrets and variables → Actions → New repository secret**, add all four:

| Secret name | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Contents of `openvsmobile-release.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | Store password from step 1 |
| `ANDROID_KEY_ALIAS` | Alias from step 1 (`openvsmobile`) |
| `ANDROID_KEY_PASSWORD` | Key password from step 1 |

All four must be present, or the workflow falls back to debug signing.

### 4. Verify on the next tagged release

Push `app-v<next>`. The build log should print `Release signing secrets present — decoding keystore.` and the published release body **will not** contain the debug-signed warning callout.

### Local signing (for testing release builds outside CI)

Drop a `key.properties` file at `next/app/android/key.properties` (already in `.gitignore`):

```properties
storeFile=/absolute/path/to/openvsmobile-release.jks
storePassword=...
keyAlias=openvsmobile
keyPassword=...
```

Then `flutter build apk --release` will pick it up. Without `key.properties`, the same command falls back to debug signing — this fallback is what makes the Gradle config a no-op for contributors who only ever build debug locally.
