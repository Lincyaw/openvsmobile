// Backend version this build of the app is paired with. The SSH bootstrap
// installer pulls the matching tarball from GitHub Releases.
//
// Local debug builds use this value as-is.
// Release builds via .github/workflows/release.yml substitute it from the v* tag.
const String kBackendVersion = '0.1.3';
