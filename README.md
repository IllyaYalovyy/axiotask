# Axiotask Flutter

Axiotask is a native Flutter client for Google Tasks on Fedora GNOME and
Android. The repository is currently at the architecture gate: product and
target architecture are documented, but the Flutter application has not yet
been scaffolded.

Start with:

- [Product vision](VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Functional parity](docs/FUNCTIONAL_PARITY.md)
- [Testing strategy](docs/TESTING.md)
- [UX principles](docs/UX.md)
- [Security and privacy](docs/SECURITY.md)
- [Dependency decisions](docs/DEPENDENCIES.md)
- [Architecture decisions](docs/adr/README.md)

The Rust/Tauri application on the repository's `main` branch is a behavioral
reference only. This branch is an independent Flutter implementation, not a
translation or migration. The older `flutter` branch is intentionally not an
input to this design.

## Status

Stage 3 architecture/design is accepted. Stage 4 will specify synchronization
behavior and its test matrix before substantial sync code is written.

No CI/CD or distribution workflow is planned. Development, testing, visual
review, commits, and pushes are deliberately local.
