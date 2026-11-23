/// The released application version shown on the About screen.
///
/// Kept equal to the `version:` name in `pubspec.yaml` by
/// `test/app/app_version_test.dart`, so a version bump that forgets this
/// constant fails the gate instead of shipping a wrong About screen.
const String appVersion = '1.5.12';

/// The project's sponsorship page.
final Uri supportProjectUri = Uri.parse(
  'https://github.com/sponsors/IllyaYalovyy',
);

/// The project's source repository.
final Uri sourceCodeUri = Uri.parse('https://github.com/IllyaYalovyy/axiotask');
