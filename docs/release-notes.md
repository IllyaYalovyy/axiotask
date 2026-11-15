Restores the distribution formats provided by v1.5.3 after v1.5.4 omitted them.

Downloads:
- RPM for Fedora and compatible Linux distributions
- DEB for Ubuntu 24.04 and compatible distributions
- Flatpak for Linux x86_64, using GNOME 49
- Release-signed Android APK (arm64-v8a, armeabi-v7a, x86_64)
- Android signing certificate report and SHA256SUMS for every package

Built with Flutter 3.50.0. The APK retains application ID `com.axiotask.app` and the v1.5.3 signing certificate; CI verifies both and rejects debuggable APKs.

This release packages the current Flutter rewrite. Android Google authorization is still in development; release signing does not add that functionality. Linux requires a configured desktop OAuth client in `~/.config/axiotask/config.toml` (Flatpak: `~/.var/app/io.github.IllyaYalovyy.axiotask/config/axiotask/config.toml`), using `config/axiotask.example.toml`, and an unlocked Secret Service.
