# CI and commit artifacts

`.github/workflows/ci.yml` runs on every push, pull request, and manual dispatch.
Pushes to all branches and tags are included. Runs are not cancelled when newer
commits arrive. A push containing multiple commits tests its final commit; GitHub
does not emit a separate push event for each intermediate commit.

The workflow uses Ubuntu 24.04 and Flutter 3.50.0 with locked Dart dependencies.
Update `.github/actions/setup-flutter/action.yml` when upgrading Flutter, together
with the SDK constraints and reviewed golden baselines.

## Automated checks

- Formatting, generated-code consistency, fatal static analysis, and privacy scan.
- The entire `test/` Flutter suite: unit, widget, golden, fake Google contracts,
  synchronization/recovery tests, and coverage.
- The additional repeated deep-sync stress gate and every `test/*_test.sh` script.
- Desktop launcher and AppStream validation.
- Every Linux integration test except the three interactive live Google probes.
  A virtual display, disposable D-Bus session, software rendering, and a synthetic
  unlocked keyring support the native tests. Individual failures do not stop the
  remaining integration suites from running.
- All `capture_linux_*_screenshots.sh` synthetic desktop capture scripts. Captures
  are evidence for human inspection; golden comparisons run in the Flutter suite.
- SQLite and preferences native integration probes on an Android API 36 emulator.
- A Linux release build and an Android debug build, including verification that
  SQLite is packaged for all three Android ABIs.

The following tests require a dedicated Google account and interactive browser
consent and are intentionally not executed by hosted CI:

- `integration_test/linux_auth_probe_test.dart`
- `integration_test/google_tasks_contract_probe_test.dart`
- `integration_test/google_tasks_mutation_probe_test.dart`

Use the existing opt-in local probe scripts for these tests. CI does not receive
Google credentials, account tokens, signing keys, or developer configuration.
Physical Android device qualification and human visual acceptance remain local.

## Downloading builds

Open the repository's **Actions → Tests and commit artifacts → run → Artifacts**.
Build jobs run in parallel with validation and upload:

- `axiotask-linux-x64-<commit>`: a `.tar.gz` containing the complete executable
  bundle, desktop metadata, icons, and license, plus `SHA256SUMS`. Extract it and
  run `./axiotask`; preserve the adjacent `lib/` and `data/` directories.
- `axiotask-android-debug-<commit>`: a development APK plus `SHA256SUMS`. This is
  debug-signed, not a Play Store release; Android production auth is not ready.

Build artifacts expire after 30 days. Coverage, golden failure images, native
logs, and synthetic screenshots are uploaded even on test failure and expire
after 14 days. These CI artifacts can be available before validation finishes. Check the run
status before using them. Failed checks prevent GitHub Release publication.

The Linux app still requires the documented local OAuth client configuration
until public-client onboarding is completed. These artifacts are CI builds,
not Flathub publications. No release signing secret is needed.

Pushing a `v<version>` tag builds RPM, DEB, Flatpak, and a release-signed APK.
The published release contains those four packages, `ANDROID_SIGNING_CERT.txt`,
and `SHA256SUMS`; development artifacts remain in Actions only. Publication
requires every validation and artifact job to pass, including package validation,
installation of the DEB in Ubuntu 24.04, Flatpak runtime dependency checks, and
APK application ID, non-debuggable status, and signing-certificate continuity.
The asset-set guard rejects missing packages, extra files, or incomplete checksums.

The tag must match `pubspec.yaml` and the newest AppStream release. Release notes
come from `docs/release-notes.md`. Update these together before tagging.

## Activation

GitHub Actions must be enabled. Tag builds use the existing repository secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEYSTORE_KEY_ALIAS`, and `ANDROID_KEYSTORE_KEY_PASSWORD`.
Missing signing secrets fail the build; there is no debug-key fallback.
Only the publication job receives repository contents write permission.
Packaging tools and the GNOME 49 Flatpak runtime/SDK are installed on disposable
GitHub runners; the workflow does not install anything on the developer machine.
