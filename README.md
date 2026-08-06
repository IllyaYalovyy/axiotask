# axiotask (Flutter)

Ground-up Flutter/Dart implementation of axiotask — a fast, keyboard-light,
sync-capable task manager for Google Tasks. One codebase, one UI, for Linux
desktop and Android.

This branch (`flutter`) starts from scratch and is intended to eventually
replace `main`. The Tauri/Rust implementation on `main` remains the reference
for behavior, UX contracts, and the sync semantics oracle until parity is
reached.

## Layout

- `lib/` — application code (deep modules, simple interfaces)
- `test/` — unit and widget tests
- `designs/` — RFCs; see `designs/RFC-000-template.md`. Architecture and the
  migration plan are specified by RFC before implementation.

## Development

- `flutter analyze` — must be clean (all lints are gate failures)
- `flutter test` — must be green
- Android build: `flutter build apk`
- Linux build: `flutter build linux`

See CONTRIBUTING.md for commit identity, versioning, and RFC rules.
