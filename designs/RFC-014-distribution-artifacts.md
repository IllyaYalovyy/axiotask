# RFC-014: RPM, Flatpak and Android distribution

| Field | Value |
|---|---|
| Status | Accepted |
| Author(s) | Illya Yalovyy |
| Supersedes | — |
| Superseded by | — |

## Summary

Complete the user-requested distribution pipeline with a downloadable Flatpak alongside the existing RPM, DEB and signed APK, and retain packages from continuous integration.

## Goals

- Build, verify and publish installable packages with checksums on version tags.
- Exercise Linux packaging on pushes and pull requests and retain Android CI APKs.
- Preserve the Android release signing identity and desktop OAuth configuration.

## Non-Goals

Flathub submission and Google Play publishing are separate distribution channels.

## Background & Motivation

The existing release workflow builds RPM, DEB and APK but lacks Flatpak. CI's Android job builds an APK without uploading it. Release credentials have not yet been configured in repository secrets.

## Considered Options

### Option A — Package the verified Flutter Linux bundle

Reuse the existing bundle, normalize library RUNPATHs, and verify every ELF dependency within a pinned GNOME runtime before exporting a Flatpak. This keeps the release binaries consistent and fails on incompatible host toolchains.

### Option B — Rebuild Flutter inside a Flatpak SDK

Offers tighter ABI control but requires a second Flutter build and additional SDK management. Consider if the supported runtime no longer accepts the CI bundle.

## Decision

Choose Option A. A runtime dependency check must fail rather than ship an incompatible bundle. Use the standard Flatpak build-init, build-finish, build-export and build-bundle commands.

## Design

Pin GNOME runtime/SDK 49. Package the binary and plugins under /app/lib/axiotask and export an app-id desktop entry, icons and AppStream metadata. Disable the JNI plugin’s optional JVM discovery on Linux: path_provider_android uses JNI on Android only, and a desktop bundle must not acquire a host Java dependency. Grant display, network (Google Tasks and loopback OAuth), graphics and IPC access; use sandbox-private application data and the desktop portal for external links and file dialogs. Releases retain RPM, DEB, Flatpak, signed APK and SHA256SUMS. Push/PR jobs retain Linux packages and explicitly named Android debug APKs. Signing material remains ignored locally and encrypted in GitHub secrets.

## Testing Strategy

Verify packaging contracts, missing-bundle failure, actual RPM contents, Flatpak runtime dependency resolution and installed sandbox startup. Verify the APK certificate and reject Android Debug certificates for published releases. Run the repository gate.

## Development Plan

- [x] Extend packaging tests and confirm their new assertions fail.
- [x] Add Flatpak packaging and CI artifact uploads.
- [ ] Configure credentials, build packages and verify them.
- [ ] Push changes and publish a verified GitHub release.

## Open Questions

No existing release keystore or published release was found. A new release key is retained in private local storage and configured in GitHub secrets. Its certificate fingerprint must be registered with the Google Cloud Android OAuth client.
