Refines Android task screens and touch behavior.

- Use consistent app bars, cleaner task details, and contextual task actions.
- Create tasks in a keyboard-aware sheet; Save closes it after successful persistence.
- Use predictable Back behavior for menus, search, details, and reorder mode.
- Keep completion and deletion Undo near the bottom without shifting task rows.
- Keep controls reachable in landscape and with large text, including bulk selection and editing.
- Improve Android regression coverage and CI dependency resolution.

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
