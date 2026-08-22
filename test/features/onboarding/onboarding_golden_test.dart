import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/onboarding/onboarding_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  for (final brightness in Brightness.values) {
    testWidgets('Linux onboarding ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: axiotaskTheme(
            brightness,
            DensityPreference.standard,
            fontFamily: 'GoldenRoboto',
            platform: TargetPlatform.linux,
          ),
          home: const OnboardingView(onDismiss: _dismiss),
        ),
      );
      await tester.pump();

      await expectLater(
        find.byType(OnboardingView),
        matchesGoldenFile(
          '../../goldens/linux/onboarding_${brightness.name}.png',
        ),
      );
    });
  }
}

Future<void> _dismiss() async {}

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
