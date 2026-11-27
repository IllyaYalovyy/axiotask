// Upgrading from 1.6.0 with edits that never left the device.
//
// 1.6.0 could be set not to push (and was by default), so an upgraded database
// may hold any amount of pending local work. The first sync after the upgrade
// has to send all of it, with the ordinary conflict handling.
//
// `fixtures/1.6.0_read_only.sql` was recorded by the 1.6.0 code with pushing
// off: it pulled the account [_account] builds, made one change of every kind
// through [Commands], synced again, and dumped the database. Its etags are the
// ones [_account] hands out, so the two must stay in step. It is a record of
// what is on users' disks — never regenerate it from current code.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/bootstrap.dart';
import 'package:axiotask/src/app/instance.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

FakeTasksApi _account() => FakeTasksApi()
  ..seedList('inbox', 'My Tasks')
  ..seedList('work', 'Work')
  ..seedList('old', 'Old projects')
  ..seedTask('inbox', 'rename-me', 'Call the plumber', '00000000000001')
  ..seedTask('inbox', 'finish-me', 'Pay rent', '00000000000002')
  ..seedTask('inbox', 'delete-me', 'Cancel gym', '00000000000003')
  ..seedTask('inbox', 'move-me', 'Book flights', '00000000000004')
  ..seedTask('inbox', 'both-edit', 'Draft report', '00000000000005')
  ..seedTask('old', 'old-task', 'Archive photos', '00000000000001');

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_upgrade'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the first sync after upgrading from 1.6.0 pushes every change held '
      'on the device', () async {
    final dataBase = Directory(p.join(tmp.path, 'data'));
    final configBase = Directory(p.join(tmp.path, 'config'));
    final dbFile = dbPathIn(dataBase, env: const {});
    dbFile.parent.createSync(recursive: true);
    final sql = File('test/app/fixtures/1.6.0_read_only.sql');
    final loader = AppDatabase(
      NativeDatabase(
        dbFile,
        setup: (raw) => raw.execute(sql.readAsStringSync()),
      ),
    );
    await loader.customSelect('SELECT 1').get();
    await loader.close();
    configPathIn(configBase, env: const {})
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'sync': {'push_enabled': false, 'auto_sync_on_start': true},
        }),
      );

    final ready =
        await bootstrap(
              dataBase: dataBase,
              configBase: configBase,
              env: const {},
            )
            as BootstrapReady;
    addTearDown(ready.database.close);
    final store = Store(ready.database);
    expect(
      await store.pendingPushCount(),
      11,
      reason: 'precondition: the work held on the device is all still queued',
    );

    final server = _account();
    // While that work sat on the device, another one edited the same task and
    // added a new one.
    await server.patchTask(
      'inbox',
      'both-edit',
      const TaskPatch(title: 'Draft report (theirs)'),
    );
    await server.insertTask('inbox', const NewTask(title: 'From my phone'));

    final runtime = AuthSyncRuntime(
      store: store,
      config: ready.configController,
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      buildClient: (_) => server,
    );
    addTearDown(runtime.dispose);

    Future<Map<String, Task>> tasksIn(String listTitle) async {
      final list = (await server.listTasklists()).singleWhere(
        (l) => l.title == listTitle,
      );
      final items = (await server.listTasks(list.id)).items;
      final byTitle = {for (final t in items) t.title: t};
      expect(byTitle.length, items.length, reason: 'no duplicates');
      return byTitle;
    }

    // The startup auto-sync: the first sync this install runs after upgrading.
    await runtime.restoreAndAutoSync();
    expect(runtime.scheduler.status.lastError, isNull);
    expect(runtime.scheduler.status.lastConflicts, 1);

    // The list rename, deletion and creation all reached Google.
    expect([
      for (final l in await server.listTasklists()) l.title,
    ], unorderedEquals(['My Tasks', 'Office', 'Errands']));
    expect((await tasksIn('Errands')).keys, ['Post parcel']);

    final inbox = await tasksIn('My Tasks');
    expect(inbox['Call the electrician']!.id, 'rename-me');
    expect(inbox['Call the electrician']!.notes, 'Ask about the fuse box');
    expect(inbox['Pay rent']!.status, TaskStatus.completed);
    expect(inbox, isNot(contains('Cancel gym')), reason: 'deleted');
    expect(inbox['Plan party']!.due, '2026-12-01T00:00:00.000Z');
    expect(inbox['Buy candles']!.parent, inbox['Plan party']!.id);
    final topLevel = inbox.values.where((t) => t.parent == null).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    expect(topLevel.first.id, 'move-me', reason: 'the reorder landed');
    expect(inbox, contains('From my phone'));

    // The task edited on both sides: Google's version stays canonical and ours
    // is kept as a conflicted copy, which the next run pushes.
    expect(inbox['Draft report (theirs)']!.id, 'both-edit');
    expect(await store.pendingPushCount(), 1);
    await runtime.refresh();
    expect(
      (await tasksIn('My Tasks')).keys,
      containsAll([
        'Draft report (theirs)',
        'Draft report (mine) (conflicted copy)',
      ]),
    );
    expect(await store.pendingPushCount(), 0);
    expect(runtime.scheduler.status.lastError, isNull);

    // Nothing was lost on the device either.
    final local = <String>[
      for (final list in await store.allLists())
        for (final row in await store.listTasks(list.list.id)) row.task.title,
    ];
    expect(
      local,
      unorderedEquals([
        'Call the electrician',
        'Pay rent',
        'Book flights',
        'Draft report (theirs)',
        'Draft report (mine) (conflicted copy)',
        'Plan party',
        'Buy candles',
        'Post parcel',
        'From my phone',
      ]),
    );
  });
}
