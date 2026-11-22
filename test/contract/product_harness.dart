import 'package:axiotask/src/app/axiotask_product.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/app/haptics.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/repository/external_link_launcher.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The two shipped form factors every must-have feature is checked on.
enum ProductTarget {
  /// Android phone, portrait.
  android(TargetPlatform.android, Size(412, 900)),

  /// Linux desktop window.
  linux(TargetPlatform.linux, Size(1280, 800));

  const ProductTarget(this.platform, this.size);

  final TargetPlatform platform;
  final Size size;

  bool get isPhone => this == ProductTarget.android;
}

/// The real shipped application ([AxiotaskProduct]) over an isolated
/// synthetic account: a private in-memory SQLite database (a fresh one each
/// time the product reopens its runtime), in-memory device preferences
/// and a synthetic Google Tasks service. Only the outermost platform edges
/// (file pickers, the browser, the haptic engine, the clipboard) are
/// recorders, so everything between a tap and those edges is production
/// code.
final class ProductFixture {
  ProductFixture._(
    this.tester,
    this.target,
    this.preferences,
    this.composition,
  );

  final WidgetTester tester;
  final ProductTarget target;
  final InMemoryDevicePreferencesBackend preferences;
  final TestComposition composition;

  final RecordingBackupFiles backupFiles = RecordingBackupFiles();
  final RecordingLinks links = RecordingLinks();
  final RecordingHaptics haptics = RecordingHaptics();
  final List<String> clipboard = <String>[];
  final List<TasksFeatureRuntime> runtimes = <TasksFeatureRuntime>[];

  TasksFeatureRuntime get runtime => runtimes.last;

  String get preferencesNamespace =>
      composition.boundary.storage.preferencesNamespace;

  static Future<ProductFixture> pump(
    WidgetTester tester,
    ProductTarget target, {
    Map<String, bool> storedToggles = const <String, bool>{},
  }) async {
    debugDefaultTargetPlatformOverride = target.platform;
    tester.view
      ..physicalSize = target.size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final composition = TestComposition.create(instanceId: 'contract');
    final namespace = composition.boundary.storage.preferencesNamespace;
    final preferences = InMemoryDevicePreferencesBackend();
    await preferences.writeBool('$namespace.onboarding_dismissed', true);
    for (final entry in storedToggles.entries) {
      await preferences.writeBool('$namespace.${entry.key}', entry.value);
    }
    final fixture = ProductFixture._(tester, target, preferences, composition);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments as Map<Object?, Object?>;
          fixture.clipboard.add(arguments['text']! as String);
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
    await tester.pumpWidget(
      AxiotaskProduct(
        clock: composition.clock,
        diagnostics: composition.diagnostics,
        diagnosticHistory: composition.diagnosticHistory,
        diagnosticExporter: const _NoDiagnosticExport(),
        services: ProductPlatformServices(
          backupExporter: fixture.backupFiles,
          backupImporter: fixture.backupFiles,
          links: fixture.links,
          haptics: fixture.haptics,
        ),
        version: '9.8.7',
        openRuntime: fixture._openRuntime,
      ),
    );
    await fixture.settle();
    return fixture;
  }

  Future<TasksFeatureRuntime> _openRuntime() async {
    final runtime = await TasksFeatureRuntime.open(
      composition,
      injectedDatabase: AppDatabase.inMemory(),
      injectedDevicePreferencesBackend: preferences,
    );
    runtimes.add(runtime);
    return runtime;
  }

  /// Lets database streams, the synthetic synchronization run and route
  /// transitions finish.
  Future<void> settle() async {
    for (var round = 0; round < 6; round += 1) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
    }
  }

  /// Removes the product and restores global test state. Must be the last
  /// call of every test: the platform override may not outlive the test body.
  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> tap(Finder finder) async {
    if (finder.evaluate().isEmpty) {
      // A control further down a lazily built page: scroll the frontmost
      // vertical list until it exists.
      final vertical = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            (widget.axisDirection == AxisDirection.down ||
                widget.axisDirection == AxisDirection.up),
      );
      if (vertical.evaluate().isNotEmpty) {
        await tester.scrollUntilVisible(finder, 200, scrollable: vertical.last);
        await tester.pumpAndSettle();
      }
    }
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    await tester.tap(finder.first);
    await settle();
  }

  /// Opens the application overflow menu ("More app actions").
  Future<void> openAppMenu() => tap(find.byTooltip('More app actions'));

  /// Opens Settings from the application overflow menu.
  Future<void> openSettings() async {
    await openAppMenu();
    await tap(find.text('Settings'));
    expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
  }

  /// Opens the collection actions menu of the visible task list.
  Future<void> openCollectionMenu() =>
      tap(find.byTooltip('Collection actions'));

  /// Scrolls a Settings control into view.
  Future<void> reveal(Finder finder, {Key scrollable = _settingsScroll}) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.descendant(
        of: find.byKey(scrollable),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Leaves a pushed page (Settings, About, phone task details).
  Future<void> back() async {
    final phoneDetails = find.byTooltip('Back to task collection');
    if (phoneDetails.evaluate().isNotEmpty) {
      await tap(phoneDetails);
      return;
    }
    await tester.pageBack();
    await settle();
  }

  /// The on/off value of the switch inside [setting].
  bool switchValue(Finder setting) => tester
      .widget<Switch>(
        find.descendant(of: setting, matching: find.byType(Switch)),
      )
      .value;

  Future<bool?> storedToggle(String name) =>
      preferences.readBool('$preferencesNamespace.$name');

  static const Key _settingsScroll = Key('settings-scroll');
}

final class RecordingBackupFiles
    implements AccountBackupExporter, AccountBackupImporter {
  final Map<String, String> saved = <String, String>{};
  int openRequests = 0;

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async {
    saved[suggestedName] = contents;
    return AccountBackupSaveResult.saved(suggestedName);
  }

  @override
  Future<AccountBackupOpenResult> open() async {
    openRequests += 1;
    if (saved.isEmpty) return const AccountBackupOpenResult.cancelled();
    return AccountBackupOpenResult.opened(
      fileName: saved.keys.last,
      contents: saved.values.last,
    );
  }
}

final class RecordingLinks implements ExternalLinkLauncher {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

final class RecordingHaptics implements Haptics {
  int ticks = 0;
  int confirms = 0;

  int get total => ticks + confirms;

  @override
  void tick() => ticks += 1;

  @override
  void confirm() => confirms += 1;
}

final class _NoDiagnosticExport implements DiagnosticExportPort {
  const _NoDiagnosticExport();

  @override
  Future<DiagnosticExportReceipt> export(List<DiagnosticRecord> records) =>
      Future<DiagnosticExportReceipt>.error(StateError('Not exported.'));
}
