Restores the features that v1.5.4 removed and that later releases had not yet
brought back, with v1.5.3 as the baseline.

- About screen with the application version, license and source link.
- Donate / Support the project, from the application menu, Settings and About.
- Account screen: sign out (your tasks stay on the device) and switch to
  another Google account.
- Read-only sync setting: changes stay on this device until you turn it off.
- Auto-sync on startup setting.
- Sync activity: every synchronization run with its trigger, time and result.
- Full account backup and restore on Android, through the system file picker.
- "Collapse completed subtasks" is a persistent setting.
- Haptics on/off setting on touch devices.
- Export opens a sheet with a preview and separate Copy, Save and Share
  actions instead of opening the file picker directly.
- v1.5.8's layouts, ordering, capture and Undo behavior are unchanged.

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
