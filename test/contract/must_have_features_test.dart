// The must-have feature contract.
//
// Every entry of `must_have_features.json` is driven here through the REAL
// shipped widget tree (`AxiotaskProduct`, exactly what `main()` runs) on each
// target it lists. A feature that is deleted, unwired on one platform, or
// buried so its control is no longer reachable fails its test by name.
//
// These tests assert behaviour and reachability, never pixels: restyling,
// moving a control within its screen, or a Flutter upgrade does not break
// them. Removing what a user could do does.
//
// Adding a feature: add a registry entry and a contract below. Removing one
// requires the owner's approval in `approved_removals.json`.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/app_version.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/sync_activity_repository.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'product_harness.dart';

typedef _Body = Future<void> Function(ProductFixture fixture);

final class _Contract {
  const _Contract(this.body, {this.storedToggles = const <String, bool>{}});

  final _Body body;

  /// Device toggles stored before the product starts.
  final Map<String, bool> storedToggles;
}

/// Local edits stay unpublished, so the synthetic read-only Google service is
/// never asked to mutate.
const _readOnly = <String, bool>{'read_only_sync': true};

const _syntheticTask = 'Verified synthetic task';

final _contracts = <String, _Contract>{
  'MH-CORE-001': _Contract((f) async {
    expect(find.text(_syntheticTask), findsOneWidget);
    expect(find.text('Synthetic inbox'), findsWidgets);
    expect(f.runtime.viewModel.state.health.outcome, SyncHealthOutcome.good);
  }),
  'MH-CORE-002': _Contract((f) async {
    await _addTask(f, 'Contract created task');
    expect(find.text('Contract created task'), findsWidgets);
    expect(
      f.runtime.viewModel.state.tasks.map((task) => task.title),
      contains('Contract created task'),
    );
  }, storedToggles: _readOnly),
  'MH-CORE-003': _Contract((f) async {
    await f.tap(find.byTooltip('Complete task'));
    final task = f.runtime.viewModel.state.tasks.singleWhere(
      (task) => task.title == _syntheticTask,
    );
    expect(task.status, TaskStatus.completed);
    expect(find.text('Undo'), findsWidgets, reason: 'Completion offers Undo');
  }, storedToggles: _readOnly),
  'MH-CORE-004': _Contract((f) async {
    await f.tap(find.text(_syntheticTask));
    expect(find.byKey(const Key('task-detail-scroll-view')), findsOneWidget);
    expect(
      find.byKey(const Key('task-detail-completion-action')),
      findsOneWidget,
    );
    expect(
      find.textContaining('This isolated composition never contacts Google'),
      findsWidgets,
      reason: 'Details show the notes',
    );
  }),
  'MH-CORE-005': _Contract((f) async {
    for (final view in <String>[
      'Focus',
      'Upcoming',
      'Missed',
      'Unscheduled',
      'All',
    ]) {
      expect(find.text(view), findsWidgets, reason: '$view is one step away');
    }
    await f.tap(find.text('Unscheduled'));
    expect(f.runtime.viewModel.state.selectedSmartView, isNotNull);
    expect(find.text(_syntheticTask), findsOneWidget);
    await f.tap(find.text('Missed'));
    expect(find.text(_syntheticTask), findsNothing);
  }),
  'MH-CORE-006': _Contract((f) async {
    await f.tap(find.byTooltip('Search tasks'));
    await f.tester.enterText(find.byKey(const Key('search-input')), 'Verified');
    await f.settle();
    expect(find.byKey(const Key('search-result-0')), findsOneWidget);
  }),
  'MH-CORE-007': _Contract((f) async {
    Future<int> runs() async => (await f.tester.runAsync(
      () => f.runtime.syncActivityRepository!
          .watchRecentRuns(f.runtime.viewModel.accountId)
          .first,
    ))!.length;
    final before = await runs();
    if (f.target.isPhone) {
      await f.openAppMenu();
      await f.tap(find.text('Refresh'));
    } else {
      await f.tap(find.byTooltip('Refresh'));
    }
    expect(await runs(), before + 1, reason: 'Refresh starts a run');
    if (f.target.isPhone) {
      await f.openAppMenu();
      await f.tap(find.text('Stop sync'));
    } else {
      await f.tap(find.byTooltip('Stop sync'));
    }
    final health = f.runtime.viewModel.state.health;
    expect(health.outcome, SyncHealthOutcome.inactive);
    expect(health.inactiveReason, SyncInactiveReason.syncStopped);
    expect(health.action, SyncHealthAction.resume);
  }),
  'MH-CORE-008': _Contract((f) async {
    await f.openSettings();
    await f.tap(find.byKey(const Key('settings-theme-dark')));
    expect(
      Theme.of(f.tester.element(find.byKey(const Key('settings-scroll'))))
          .brightness,
      Brightness.dark,
    );
    expect(
      await f.preferences.readString('${f.preferencesNamespace}.theme'),
      'dark',
    );
  }),
  'MH-CORE-009': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Local data recovery'));
    expect(find.textContaining('Reset'), findsWidgets);
  }),
  'MH-ABOUT-001': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('About Axiotask'));
    expect(find.byKey(const Key('about-version')), findsOneWidget);
    expect(find.text('v9.8.7'), findsOneWidget);
    // And from Settings, where a user looks for it.
    await f.back();
    await f.openSettings();
    await f.reveal(find.byKey(const Key('settings-about')));
    await f.tap(find.byKey(const Key('settings-about')));
    expect(find.text('v9.8.7'), findsOneWidget);
  }),
  'MH-SUPPORT-001': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Support the project'));
    expect(f.links.opened, <Uri>[supportProjectUri]);
    await f.openAppMenu();
    await f.tap(find.text('About Axiotask'));
    await f.reveal(
      find.byKey(const Key('about-support-project')),
      scrollable: const Key('about-scroll'),
    );
    await f.tap(find.byKey(const Key('about-support-project')));
    expect(f.links.opened, <Uri>[supportProjectUri, supportProjectUri]);
    expect(supportProjectUri.host, 'github.com');
    expect(supportProjectUri.path, '/sponsors/IllyaYalovyy');
  }),
  'MH-ACCOUNT-001': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Account'));
    expect(find.text('Connected to Google Tasks'), findsOneWidget);
    await f.tap(find.byKey(const Key('account-sign-out')));
    await f.tap(find.byKey(const Key('account-sign-out-accept')));
    expect(find.text('Signed out'), findsOneWidget);
    final signedOut = f.runtime.viewModel.state.health;
    expect(signedOut.outcome, SyncHealthOutcome.inactive);
    expect(signedOut.inactiveReason, SyncInactiveReason.noAuthorization);
    expect(
      f.runtime.viewModel.state.tasks.map((task) => task.title),
      contains(_syntheticTask),
      reason: 'Signing out keeps local tasks',
    );
    await f.tap(find.byKey(const Key('account-sign-in')));
    expect(find.text('Connected to Google Tasks'), findsOneWidget);
    expect(f.runtime.viewModel.state.health.outcome, SyncHealthOutcome.good);
  }),
  'MH-ACCOUNT-002': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Account'));
    await f.tap(find.byKey(const Key('account-switch')));
    expect(find.byKey(const Key('account-switch-confirm')), findsOneWidget);
    await f.tap(find.byKey(const Key('account-switch-accept')));
    expect(
      f.runtimes,
      hasLength(2),
      reason: 'The application reopened for a new account',
    );
    expect(find.byKey(const Key('account-scroll')), findsNothing);
  }),
  'MH-SYNC-001': _Contract((f) async {
    await f.openSettings();
    final toggle = find.byKey(const Key('settings-read-only-sync'));
    await f.reveal(toggle);
    await f.tap(toggle);
    expect(await f.storedToggle('read_only_sync'), isTrue);
    await f.back();
    await _addTask(f, 'Kept on this device');
    // Force a synchronization now: read-only must hold the change back. The
    // synthetic Google service rejects every mutation, so a run that tried
    // to publish could not succeed.
    final runsBefore = (await f.tester.runAsync(
      () => f.runtime.syncActivityRepository!
          .watchRecentRuns(f.runtime.viewModel.accountId)
          .first,
    ))!.length;
    if (f.target.isPhone) {
      await f.openAppMenu();
      await f.tap(find.text('Refresh'));
    } else {
      await f.tap(find.byTooltip('Refresh'));
    }
    final health = f.runtime.viewModel.state.health;
    expect(
      health.counts.total,
      greaterThan(0),
      reason: 'The change stays pending, unpublished',
    );
    final runs = (await f.tester.runAsync(
      () => f.runtime.syncActivityRepository!
          .watchRecentRuns(f.runtime.viewModel.accountId)
          .first,
    ))!;
    expect(runs.length, runsBefore + 1, reason: 'Refresh ran a sync');
    expect(
      runs.map((run) => run.state),
      everyElement(SyncRunRecordState.succeeded),
      reason: 'Read-only runs never attempt (and fail) a publication',
    );
    final attempts = await f.tester.runAsync(() {
      final database = f.runtime.database;
      return database.select(database.desiredStateAttemptRows).get();
    });
    expect(
      attempts,
      isEmpty,
      reason: 'Read-only sync must not even attempt to upload local changes',
    );
    // Leaving read-only mode would publish; it must ask first.
    await f.openSettings();
    await f.reveal(toggle);
    await f.tap(toggle);
    expect(find.byKey(const Key('settings-read-only-confirm')), findsOneWidget);
    await f.tap(find.text('Cancel'));
    expect(await f.storedToggle('read_only_sync'), isTrue);
  }),
  'MH-SYNC-002': _Contract((f) async {
    expect(
      find.text(_syntheticTask),
      findsNothing,
      reason: 'With auto-sync off, nothing is fetched at startup',
    );
    final runs = (await f.tester.runAsync(
      () => f.runtime.syncActivityRepository!
          .watchRecentRuns(f.runtime.viewModel.accountId)
          .first,
    ))!;
    expect(runs, isEmpty);
    await f.openSettings();
    final toggle = find.byKey(const Key('settings-auto-sync-startup'));
    await f.reveal(toggle);
    expect(f.switchValue(toggle), isFalse);
    await f.tap(toggle);
    expect(await f.storedToggle('auto_sync_on_startup'), isTrue);
    await f.back();
    // A manual refresh still synchronizes.
    if (f.target.isPhone) {
      await f.openAppMenu();
      await f.tap(find.text('Refresh'));
    } else {
      await f.tap(find.byTooltip('Refresh'));
    }
    expect(find.text(_syntheticTask), findsOneWidget);
  }, storedToggles: <String, bool>{'auto_sync_on_startup': false}),
  'MH-SYNC-003': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Sync activity'));
    expect(find.byKey(const Key('sync-run-0')), findsOneWidget);
    expect(find.textContaining('Succeeded'), findsWidgets);
    expect(find.textContaining('App start'), findsWidgets);
    // And from Settings.
    await f.back();
    await f.openSettings();
    await f.reveal(find.byKey(const Key('settings-sync-activity')));
    await f.tap(find.byKey(const Key('settings-sync-activity')));
    expect(find.byKey(const Key('sync-run-0')), findsOneWidget);
  }),
  'MH-BACKUP-001': _Contract((f) async {
    await f.openAppMenu();
    await f.tap(find.text('Account backup'));
    await f.tap(find.text('Choose file and export'));
    await f.tap(find.text('Export backup'));
    expect(f.backupFiles.saved, hasLength(1));
    final backup = f.backupFiles.saved.values.single;
    expect(backup, contains(_syntheticTask));
    expect(backup, contains('Synthetic inbox'));
    // The selected backup contains a task absent from the live account.
    // Google cannot recreate this synthetic task: only Restore can do so.
    const restoredTitle = 'Restored contract task';
    final document = jsonDecode(backup) as Map<String, dynamic>;
    final task = (document['tasks'] as List).first as Map<String, dynamic>;
    task['googleId'] = null;
    task['title'] = restoredTitle;
    f.backupFiles.saved[f.backupFiles.saved.keys.single] = jsonEncode(document);
    await f.tap(find.text('Choose backup to restore'));
    expect(f.backupFiles.openRequests, 1);
    expect(
      find.text('Restore absent records'),
      findsOneWidget,
      reason: 'The chosen backup is validated and offered for restore',
    );
    await f.tap(find.text('Restore absent records'));
    expect(find.text('Restore accepted locally'), findsOneWidget);
    final restored = await f.tester.runAsync(() {
      final database = f.runtime.database;
      return (database.select(
        database.taskCacheRows,
      )..where((row) => row.title.equals(restoredTitle))).get();
    });
    expect(
      restored,
      hasLength(1),
      reason: 'Restore recreated the missing task',
    );
  }),
  'MH-PREF-001': _Contract((f) async {
    final viewModel = f.runtime.viewModel;
    final parent = viewModel.state.tasks.singleWhere(
      (task) => task.title == _syntheticTask,
    );
    await f.tester.runAsync(() async {
      await viewModel.createTask(
        taskListId: parent.taskListId,
        parentTaskId: parent.id,
        title: 'Finished subtask',
      );
    });
    await f.settle();
    final child = viewModel.state.tasks.singleWhere(
      (task) => task.title == 'Finished subtask',
    );
    await f.tester.runAsync(
      () => viewModel.setTaskCompletion(child.id, TaskStatus.completed),
    );
    await f.settle();

    Future<void> openDetails() async {
      await f.tap(find.text(_syntheticTask));
      expect(find.byKey(const Key('task-detail-scroll-view')), findsOneWidget);
    }

    Future<void> closeDetails() async {
      if (f.target.isPhone) await f.back();
    }

    // Default: collapsed.
    await openDetails();
    expect(find.text('Finished subtask'), findsNothing);
    expect(find.text('Show 1 completed subtask'), findsOneWidget);
    await closeDetails();

    await f.openSettings();
    final toggle = find.byKey(const Key('settings-collapse-completed'));
    await f.reveal(toggle);
    await f.tap(toggle);
    expect(await f.storedToggle('collapse_completed_subtasks'), isFalse);
    await f.back();

    await openDetails();
    expect(
      find.text('Finished subtask'),
      findsWidgets,
      reason: 'With the setting off, completed subtasks start visible',
    );
  }, storedToggles: _readOnly),
  'MH-PREF-002': _Contract((f) async {
    await f.tap(find.byTooltip('Complete task'));
    expect(f.haptics.total, greaterThan(0), reason: 'Haptics default on');
    final before = f.haptics.total;
    await f.openSettings();
    final toggle = find.byKey(const Key('settings-haptics'));
    await f.reveal(toggle);
    await f.tap(toggle);
    expect(await f.storedToggle('haptics'), isFalse);
    await f.back();
    await _addTask(f, 'Silent task');
    await f.tap(find.byTooltip('Complete task'));
    expect(f.haptics.total, before, reason: 'Off silences every haptic');
  }, storedToggles: _readOnly),
  'MH-EXPORT-001': _Contract((f) async {
    await f.openCollectionMenu();
    await f.tap(find.byKey(const Key('collection-export')));
    expect(find.byKey(const Key('export-sheet')), findsOneWidget);
    expect(find.byKey(const Key('export-count')), findsOneWidget);
    final preview = f.tester.widget<SelectableText>(
      find.byKey(const Key('export-preview-text')),
    );
    expect(preview.data, contains('- [ ] $_syntheticTask'));
    // The other format is one tap away and previews too.
    await f.tap(find.text('CSV'));
    expect(
      f.tester
          .widget<SelectableText>(find.byKey(const Key('export-preview-text')))
          .data,
      startsWith('title,list,due,status'),
    );
    await f.tap(find.byKey(const Key('export-copy')));
    expect(f.clipboard, hasLength(1));
    expect(f.clipboard.single, contains(_syntheticTask));
    expect(find.textContaining('Copied 1 task'), findsWidgets);
  }),
  'MH-EXPORT-002': _Contract((f) async {
    await f.openCollectionMenu();
    await f.tap(find.byKey(const Key('collection-export')));
    expect(
      find.byKey(const Key('export-save')),
      findsOneWidget,
      reason: 'Saving to a file is offered on every platform',
    );
    expect(
      find.byKey(const Key('export-share')),
      f.target.isPhone ? findsOneWidget : findsNothing,
      reason: 'Share is offered where a share sheet exists',
    );
    expect(find.byKey(const Key('export-cancel')), findsOneWidget);
  }),
};

