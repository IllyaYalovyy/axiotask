Restores Android Google sign-in, synchronization, and the original Axiotask icon.

- Connect using native Google Play Services authorization; restore the connection after reopening the app.
- Accept valid Gmail task links containing URL fragments when parsing, storing, and displaying tasks.
- Restore authorization after an exhausted retry episode, and let Refresh explicitly retry synchronization.
- Keep routine background verification compact, and show clearer failure explanations with a diagnostic reference.
- Restore the purple Axiotask launcher icon, including adaptive, round, and themed variants.

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
