import 'dart:async';

import 'package:alchemist/alchemist.dart';

import 'support/app_fonts.dart';

/// Suite-wide test setup. `flutter test` auto-discovers this file and runs
/// [testExecutable] once, wrapping every test in the package.
///
/// It does two things:
///
///  1. Loads the real app fonts so widget/golden tests render actual glyphs
///     (see [loadAppFonts]).
///  2. Pins the golden configuration to ONE variant (#275). alchemist's default
///     writes and compares two baselines per scenario — `goldens/<platform>/`
///     (real glyphs, real shadows) and `goldens/ci/` (every run of text
///     obscured into a solid block, shadows off). This project has a single
///     host platform for tests, so the `ci` set only ever doubled the
///     regeneration cost of an engine bump (#230) while being structurally
///     unable to show a typography or layout regression. Platform on, ci off.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await loadAppFonts();
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: true),
      ciGoldensConfig: CiGoldensConfig(enabled: false),
    ),
    run: testMain,
  );
}
