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

Pushing a `v<version>` tag publishes the tested Linux archive, explicitly labeled
Android debug APK, and combined SHA256SUMS as a GitHub Release. The tag must match
`pubspec.yaml`. Publication runs only after all three validation jobs and both artifact jobs succeed.

## Activation

Commit and push the workflow, local composite action, CI scripts, and the app
changes they test. GitHub Actions must be enabled in the repository settings,
with the referenced actions permitted by any organization policy. No repository
secrets or write-token permissions are required. The first hosted run validates
Ubuntu rendering and emulator behavior; local checks do not establish that the
hosted environment has passed.
