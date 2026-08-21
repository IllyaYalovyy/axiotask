import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/settings/settings_view.dart';
import 'package:axiotask/src/features/settings/settings_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'settings_test_support.dart';

void main() {
  testWidgets('current choices are accessible and persist typed selections', (
    tester,
  ) async {
    final preferences = MemorySettingsPreferences(
      current: const DevicePreferences(
        theme: ThemePreference.dark,
        density: DensityPreference.compact,
        onboardingDismissed: true,
      ),
    );
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_app(viewModel));
    await tester.pump();

    expect(find.bySemanticsLabel('Dark theme, selected'), findsOneWidget);
    expect(find.bySemanticsLabel('Compact density, selected'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(preferences.themeWrites.single, ThemePreference.light);
    expect(find.bySemanticsLabel('Light theme, selected'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Standard density'));
    await tester.pump();
    expect(preferences.densityWrites.single, DensityPreference.standard);
    expect(find.bySemanticsLabel('Standard density, selected'), findsOneWidget);
  });

  testWidgets('persistence failure is nonblocking and dismissible', (
    tester,
  ) async {
    final preferences = MemorySettingsPreferences()..failNextThemeWrite = true;
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_app(viewModel));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Dark theme'));
    await tester.pump();
    expect(find.byKey(const Key('settings-failure')), findsOneWidget);
    expect(find.textContaining('could not be saved'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.byKey(const Key('settings-failure')), findsNothing);

    _scrollSettingsToEnd(tester);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Compact density'));
    await tester.pump();
    expect(preferences.densityWrites.single, DensityPreference.compact);
  });

  testWidgets('settings remains readable and focusable at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = MemorySettingsPreferences();
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SettingsView(viewModel: viewModel),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
    expect(find.bySemanticsLabel('System theme, selected'), findsOneWidget);
    _scrollSettingsToEnd(tester);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Compact density'));
    await tester.pump();
    expect(preferences.densityWrites.single, DensityPreference.compact);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(SettingsViewModel viewModel) => MaterialApp(
  theme: axiotaskTheme(Brightness.light, DensityPreference.standard),
  home: SettingsView(viewModel: viewModel),
);

void _scrollSettingsToEnd(WidgetTester tester) {
  final scrollable = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const Key('settings-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
}
