# axiotask (Flutter)

Ground-up Flutter/Dart implementation of axiotask — a fast, sync-capable task
manager for Google Tasks. One codebase, one UI, for Linux desktop and Android.

This branch (`flutter`) is intended to eventually replace `main`. The
Tauri/Rust implementation on `main` remains the reference for behavior, UX
contracts, and the sync semantics oracle until parity is reached.

## Requirements

- Flutter SDK (stable channel) with the Linux desktop target enabled.
- Linux desktop toolchain: `clang`, `cmake`, `ninja-build`, `gtk3-devel`
  (Fedora names; equivalents elsewhere).
- Android builds additionally need the Android SDK/NDK that `flutter doctor`
  asks for.
- Headless integration tests need `xorg-x11-server-Xvfb`.

`flutter doctor` should be clean for the targets you build.

## Run (development)

```
tool/dev.sh
```

This builds and launches an **isolated dev instance** under `flutter run`
(hot reload + visible logs). It never touches your real data: the instance
prefix roots all state in `…/axiotask-flt/` directories, separate from the
production app's `…/axiotask/` (and from the Tauri dev instance's
`…/axiotask-dev/` — never share a prefix across the two implementations;
their database schemas differ). Options:

- `tool/dev.sh --bundle` — build the debug bundle and run the real standalone
  binary instead of `flutter run` (note: standalone runs do not print logs).
- `tool/dev.sh --release` — build and run the release bundle.
- `tool/dev.sh --prefix NAME` — a differently-named isolated instance.
- `tool/dev.sh --fresh` — wipe the instance's data/config first.

The same isolation works for any launch: `AXIOTASK_PREFIX=foo axiotask` uses
`axiotask-foo/` state directories. An unset prefix is the production instance.

## Google sign-in setup

Sync needs an OAuth "Desktop app" client (Google Cloud console → APIs &
Services → Credentials) with the Google Tasks API enabled. Put the credentials
in the instance's config file, e.g. for the default `flt` instance
`${XDG_CONFIG_HOME:-~/.config}/axiotask-flt/config.json`:

```json
{
  "google": {
    "client_id": "…apps.googleusercontent.com",
    "client_secret": "…",
    "scopes": ["https://www.googleapis.com/auth/tasks"]
  },
  "sync": {
    "push_enabled": false,
    "auto_sync_on_start": true
  }
}
```

The app writes a default config (empty credentials) on first launch; fill in
the `google` section and restart. `push_enabled` defaults to **false**: the
app pulls from Google but never writes back until you enable push — useful for
testing against a real account without touching it.

On Android there are no client credentials in config: the app is identified by
package name + signing-certificate SHA-1, which must be registered on the same
Google Cloud project.

## Build & install

- Linux (debug): `flutter build linux --debug`
- Linux (release): `flutter build linux --release`
  → `build/linux/x64/release/bundle/`
- User-local install (no sudo): `tool/install.sh` — builds the release bundle
  and installs it under your home: bundle → `~/.local/lib/axiotask`, launcher →
  `~/.local/bin/axiotask`, plus the desktop entry, hicolor icons and AppStream
  metainfo under `~/.local/share`. `tool/install.sh --uninstall` reverses it;
  re-running upgrades in place. It never touches your data
  (`~/.local/share/axiotask*`, `~/.config/axiotask*`) — which is why the program
  directory is `~/.local/lib`, not `~/.local/share`.
- RPM package: `tool/build_rpm.sh` (see `tool/build_rpm.sh --dry-run`), then
  install with `dnf install` of the produced rpm. This installs the launcher,
  desktop entry, icons and AppStream metainfo system-wide.
- Android (debug): `flutter build apk --debug`

The desktop entry (`linux/packaging/axiotask.desktop`) and the AppStream
metainfo (`linux/packaging/io.github.illyayalovyy.axiotask.metainfo.xml`) are
the app's OS-level metadata; both are validated by `desktop-file-validate` /
`appstreamcli validate` in the packaging tests. `StartupWMClass` must equal the
`APPLICATION_ID` in `linux/CMakeLists.txt` (the runner sets it as the program
name, so it is the window's WM_CLASS / Wayland app_id) or the running window
loses its icon.

### App icon

`assets/branding/axiotask.svg` is the only hand-authored icon. The Linux hicolor
theme set and every Android launcher bitmap (legacy, round, and the adaptive
foreground/background/monochrome layers) are rendered from it by
`tool/gen_icons.py` — needs python3 `cairosvg`. Edit the master, run the script,
and commit the master, the rasters, and `assets/branding/icons.sha256` together;
`tool/gen_icons.py --check` (also enforced by the test suite) fails if a raster
was hand-edited or left stale.

## Test

- `flutter analyze` and `dart analyze` — must be clean; every diagnostic is
  treated as a failure.
- `flutter test` — the full unit/widget suite, including the randomized sync
  invariant suite (`AXIOTASK_PROPTEST_CASES` raises its depth for soak runs).
- `xvfb-run -a flutter test integration_test/` — boots the real Linux engine
  headless: window, database, CRUD round-trip.
- See `TESTING.md` for the testing conventions (test layers, the red-check
  ritual, the time-source ban, and the golden-regeneration rule).

## Troubleshooting

- The app logs through `dart:developer`: output is visible under
  `flutter run` (i.e. plain `tool/dev.sh`) and via `flutter logs` / logcat on
  Android, but a standalone desktop binary currently prints nothing. If
  something misbehaves silently, reproduce it under `tool/dev.sh` and watch
  the console.
- Every instance takes a single-instance lock; a second launch of the same
  prefix shows a startup error screen instead of sharing the database.

## Layout

- `lib/` — application code (deep modules, simple interfaces)
- `test/`, `integration_test/` — unit/widget tests and real-engine smoke
- `tool/` — build/run scripts (`dev.sh`, `install.sh`, `build_rpm.sh`)
- `designs/` — RFCs; see `designs/RFC-000-template.md`. Architecture and the
  migration plan are specified by RFC before implementation.

See `CONTRIBUTING.md` for commit identity, versioning, and RFC rules.
