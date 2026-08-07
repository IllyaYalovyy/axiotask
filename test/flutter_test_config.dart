import 'dart:async';

import 'support/app_fonts.dart';

/// Suite-wide test setup. `flutter test` auto-discovers this file and runs
/// [testExecutable] once, wrapping every test in the package.
///
/// Its one job today is to load the real app fonts so widget/golden tests
/// render actual glyphs (see [loadAppFonts]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await loadAppFonts();
  await testMain();
}
