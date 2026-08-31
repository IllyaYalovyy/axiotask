// Properties (MIGRATION-PLAN §5 T7.7) + Export + Import + FreshSync suites.
// Drives the real [PropertiesDialog] and the sidebar trigger. Assertions are
// about what RENDERS (buttons, confirms, toasts, the selected theme radio) and
// what the fake/real backend HOLDS — never that a method merely fired.

import 'dart:io';

import 'package:axiotask/src/app/app_settings.dart';
import 'package:axiotask/src/app/backup_service.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/local_data_reset.dart';
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
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

AppSettingsView settingsView({
  bool authenticated = false,
  bool needsReauth = false,
  List<String> scopes = const ['https://www.googleapis.com/auth/tasks'],
  String instance = '',
  bool credentialsMissing = false,
  SyncStatusView sync = const SyncStatusView.initial(),
}) => AppSettingsView(
  version: '0.1.0',
  instance: instance.isEmpty ? null : instance,
  pushEnabled: false,
  autoSyncOnStart: true,
  authenticated: authenticated,
  needsReauth: needsReauth,
  scopes: scopes,
  credentialsMissing: credentialsMissing,
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

  ConfigController tempConfig() => ConfigController(
    path: File(p.join(tmp.path, 'config.json')),
    initial: const AppConfig(),
  );

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
    LocalDataReset? localDataReset,
    Future<void> Function()? freshSync,
    Future<void> Function()? refreshAction,
    Prefs prefs = const Prefs(),
    List<Override> extraOverrides = const [],
    ThemeData? theme,
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
          if (backup != null) backupServiceProvider.overrideWithValue(backup),
          if (localDataReset != null)
            localDataResetProvider.overrideWithValue(localDataReset),
          if (freshSync != null)
            freshSyncActionProvider.overrideWithValue(freshSync),
          if (refreshAction != null)
            refreshActionProvider.overrideWithValue(refreshAction),
          ...extraOverrides,
        ],
        child: MaterialApp(
          theme: theme,
          home: const Scaffold(body: PropertiesDialog()),
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
  Future<void> scrollTo(WidgetTester tester, Key key) =>
      tester.scrollUntilVisible(
        find.byKey(key),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('sync-tab-list')),
          matching: find.byType(Scrollable),
        ),
      );

  // Tap a button whose handler does REAL async file IO. `runAsync` lets that IO
  // complete (fake timers would starve it); a final pump renders the result.
  Future<void> tapAsync(WidgetTester tester, Key key) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

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
      await tapAsync(tester, const Key('export-backup-button'));

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
      File(
        p.join(tmp.path, 'axiotask-backup-20260101-000000.json'),
      ).writeAsStringSync(backup.toJsonPretty());

      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      await pumpProps(
        tester,
        backup: BackupService(store: Store(db), backupsDir: tmp),
      );
      await scrollTo(tester, const Key('restore-backup-button'));
      await tapAsync(tester, const Key('restore-backup-button'));

      expect(
        find.textContaining('Restored 1 task(s) in 1 list(s) ←'),
        findsOneWidget,
      );
    });
  });

  group('Sync tab — last synced (#222)', () {
    SyncStatusView statusView({String? lastSynced}) => SyncStatusView(
      lastSynced: lastSynced,
      lastPulled: 0,
      lastPushed: 0,
      lastConflicts: 0,
      lastDeleted: 0,
      totalSyncs: 1,
      lastError: null,
      needsAttention: false,
      needsReauth: false,
    );

    testWidgets('the stat reads the relative phrase AND the absolute time', (
      tester,
    ) async {
      // This tab is the stats surface: "3m ago" alone cannot be checked against
      // anything, so the absolute LOCAL time sits beside it. Built from LOCAL
      // calendar fields and stored as the UTC instant sync persists, so a
      // UTC-rendering implementation shows different digits and fails here.
      final syncedAt = DateTime(2026, 8, 22, 10, 48);
      await withClock(
        Clock.fixed(syncedAt.add(const Duration(minutes: 3))),
        () async {
          await pumpProps(
            tester,
            settings: settingsView(
              authenticated: true,
              sync: statusView(lastSynced: syncedAt.toUtc().toIso8601String()),
            ),
          );

          expect(find.text('3m ago · Aug 22 10:48'), findsOneWidget);
          // Never the raw stored form.
          expect(find.textContaining('T10:48'), findsNothing);
        },
      );
    });

    testWidgets(
      'never synced reads "never" with no absolute time (non-happy)',
      (tester) async {
        await pumpProps(
          tester,
          settings: settingsView(authenticated: true, sync: statusView()),
        );

        // Exact text: a stat that appended an absolute time to a stamp it does
        // not have ("never · …") would not match.
        expect(find.text('never'), findsOneWidget);
        expect(find.textContaining('never ·'), findsNothing);
      },
    );
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

  group('Sync tab — sync now', () {
    testWidgets('is disabled until authenticated', (tester) async {
      await pumpProps(tester, settings: settingsView(authenticated: false));
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('sync-now-button')),
      );
      expect(button.onPressed, isNull, reason: 'gated on authentication');
    });

    testWidgets('tapping Sync now runs the real refresh action', (
      tester,
    ) async {
      var ran = 0;
      await pumpProps(
        tester,
        settings: settingsView(authenticated: true),
        refreshAction: () async => ran++,
      );

      await tester.tap(find.byKey(const Key('sync-now-button')));
      await tester.pumpAndSettle();

      expect(ran, 1, reason: 'Sync now drives the refresh (sync-when-authed)');
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

    testWidgets(
      'the haptics switch is ON by default and silences the app when turned '
      'off (#257)',
      (tester) async {
        final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')));
        await pumpProps(
          tester,
          extraOverrides: [prefsStoreProvider.overrideWithValue(store)],
        );
        await tester.tap(find.text('Appearance'));
        await tester.pumpAndSettle();

        final toggle = find.byKey(const Key('haptics-toggle'));
        expect(toggle, findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(toggle).value,
          isTrue,
          reason: 'haptics are opt-OUT',
        );

        await tester.tap(toggle);
        await tester.pumpAndSettle();

        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        expect(
          store.load().haptics,
          isFalse,
          reason: 'the choice survives a restart',
        );
      },
    );

    testWidgets('the haptics switch is absent on a desktop pointer', (
      tester,
    ) async {
      // The seam is a no-op off Android; a switch that changes nothing is not
      // an affordance, it is furniture.
      await pumpProps(tester, theme: ThemeData(platform: TargetPlatform.linux));
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('haptics-toggle')), findsNothing);
      expect(find.text('Haptics'), findsNothing);
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

    testWidgets('a configured install still opens on the Sync tab', (
      tester,
    ) async {
      await pumpProps(tester);
      expect(find.byKey(const Key('account-signin')), findsNothing);
    });

    testWidgets(
      'with no Google credentials it opens straight on Account (#228)',
      (tester) async {
        // The footer's "Google setup needed" sends the user here; landing on
        // Sync would leave them hunting for the one tab that explains it.
        await pumpProps(
          tester,
          settings: settingsView(credentialsMissing: true),
        );

        expect(find.byKey(const Key('account-not-configured')), findsOneWidget);
        expect(find.text('Not signed in — setup required'), findsOneWidget);
        expect(
          find.textContaining('/tmp/axiotask/config.json'),
          findsOneWidget,
          reason: 'the file to edit is named without another tap',
        );
      },
    );
  });

  // ── #215: the account-switch reset, end to end through the dialog ─────────
  //
  // Driven against a REAL store and a real dump target, so what is asserted is
  // what the user is left with: an empty store, a recovery file on disk, and a
  // sentence in the dialog telling them so. A refusal must leave the data.
  group('Account tab — reset local data (#215)', () {
    Future<void> openAccountTab(WidgetTester tester) async {
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
    }

    /// Walk the whole gate: open the confirm, type the word, confirm. Bounded
    /// pumps only — the focused field's caret animation never settles.
    Future<void> runResetGate(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.byKey(const Key('account-reset-data')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('account-tab-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const Key('reset-data-confirm-field')),
        'RESET',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('reset-data-confirm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The reset does REAL file IO (the durable recovery dump) with store
      // writes chained after it; only runAsync lets those futures complete
      // (fake timers starve them), and each stage needs a pump to hand control
      // back. A few alternating rounds settle the whole chain deterministically.
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump();
      }
    }

    testWidgets('the confirmed reset empties the store and reports it', (
      tester,
    ) async {
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
      await store.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'old account task',
            status: TaskStatus.needsAction,
            updated: 't',
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: 't',
        ),
      );

      await pumpProps(
        tester,
        localDataReset: LocalDataReset(
          database: db,
          store: store,
          dbPath: p.join(tmp.path, 'axiotask.sqlite'),
        ),
      );
      await openAccountTab(tester);
      await runResetGate(tester);

      // The store is empty and the recovery copy is on disk.
      expect(await store.allLists(), isEmpty);
      expect(await store.allTasks(), isEmpty);
      final dump = tmp.listSync().whereType<File>().where(
        (f) => p.basename(f.path).startsWith('axiotask-prereset-'),
      );
      expect(dump, hasLength(1));
      expect(dump.single.readAsStringSync(), contains('old account task'));

      // ...and the user is told, inside the dialog where they acted.
      expect(find.byKey(const Key('account-reset-notice')), findsOneWidget);
      expect(
        find.textContaining('Erased 1 task(s) in 1 list(s)'),
        findsOneWidget,
      );
    });

    testWidgets('a refused reset keeps the data and says so', (tester) async {
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

      await pumpProps(
        tester,
        localDataReset: LocalDataReset(
          database: db,
          store: store,
          // No such directory ⇒ the recovery copy cannot be written.
          dbPath: p.join(tmp.path, 'missing-dir', 'axiotask.sqlite'),
        ),
      );
      await openAccountTab(tester);
      await runResetGate(tester);

      expect((await store.allLists()).map((l) => l.list.id), [
        'L1',
      ], reason: 'no dump, no erase');
      expect(find.byKey(const Key('account-reset-notice')), findsOneWidget);
      expect(find.textContaining('NOT erased'), findsOneWidget);
    });

    testWidgets('a live session leaves the reset inert', (tester) async {
      await pumpProps(tester, settings: settingsView(authenticated: true));
      await openAccountTab(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('account-reset-data')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('account-tab-scroll')),
          matching: find.byType(Scrollable),
        ),
      );

      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('account-reset-data')))
            .onPressed,
        isNull,
        reason: 'the ratified order is sign out, then reset',
      );
    });
  });

  // ── #239: the sponsor ask lives in About, and NOWHERE else ───────────────
  //
  // Protects two things at once: the row hands the EXACT sponsors URL to the
  // url-opener seam (a typo'd or truncated URL is a dead donation link the
  // user can only discover by being annoyed), and the ask never leaks out of
  // the About tab into a banner, badge or startup prompt.
  group('About tab — Support axiotask (#239)', () {
    const sponsorsUrl = 'https://github.com/sponsors/IllyaYalovyy';

    Future<void> openAbout(WidgetTester tester) async {
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
    }

    /// WCAG contrast ratio between two opaque colours.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    testWidgets('tapping the row hands the exact sponsors URL to the opener', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpProps(
        tester,
        extraOverrides: [
          urlOpenerProvider.overrideWithValue((url) async => opened.add(url)),
        ],
      );
      await openAbout(tester);

      expect(find.text('Support axiotask'), findsOneWidget);
      expect(find.text('Donate via GitHub Sponsors'), findsOneWidget);
      // A Material icon, never an emoji glyph.
      expect(
        find.descendant(
          of: find.byKey(const Key('sponsor-link')),
          matching: find.byIcon(Icons.favorite_outline),
        ),
        findsOneWidget,
      );
      // Touch-reachable: the whole row is the target, not the icon.
      expect(
        tester.getSize(find.byKey(const Key('sponsor-link'))).height,
        greaterThanOrEqualTo(48.0),
      );

      await tester.tap(find.byKey(const Key('sponsor-link')));
      await tester.pump();
      expect(opened, [sponsorsUrl]);
    });

    testWidgets('the row is legible in dark, and still opens there', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpProps(
        tester,
        theme: ThemeData(brightness: Brightness.dark),
        extraOverrides: [
          urlOpenerProvider.overrideWithValue((url) async => opened.add(url)),
        ],
      );
      await openAbout(tester);

      final iconFinder = find.descendant(
        of: find.byKey(const Key('sponsor-link')),
        matching: find.byIcon(Icons.favorite_outline),
      );
      expect(iconFinder, findsOneWidget);

      // The heart must be VISIBLE against the dark surface it sits on — a
      // colour pinned to the light scheme would disappear here.
      final context = tester.element(iconFinder);
      final icon = tester.widget<Icon>(iconFinder);
      final effective = icon.color ?? IconTheme.of(context).color!;
      final surface = Theme.of(context).colorScheme.surface;
      expect(contrast(effective, surface), greaterThanOrEqualTo(3.0));

      await tester.tap(find.byKey(const Key('sponsor-link')));
      await tester.pump();
      expect(opened, [sponsorsUrl]);
    });

    testWidgets('no sponsor ask renders outside the About tab', (tester) async {
      await pumpProps(tester);

      // The dialog opens on Sync: nothing asks for money here...
      expect(find.text('Support axiotask'), findsNothing);
      expect(find.byKey(const Key('sponsor-link')), findsNothing);

      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(find.text('Support axiotask'), findsNothing);
      expect(find.byKey(const Key('sponsor-link')), findsNothing);

      // ...and only the About tab does.
      await openAbout(tester);
      expect(find.byKey(const Key('sponsor-link')), findsOneWidget);
    });
  });

  // ── #232: the pending-changes counter is LIVE ────────────────────────────
  //
  // Driven against a REAL store with the REAL `appSettingsProvider` assembly
  // (no settings override), because the defect being protected against lives
  // exactly there: a one-shot read of the push queue answered once per session
  // and then reported a number that no longer matched a single row on disk.
  group('pending changes counter is live (#232)', () {
    /// The Properties dialog over a real store, with the real settings
    /// assembly — the only wiring that can go stale.
    Future<void> pumpLive(WidgetTester tester, Store store) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configControllerProvider.overrideWithValue(tempConfig()),
            storeProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: Scaffold(body: PropertiesDialog())),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Tear the tree down INSIDE the test body, then pump once more.
    ///
    /// Disposing the `ProviderScope` cancels the drift stream, and drift defers
    /// its stream-store cleanup onto a zero-duration timer. Left to the
    /// binding's own teardown that timer is created after fake time has already
    /// stopped, so it never fires: the test trips the pending-timer invariant
    /// and the `db.close()` teardown then waits on it forever. Unmounting here
    /// gives the timer a frame to run on.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      // A bare `pump()` does NOT advance fake time, so the zero-duration timer
      // would still be sitting in the queue; give it a tick to run on.
      await tester.pump(const Duration(milliseconds: 1));
    }

    /// The value rendered beside the 'Pending changes' label.
    String pendingStat(WidgetTester tester) {
      final row = find
          .ancestor(
            of: find.text('Pending changes'),
            matching: find.byType(Row),
          )
          .first;
      return tester
          .widget<Text>(
            find.descendant(of: row, matching: find.byType(Text)).last,
          )
          .data!;
    }

    /// T1 turned into an unpushed local edit (the row a sync would push).
    StoredTask dirtyT1({String localUpdated = 't2'}) => StoredTask(
      task: Task(
        id: 'T1',
        position: '1',
        title: 'edited offline',
        status: TaskStatus.needsAction,
        updated: 't',
      ),
      listId: 'L1',
      syncState: SyncState.dirty,
      localUpdated: localUpdated,
      pendingOp: 'update',
    );

    testWidgets('the Sync tab follows the queue filling and draining while '
        'the dialog stays open', (tester) async {
      final store = await seededStore();
      await pumpLive(tester, store);
      expect(pendingStat(tester), '0', reason: 'nothing edited yet');

      // The user edits a task (offline, or just before the next push).
      await store.upsertTask(dirtyT1());
      await tester.pumpAndSettle();
      expect(
        pendingStat(tester),
        '1',
        reason: 'an unpushed edit must show up without reopening Properties',
      );

      // The push completes: the queue is empty again and the stat must say so.
      await store.markTaskClean('T1', 'e2', 't3', 't2');
      await tester.pumpAndSettle();
      expect(
        pendingStat(tester),
        '0',
        reason: 'a stat stuck on 1 with zero dirty rows is the reported defect',
      );
      await unmount(tester);
    });

    testWidgets('an edit made after the dialog opened still warns in the '
        'reset confirm', (tester) async {
      final store = await seededStore();
      await pumpLive(tester, store);

      // The unsynced edit lands while Properties is already open — the exact
      // case a session-long snapshot misses, and the one where losing the
      // warning means erasing data Google never saw.
      await store.upsertTask(dirtyT1());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('account-reset-data')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('account-tab-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('1 change(s) on this device never reached Google'),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('a dirty task in a local-only list never counts', (
      tester,
    ) async {
      final store = await seededStore();
      await store.upsertList(
        StoredTaskList(
          list: TaskList(id: 'LOCAL', title: 'Scratch', updated: 't'),
          syncState: SyncState.clean,
          localUpdated: 't',
          localOnly: true,
        ),
      );
      await pumpLive(tester, store);

      await store.upsertTask(
        StoredTask(
          task: Task(
            id: 'LT',
            position: '1',
            title: 'scratch note',
            status: TaskStatus.needsAction,
            updated: 't',
          ),
          listId: 'LOCAL',
          syncState: SyncState.dirty,
          localUpdated: 't2',
          pendingOp: 'create',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        pendingStat(tester),
        '0',
        reason: 'a local-only list is never pushed, so it owes Google nothing',
      );
      await unmount(tester);
    });
  });
}
