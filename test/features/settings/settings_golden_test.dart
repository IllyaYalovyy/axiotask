import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/settings/settings_view.dart';
import 'package:axiotask/src/features/settings/settings_view_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'settings_test_support.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  const scenarios = <_SettingsScenario>[
    _SettingsScenario(
      name: 'system_standard',
      theme: ThemePreference.system,
      density: DensityPreference.standard,
      effectiveBrightness: Brightness.light,
    ),
    _SettingsScenario(
      name: 'light_compact',
      theme: ThemePreference.light,
      density: DensityPreference.compact,
      effectiveBrightness: Brightness.light,
    ),
    _SettingsScenario(
      name: 'dark_standard',
      theme: ThemePreference.dark,
      density: DensityPreference.standard,
      effectiveBrightness: Brightness.dark,
    ),
  ];

  for (final scenario in scenarios) {
    testWidgets('Linux Settings ${scenario.name}', (tester) async {
      tester.view.physicalSize = const Size(1024, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final preferences = MemorySettingsPreferences(
        current: DevicePreferences(
          theme: scenario.theme,
          density: scenario.density,
          onboardingDismissed: true,
        ),
      );
      final viewModel = SettingsViewModel(preferences)..start();
      addTearDown(preferences.close);
      addTearDown(viewModel.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: axiotaskTheme(
            scenario.effectiveBrightness,
            scenario.density,
            fontFamily: 'GoldenRoboto',
            platform: TargetPlatform.linux,
          ),
          home: SettingsView(viewModel: viewModel),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(tester.getRect(find.text('Settings')).width, greaterThan(60));
      expect(tester.getTopLeft(find.text('Appearance')).dy, greaterThan(50));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        0,
      );
      expect(
        find.byKey(Key('settings-theme-${scenario.theme.name}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('settings-density-${scenario.density.name}')),
        findsOneWidget,
      );
      await expectLater(
        find.byType(SettingsView),
        matchesGoldenFile('../../goldens/linux/settings_${scenario.name}.png'),
      );
    });
  }
}

final class _SettingsScenario {
  const _SettingsScenario({
    required this.name,
    required this.theme,
    required this.density,
    required this.effectiveBrightness,
  });

  final String name;
  final ThemePreference theme;
  final DensityPreference density;
  final Brightness effectiveBrightness;
}

Future<void> _loadFlutterRoboto() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document = jsonDecode(await packageConfig.readAsString());
  final packages =
      (document as Map<String, Object?>)['packages']! as List<Object?>;
  final flutter = packages.cast<Map<String, Object?>>().singleWhere(
    (value) => value['name'] == 'flutter',
  );
  final flutterPackage = Directory.fromUri(
    packageConfig.absolute.uri.resolve(flutter['rootUri']! as String),
  );
  final fontFile = File(
    '${flutterPackage.parent.parent.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await fontFile.readAsBytes();
  await (FontLoader('GoldenRoboto')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}
