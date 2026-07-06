# Releases

Both halves of the product ship together on `v<semver>` tags (e.g. `v0.2.0`, `v0.2.0-rc1`) driven by `.github/workflows/release.yml`. A single tag push produces one GitHub Release with the backend tarballs (linux x64 + arm64), `install.sh`, and an Android arm64-v8a APK side by side.

The APK's `kBackendVersion` is substituted from the tag at build time, so a released APK always knows the matching backend version. SSH bootstrap uses this to fetch the right tarball.

The workflow detects `-rc` / `-beta` / `-alpha` suffixes in the tag and flips the GitHub Release `prerelease` flag accordingly.

## Backend install one-liner

Install or upgrade the backend by passing the desired release version once:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | OPENVSMOBILE_IROH=1 bash -s -- 0.4.6
```

The root `install.sh` is a small wrapper that fetches the canonical installer from `next/backend/pkg/install.sh` on `main`, then forwards the arguments unchanged. The installer downloads the matching backend tarball from GitHub Releases based on the version argument.

Iroh remote transport is the default release-install path. The environment
variable is set on the `bash` side of the pipe so it is persisted into the
systemd user unit:

```bash
curl -fsSL https://raw.githubusercontent.com/Lincyaw/openvsmobile/main/install.sh | OPENVSMOBILE_IROH=1 bash -s -- 0.4.6
```

Android release APKs currently target `arm64-v8a` because the bundled
`libiroh_ffi.so` is arm64-only. Do not publish x86_64 / armeabi-v7a splits
until matching Iroh FFI libraries are checked in and validated by CI.

## Setting up release signing (optional)

The workflow degrades gracefully. If the four signing secrets below are **not** configured, the workflow emits a warning and produces a **debug-signed** APK — installable, but cannot coexist with a release-signed install of the same app. For internal smoke testing this is fine; for any user-facing distribution, configure real signing.

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

Push `v<next>`. The build log should print `Release signing secrets present — decoding keystore.` and the published release body **will not** contain the debug-signed warning callout.

### Local signing (for testing release builds outside CI)

Drop a `key.properties` file at `next/app/android/key.properties` (already in `.gitignore`):

```properties
storeFile=/absolute/path/to/openvsmobile-release.jks
storePassword=...
keyAlias=openvsmobile
keyPassword=...
```

Then `flutter build apk --release` will pick it up. Without `key.properties`, the same command falls back to debug signing — this fallback is what makes the Gradle config a no-op for contributors who only ever build debug locally.
