Fixes "Tasks unavailable" (`database.open_failed`) on a fresh Linux
installation.

- Linux: Axiotask now always keeps its data in
  `~/.local/share/io.github.IllyaYalovyy.axiotask` (under `XDG_DATA_HOME` when
  that is set). Before, a `~/.local/share/axiotask` folder left behind by
  v1.5.3 or earlier was picked up instead, and its old database could not be
  opened. That folder is now ignored and left untouched; nothing is migrated
  from it.
- A relative `XDG_DATA_HOME` is ignored, as the XDG specification requires.
- The release gate now starts the shipped Linux binary in every kind of home
  directory a new installation can meet, including one with v1.5.3 data.

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
