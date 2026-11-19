Fixes task ordering, completed subtasks, and editing during synchronization.

- Keep local task commands responsive while synchronization is running.
- Move tasks up and down from their actions menu in My order.
- Hide completed subtasks by default, with a toggle to show them in details.
- Update reordered lists immediately and preserve task and list order across restarts.
- Retain v1.5.7's native phone layouts, keyboard-aware capture, Back behavior,
  and reachable Undo controls.

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
