Fixes Linux startup after an upgrade or a fresh installation, and removes a
test-only setting.

- Linux: Axiotask now starts when `~/.config/axiotask/config.toml` does not
  exist. The Google connection stays unavailable until the file is created
  from `config/axiotask.example.toml` with a desktop OAuth client (see the
  README); nothing is migrated from the v1.5.3 `config.json`. A file that
  exists but is invalid still stops startup with a precise message.
- The Read-only sync setting is removed. It existed for testing only; changes
  made on the device are always sent to Google Tasks while sync is running.
  Stop sync remains the way to hold synchronization.

Android signing: this release uses the historical OAuth-registered certificate
(SHA-1 `92:0A:4B:DD:8D:D9:C4:83:08:F5:6F:5A:6B:AB:8B:5E:36:A3:AC:72`).
The APK is an optimized, non-debuggable release build. The v1.5.3–v1.5.5 GitHub
APKs used a different certificate, so Android requires uninstalling those copies
before installing this release. Export unsynced local work first: uninstalling
clears local app data. Google Tasks cloud data is unaffected. Copies already
signed with the registered certificate can update normally.

Includes RPM, DEB, Flatpak, and Android APK packages, the Android certificate
report, and SHA256SUMS. Built with Flutter 3.50.0. Linux continues to use the
configured desktop OAuth client and an unlocked Secret Service.
