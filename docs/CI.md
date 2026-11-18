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
- The complete 40-contract Android behavior regression suite on the same emulator,
  with per-case outcomes, device facts and screenshots in `android-evidence-<commit>`.
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
  debug-signed, not a Play Store release; Google authorization requires an OAuth
  registration for that debug certificate. Use the signed release APK for the
  registered production Android client.

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
APK application ID, non-debuggable status, and the exact OAuth-registered signing certificate.
The asset-set guard rejects missing packages, extra files, or incomplete checksums.

The tag must match `pubspec.yaml` and the newest AppStream release. Release notes
come from `docs/release-notes.md`. Update these together before tagging.

## Activation

GitHub Actions must be enabled. Tag builds use the existing repository secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEYSTORE_KEY_ALIAS`, and `ANDROID_KEYSTORE_KEY_PASSWORD`.
Missing signing secrets fail the build; there is no generated-key fallback.
The secrets contain the historical OAuth-registered key (SHA-256
`1935e06653e69ddaf6e616a6f2c35b53425f14a3e94cd8daaf219338757cb796`).
Its certificate subject is `Android Debug`, but the APK is built in release mode
and must be non-debuggable. Fingerprint validation prevents accidentally using
another debug key or the unregistered certificate used by v1.5.3–v1.5.5.
Only the publication job receives repository contents write permission.
Packaging tools and the GNOME 49 Flatpak runtime/SDK are installed on disposable
GitHub runners; the workflow does not install anything on the developer machine.

### Android candidate qualification before publication

For device verification before creating a release tag, dispatch **Signed Android
qualification candidate** (`android-candidate.yml`) at the source ref to test.
It uses the same registered signing secrets and identity checks as distribution
builds, and uploads `android-signed-candidate-<commit>` with the APK, certificate,
source SHA and checksums. It does not publish a release. Verify that the matching
**Tests and commit artifacts** run is green before qualifying the candidate.
Release publication still requires evidence for the exact distribution APK
digest; evidence for a different build cannot be substituted.

The Android integration job runs the complete manifest, not just the 17-case
baseline. Publication also runs `scripts/check_android_qualification.py` against
that run's acceptance evidence and the exact distribution APK. A missing or
failed acceptance job already blocks publication through `needs`; the checker
additionally rejects dirty/stale commits, missing/duplicate/failed cases,
manifest mismatches, changed production installs, and infrastructure failures.

Physical-device qualification is separate from instrumented debug testing. The
publication job downloads `android-release-qualification-<full source SHA>` from
the trusted repository Actions run identified by repository variable
`ANDROID_QUALIFICATION_RUN_ID`. Leave that variable unset until qualification is
available: publication deliberately fails closed. Qualify the exact APK from
the distribution artifact on an isolated physical target, preserve inspected
comparison screenshots, upload the qualification artifact, then rerun the
publication job. Do not rebuild or substitute the APK after qualification.

The artifact contains `smoke.json` and screenshot files. Schema version 1 requires
`source_commit`, `apk_sha256`, `application_id` (`com.axiotask.app`),
`signing_certificate_sha256` (the pinned certificate above), `debuggable: false`,
`execution_mode: "signed-release-physical"`, and `device` with `kind: "physical"`,
nonempty `serial`/`model` and integer `api`. Its `checks` object must have exactly
these boolean true entries: `install`, `launch`, `menu`,
`capture_edit_persistence`, `completion_undo`, `navigation`, and
`comparison_screenshots_reviewed`. `reviewed_by` identifies the visual reviewer.
Each entry in `screenshots` contains a `stage`, relative `path` and matching
`sha256`. Distinct images are required for `launch`, `menu`,
`capture_edit_persistence`, `completion_undo`, and `navigation`; paths outside
the artifact are rejected. The checker independently measures the
APK digest, signing certificate, package ID and debuggable flag using SDK tools.

These fields are evidence records, not instructions to mark unexecuted checks
passed. Missing physical/signing access leaves qualification outstanding.

`scripts/smoke_android_candidate.py` collects evidence from an isolated target
that has no existing `com.axiotask.app` installation. It verifies the exact APK
signer/package, installs and launches it, executes a reviewed accessibility-label
scenario, restarts for the persistence check, and captures workflow screenshots
and their hashes. It refuses to replace an installed app. Supply a JSON scenario
with four arrays: `menu`, `capture_edit_persistence`, `completion_undo`, and
`navigation`. Steps use `{"action":"tap","label":"..."}`,
`{"action":"expect","label":"..."}`, `{"action":"text","value":"Synthetic text"}`,
`{"action":"back"}`, or `{"action":"relaunch"}`. Every flow must assert an
outcome, and persistence must assert after relaunch. Use labels observed on the
candidate and a synthetic account; do not enter personal credentials in the
scenario. Missing or ambiguous labels fail the run and retain incomplete evidence.

```bash
python3 scripts/smoke_android_candidate.py --isolated-target \
  --apk /path/to/exact-candidate.apk --commit FULL_SOURCE_SHA \
  --device SERIAL --scenario /path/to/reviewed-scenario.json \
  --artifacts test-results/candidate-smoke \
  --apksigner "$ANDROID_HOME/build-tools/VERSION/apksigner" \
  --apkanalyzer "$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
```

The collector leaves `comparison_screenshots_reviewed` false and `reviewed_by`
empty. Inspect the captured images against the v1.5.3 acceptance basis before
recording those two fields. Emulator output is marked `signed-release-emulator`
and cannot satisfy the physical-device release guard. The collector's scenario
validation has automated tests; execution against a signed physical candidate
remains outstanding until that target is available.

`bash test/android_qualification_test.sh` exercises accepted synthetic evidence
and rejection of incomplete, stale, wrong-mode and mismatched evidence. No
physical candidate qualification or release publication is implied by those
synthetic tests.
