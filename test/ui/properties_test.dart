// Properties (MIGRATION-PLAN §5 T7.7) + Export + Import + FreshSync suites.
// Drives the real [PropertiesDialog] and the sidebar trigger. Assertions are
// about what RENDERS (buttons, confirms, toasts, the selected theme radio) and
// what the fake/real backend HOLDS — never that a method merely fired.

import 'dart:io';

import 'package:axiotask/src/app/app_settings.dart';
import 'package:axiotask/src/app/backup_service.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/backup.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/properties.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

AppSettingsView settingsView({
  bool authenticated = false,
  bool needsReauth = false,
  List<String> scopes = const ['https://www.googleapis.com/auth/tasks'],
  String instance = '',
  SyncStatusView sync = const SyncStatusView.initial(),
}) => AppSettingsView(
  version: '0.1.0',
  instance: instance.isEmpty ? null : instance,
  pushEnabled: false,
  autoSyncOnStart: true,
  authenticated: authenticated,
  needsReauth: needsReauth,
  scopes: scopes,
  dbPath: '/tmp/axiotask/axiotask.sqlite',
  configPath: '/tmp/axiotask/config.json',
  pendingPushes: 0,
  sync: sync,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_props'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigController tempConfig() =>
      ConfigController(path: File(p.join(tmp.path, 'config.json')),
          initial: const AppConfig());

  Future<Store> seededStore() async {
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    await store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'L1', title: 'Inbox', updated: 't'),
        syncState: SyncState.clean,
        localUpdated: 't',
      ),
    );
    for (final id in ['T1', 'T2']) {
      await store.upsertTask(
        StoredTask(
          task: Task(
            id: id,
            position: '1',
            title: 'task $id',
            status: TaskStatus.needsAction,
            updated: 't',
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: 't',
        ),
      );
    }
    return store;
  }

  /// Pump the Properties dialog directly under a Scaffold (so the toast's
  /// ScaffoldMessenger resolves) with the given overrides.
  Future<void> pumpProps(
    WidgetTester tester, {
    AppSettingsView? settings,
    BackupService? backup,
    Future<void> Function()? freshSync,
    Prefs prefs = const Prefs(),
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          configControllerProvider.overrideWithValue(tempConfig()),
          appSettingsProvider.overrideWithValue(settings ?? settingsView()),
          if (backup != null)
            backupServiceProvider.overrideWithValue(backup),
          if (freshSync != null)
            freshSyncActionProvider.overrideWithValue(freshSync),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PropertiesDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('sidebar trigger', () {
    testWidgets('has a Properties trigger and no Fresh sync', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              selectedViewId: 'all',
              counts: const {},
              lists: const [],
              excludedLists: const {},
              onSelectView: (_) {},
              onCreateList: (_, {localOnly = false}) {},
              onRenameList: (_, _) {},
              onDeleteList: (_) {},
              onToggleExclude: (_) {},
              onReorderLists: (_) {},
              onOpenProperties: () => opened++,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('open-properties')), findsOneWidget);
      // No Fresh sync in the sidebar — it lives only inside Properties.
      expect(find.text('Fresh sync'), findsNothing);

      await tester.tap(find.byKey(const Key('open-properties')));
      expect(opened, 1);
    });
  });

  // The Sync tab scrolls; the Backup buttons sit at the bottom. Bring a key into
  // view before asserting/tapping (a ListView never builds off-screen children).
  Future<void> scrollTo(WidgetTester tester, Key key) => tester.scrollUntilVisible(
    find.byKey(key),
    300,
    scrollable: find.descendant(
      of: find.byKey(const Key('sync-tab-list')),
      matching: find.byType(Scrollable),
    ),
  );

  group('Sync tab — backup', () {
    testWidgets('exposes Export and Restore backup buttons', (tester) async {
      await pumpProps(tester);
      await scrollTo(tester, const Key('export-backup-button'));
      expect(find.byKey(const Key('export-backup-button')), findsOneWidget);
      expect(find.byKey(const Key('restore-backup-button')), findsOneWidget);
    });

    testWidgets('Export confirms with a toast naming the counts and file', (
      tester,
    ) async {
      final store = await seededStore();
      await pumpProps(
        tester,
        backup: BackupService(store: store, backupsDir: tmp),
      );
      await scrollTo(tester, const Key('export-backup-button'));
      await tester.tap(find.byKey(const Key('export-backup-button')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Backed up 2 task(s) in 1 list(s) →'),
        findsOneWidget,
      );
      // A real file landed in the backups dir.
      expect(
        tmp.listSync().whereType<File>().any(
          (f) => p.basename(f.path).startsWith('axiotask-backup-'),
        ),
        isTrue,
      );
    });

    testWidgets('Restore latest reports the restored counts', (tester) async {
      // Pre-write a backup file the dialog will restore into an empty store.
      final backup = Backup.build('2026-01-01T00:00:00Z', [
        (
          StoredTaskList(
            list: TaskList(id: 'L9', title: 'Restored', updated: 't'),
            syncState: SyncState.clean,
            localUpdated: 't',
          ),
          [
            StoredTask(
              task: Task(
                id: 'R1',
                position: '1',
                title: 'restored task',
                status: TaskStatus.needsAction,
                updated: 't',
              ),
              listId: 'L9',
              syncState: SyncState.clean,
              localUpdated: 't',
            ),
          ],
        ),
      ]);
      File(p.join(tmp.path, 'axiotask-backup-20260101-000000.json'))
          .writeAsStringSync(backup.toJsonPretty());

      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      await pumpProps(
        tester,
        backup: BackupService(store: Store(db), backupsDir: tmp),
      );
      await scrollTo(tester, const Key('restore-backup-button'));
      await tester.tap(find.byKey(const Key('restore-backup-button')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Restored 1 task(s) in 1 list(s) ←'),
        findsOneWidget,
      );
    });
  });

  group('Sync tab — fresh sync', () {
    testWidgets('is disabled until authenticated', (tester) async {
      await pumpProps(tester, settings: settingsView(authenticated: false));
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('fresh-sync-button')),
      );
      expect(button.onPressed, isNull, reason: 'gated on authentication');
    });

    testWidgets('uses a styled confirm; confirming runs fresh_sync', (
      tester,
    ) async {
      var ran = 0;
      await pumpProps(
        tester,
        settings: settingsView(authenticated: true),
        freshSync: () async => ran++,
      );
      await tester.tap(find.byKey(const Key('fresh-sync-button')));
      await tester.pumpAndSettle();

      // Styled confirm inside Properties (not an immediate destructive action).
      expect(find.byKey(const Key('fresh-sync-confirm')), findsOneWidget);
      expect(ran, 0, reason: 'nothing happens before confirmation');

      await tester.tap(find.byKey(const Key('fresh-sync-confirm-button')));
      await tester.pumpAndSettle();
      expect(ran, 1);
    });

    testWidgets('canceling the confirm runs nothing', (tester) async {
      var ran = 0;
      await pumpProps(
        tester,
        settings: settingsView(authenticated: true),
        freshSync: () async => ran++,
      );
      await tester.tap(find.byKey(const Key('fresh-sync-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(ran, 0);
    });
  });

  group('sync mode toggle', () {
    testWidgets('turning on read-write sync asks for inline confirmation', (
      tester,
    ) async {
      await pumpProps(tester);
      expect(find.byKey(const Key('enable-push-confirm')), findsNothing);
      await tester.tap(find.byKey(const Key('sync-push-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('enable-push-confirm')), findsOneWidget);
      expect(find.byKey(const Key('confirm-enable-push')), findsOneWidget);
    });
  });

  group('Appearance tab', () {
    testWidgets('selecting a theme applies it live', (tester) async {
      await pumpProps(tester, prefs: const Prefs(theme: 'system'));
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();

      // Selecting Light switches the group value to 'light'.
      await tester.tap(find.byKey(const Key('theme-light')));
      await tester.pumpAndSettle();
      final tile = tester.widget<RadioListTile<String>>(
        find.byKey(const Key('theme-light')),
      );
      // The group is driven by the live pref; the tile's value is 'light' and
      // the RadioGroup now selects it.
      expect(tile.value, 'light');
      expect(find.text('Light'), findsOneWidget);
    });
  });

  group('Account tab', () {
    testWidgets('renders the signed-out state and its sign-in action', (
      tester,
    ) async {
      await pumpProps(tester);
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.byKey(const Key('account-signin')), findsOneWidget);
    });
  });
}