Future<void> _addTask(ProductFixture f, String title) async {
  if (f.target.isPhone) {
    await f.tap(find.byTooltip('New task'));
  }
  await f.tester.enterText(find.byKey(const Key('quick-add-input')), title);
  await f.settle();
  await f.tap(find.byKey(const Key('quick-add-submit')));
  if (f.target.isPhone &&
      find.byKey(const Key('composer-cancel')).evaluate().isNotEmpty) {
    await f.tap(find.byKey(const Key('composer-cancel')));
  }
}

void main() {
  final registry = jsonDecode(
    File('test/contract/must_have_features.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final features = (registry['features']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('registry and contracts describe the same features', () {
    final ids = features.map((feature) => feature['id']! as String).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: 'IDs are unique');
    expect(
      ids.toSet().difference(_contracts.keys.toSet()),
      isEmpty,
      reason: 'Every registered must-have feature needs a contract',
    );
    expect(
      _contracts.keys.toSet().difference(ids.toSet()),
      isEmpty,
      reason: 'Every contract must be registered',
    );
    for (final feature in features) {
      final targets = (feature['targets']! as List<Object?>).cast<String>();
      expect(targets, isNotEmpty, reason: '${feature['id']} needs a target');
      expect(
        ProductTarget.values.map((target) => target.name),
        containsAll(targets),
      );
    }
  });

  for (final feature in features) {
    final id = feature['id']! as String;
    final contract = _contracts[id];
    if (contract == null) continue;
    for (final name in (feature['targets']! as List<Object?>).cast<String>()) {
      final target = ProductTarget.values.byName(name);
      testWidgets('[$id] $name: ${feature['title']}', (tester) async {
        final fixture = await ProductFixture.pump(
          tester,
          target,
          storedToggles: contract.storedToggles,
        );
        try {
          await contract.body(fixture);
        } finally {
          await fixture.dispose();
        }
      });
    }
  }
}
