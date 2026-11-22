import 'package:axiotask/src/app/haptics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The haptics seam restored from v1.5.3. End-to-end behaviour (a completed
/// task vibrates; the setting silences it) is in the must-have feature
/// contract, `MH-PREF-002`.
void main() {
  test('only touch platforms have a haptic engine', () {
    expect(supportsHaptics(TargetPlatform.android), isTrue);
    expect(supportsHaptics(TargetPlatform.iOS), isTrue);
    expect(supportsHaptics(TargetPlatform.linux), isFalse);
    expect(supportsHaptics(TargetPlatform.windows), isFalse);
    expect(supportsHaptics(TargetPlatform.macOS), isFalse);
  });

  testWidgets('without a scope the application is silent', (tester) async {
    late Haptics resolved;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          resolved = HapticsScope.of(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(resolved, isA<NoHaptics>());
  });

  testWidgets('platform haptics use the system channel and never throw', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          calls.add(call.arguments as String);
          throw PlatformException(code: 'no_engine');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const PlatformHaptics()
      ..tick()
      ..confirm();
    await tester.pump();

    expect(calls, <String>[
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.mediumImpact',
    ]);
    expect(tester.takeException(), isNull);
  });
}
