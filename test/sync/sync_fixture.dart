// Shared fixture for the engine suites under the stable-local-identity model
// (#224). Support library — no `main`, so `flutter test` never runs it.
//
// The suites address rows the way the SERVER does, by the id the fake Google
// minted ('L1', 'r1', 'remote-3'): that is the identity a sync test is actually
// about. The store, though, keys on immutable LOCAL ids and records Google's in
// `remote_id`. These helpers are the ONE place that translation happens, so the
// tests keep reading as "the row the server calls r1".

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';

/// Seed [id]/[title] on the fake server AND the local clean row that mirrors
/// it, pinning the LOCAL list id to the same string.
///
/// Local ids are opaque strings — nothing requires them to differ from
/// Google's — so a suite may pin them equal and go on naming one list by one
/// name on both sides. The pull then resolves the list through its `remote_id`
/// instead of minting a second local row for it. Use plain
/// [FakeTasksApi.seedList] instead wherever the point of the test is a list the
/// device has NOT seen yet.
Future<TaskList> seedSyncedList(
  FakeTasksApi client,
  Store store,
  String id,
  String title,
) async {
  final list = client.seedList(id, title);
  await store.upsertList(
    StoredTaskList(
      list: list,
      syncState: SyncState.clean,
      localUpdated: list.updated,
      remoteId: id,
    ),
  );
  return list;
}

/// The local row the server calls [id] — matched on `remote_id` first, then on
/// the local id itself so an un-pushed row (which has no remote id) is still
/// addressable by the id the test gave it. `null` when there is no such row.
Future<StoredTask?> findByAnyId(Store store, String id) async {
  final byRemote = await store.taskIdsByRemoteId();
  return store.findTaskAny(byRemote[id] ?? id);
}

/// The LOCAL id of the row the server calls [id], or [id] unchanged when
/// nothing carries it as a `remote_id`.
Future<String> localIdOf(Store store, String id) async =>
    (await findByAnyId(store, id))?.task.id ?? id;

/// How the server identifies [row] — its `remote_id` once acknowledged, else
/// its local id. The projection every id-keyed assertion in these suites reads.
String serverId(StoredTask row) => row.remoteId ?? row.task.id;

/// The parent link of [row], named the way the SERVER names it — the parent
/// row's `remote_id` when it has one. The stored link itself is always a local
/// id (#224), so an assertion phrased in server ids has to come through here.
Future<String?> parentServerId(Store store, StoredTask row) async {
  final parent = row.task.parent;
  if (parent == null) return null;
  final parentRow = await store.findTaskAny(parent);
  return parentRow == null ? parent : serverId(parentRow);
}

/// [Store.recordMove], addressed the way the SERVER names rows: the task, its
/// target parent and the sibling it follows are each resolved to their local id
/// first, because `pending_moves` keys on local ids only (#224).
Future<void> recordServerMove(
  Store store,
  String taskId,
  String listId,
  String? parentId,
  String? previousId,
) async => store.recordMove(
  await localIdOf(store, taskId),
  listId,
  parentId == null ? null : await localIdOf(store, parentId),
  previousId == null ? null : await localIdOf(store, previousId),
);
