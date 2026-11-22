import 'package:axiotask/src/app/app_destinations.dart';
import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/settings/settings_view.dart';
import 'package:axiotask/src/features/settings/settings_view_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

    await tester.scrollUntilVisible(
      find.bySemanticsLabel('Compact density'),
      120,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Compact density'));
    await tester.pump();
    expect(preferences.densityWrites.single, DensityPreference.compact);
  });

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
  }

  testWidgets('each device setting is a switch that saves immediately', (
    tester,
  ) async {
    final preferences = MemorySettingsPreferences();
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_app(viewModel, platform: TargetPlatform.android));
    await tester.pump();

    for (final (key, toggle, expected) in <(String, DeviceToggle, bool)>[
      (
        'settings-collapse-completed',
        DeviceToggle.collapseCompletedSubtasks,
        false,
      ),
      ('settings-haptics', DeviceToggle.haptics, false),
      ('settings-auto-sync-startup', DeviceToggle.autoSyncOnStartup, false),
    ]) {
      await reveal(tester, find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
      expect(preferences.toggleWrites.last, (toggle, expected), reason: key);
      expect(preferences.current.toggle(toggle), expected, reason: key);
    }
  });

  testWidgets('haptics is offered only where a haptic engine exists', (
    tester,
  ) async {
    final preferences = MemorySettingsPreferences();
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_app(viewModel));
    await tester.pump();
    await reveal(tester, find.byKey(const Key('settings-auto-sync-startup')));
    expect(find.byKey(const Key('settings-haptics')), findsNothing);
    expect(find.text('Feedback'), findsNothing);
  });

  testWidgets('a failed setting write keeps the previous value and says so', (
    tester,
  ) async {
    final preferences = MemorySettingsPreferences()..failNextToggleWrite = true;
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_app(viewModel));
    await tester.pump();
    final toggle = find.byKey(const Key('settings-auto-sync-startup'));
    await reveal(tester, toggle);
    await tester.tap(toggle);
    await tester.pump();

    expect(preferences.current.autoSyncOnStartup, isTrue);
    expect(viewModel.state.preferences.autoSyncOnStartup, isTrue);
    expect(
      viewModel.state.failureMessage,
      'Auto-sync on startup setting could not be saved. Your previous '
      'choice is still active.',
    );
  });

  testWidgets('settings links open their destinations', (tester) async {
    final preferences = MemorySettingsPreferences();
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    var supported = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: axiotaskTheme(
          Brightness.light,
          DensityPreference.standard,
          platform: TargetPlatform.linux,
        ),
        home: SettingsView(
          viewModel: viewModel,
          destinations: AppDestinations(
            about: (_) => const Scaffold(body: Text('about page')),
            syncActivity: (_) => const Scaffold(body: Text('activity page')),
            account: (_) => const Scaffold(body: Text('account page')),
            supportProject: () => supported += 1,
          ),
          accountBackupBuilder: (_) =>
              const Scaffold(body: Text('backup page')),
          localDataRecoveryBuilder: (_) =>
              const Scaffold(body: Text('recovery page')),
        ),
      ),
    );
    await tester.pump();

    for (final (key, page) in <(String, String)>[
      ('settings-sync-activity', 'activity page'),
      ('settings-account', 'account page'),
      ('settings-account-backup', 'backup page'),
      ('settings-local-data-recovery', 'recovery page'),
      ('settings-about', 'about page'),
    ]) {
      await reveal(tester, find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(find.text(page), findsOneWidget, reason: key);
      Navigator.of(tester.element(find.text(page))).pop();
      await tester.pumpAndSettle();
    }
    await reveal(tester, find.byKey(const Key('settings-support-project')));
    await tester.tap(find.byKey(const Key('settings-support-project')));
    expect(supported, 1);
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
        theme: axiotaskTheme(
          Brightness.light,
          DensityPreference.standard,
          platform: TargetPlatform.linux,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SettingsView(viewModel: viewModel),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
    expect(find.bySemanticsLabel('System theme, selected'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.bySemanticsLabel('Compact density'),
      120,
      scrollable: find.descendant(
        of: find.byKey(const Key('settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Compact density'));
    await tester.pump();
    expect(preferences.densityWrites.single, DensityPreference.compact);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  SettingsViewModel viewModel, {
  TargetPlatform platform = TargetPlatform.linux,
}) => MaterialApp(
  theme: axiotaskTheme(
    Brightness.light,
    DensityPreference.standard,
    platform: platform,
  ),
  home: SettingsView(viewModel: viewModel),
);
