// Port of the `ensure_default_list` behavior: a signed-out, empty install is
// seeded with a single "My Tasks" pending-create list so the app opens onto a
// usable, writable list offline. Assertions read the STORE state (the rows
// `all_lists` returns), never which method ran.

import 'package:axiotask/src/app/default_list.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

void main() {
  test(
    'empty + signed out → seeds one "My Tasks" pending-create list',
    () async {
      final store = await freshStore();

      final created = await ensureDefaultList(
        store,
        isAuthenticated: false,
        newId: () => 'local-1',
        now: () => '2026-01-01T00:00:00Z',
      );

      expect(created, isTrue);
      final lists = await store.allLists();
      expect(lists, hasLength(1));
      final seed = lists.single;
      expect(seed.list.title, 'My Tasks');
      expect(seed.list.id, 'local-1');
      // A pending create so the first authed pull adopts Google's "My Tasks" by
      // title (rehome_target) instead of duplicating it.
      expect(seed.syncState, SyncState.dirty);
      expect(seed.pendingOp, 'create');
      expect(seed.list.etag, isNull);
      expect(seed.localOnly, isFalse);
    },
  );

  test(
    'non-empty store → no seeding (returning user keeps their lists)',
    () async {
      final store = await freshStore();
      await store.upsertList(
        StoredTaskList(
          list: const TaskList(
            id: 'L1',
            title: 'Work',
            updated: '2026-01-01T00:00:00Z',
          ),
          syncState: SyncState.clean,
          localUpdated: '2026-01-01T00:00:00Z',
        ),
      );

      final created = await ensureDefaultList(store, isAuthenticated: false);

      expect(created, isFalse);
      final lists = await store.allLists();
      expect(lists, hasLength(1));
      expect(lists.single.list.title, 'Work', reason: 'no "My Tasks" added');
    },
  );

  test('authenticated + empty → no seeding (lists come from sync)', () async {
    final store = await freshStore();

    final created = await ensureDefaultList(store, isAuthenticated: true);

    expect(created, isFalse);
    expect(await store.allLists(), isEmpty);
  });
}
