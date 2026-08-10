// The app version string shown on the Properties About tab. Dart has no
// compile-time equivalent of the reference's `env!("CARGO_PKG_VERSION")`, so
// this constant mirrors `pubspec.yaml`'s `version:` and is bumped alongside it.
// Kept tiny and dependency-free (no package_info plugin) — it is display-only.
const String appVersion = '0.1.0';
