# OpenVSMobile Flutter App

## Verification

Run Flutter tests from the repo root with:

```bash
./scripts/verify_repo.sh
```

or:

```bash
make verify
```

The verification script detects a usable Flutter executable before running
`flutter test` in `app/`.

### Flutter SDK prerequisite

Some environment-provided Flutter wrappers are not usable for tests because
their bundled `flutter_tester` binary is missing or not executable. This repo's
verification entry checks that prerequisite up front and fails with a clear
message when the selected SDK cannot run tests.

SDK selection order:

1. `OPENVSMOBILE_FLUTTER`
2. `FLUTTER_BIN`
3. Path stored in `.flutter-bin` at the repo root
4. `/home/ddq/flutter/bin/flutter`
5. `flutter` from `PATH`

Recommended in this environment:

```bash
OPENVSMOBILE_FLUTTER=/home/ddq/flutter/bin/flutter ./scripts/verify_repo.sh
```

If the script reports a missing or non-executable `flutter_tester`, point it at
a working SDK or run `flutter precache --linux` for that SDK.
