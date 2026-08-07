// Default-list creation — the Dart port of `AppState::ensure_default_list`.
//
// On a fresh, signed-out install the store is empty and there is nothing to
// look at. The bootstrap seeds a single "My Tasks" list as a PENDING CREATE so
// the app opens onto a usable, writable list offline. The title "My Tasks" is
// load-bearing: on the first authenticated pull the reconcile step adopts
// Google's existing "My Tasks" list BY TITLE (its `rehome_target`) instead of
// duplicating it — so this local seed and Google's default converge rather than
// producing two lists.
//
// It runs ONLY when signed out and ONLY when no list exists: an authenticated
// user gets their real lists from sync, and a returning user already has rows,
// so re-seeding would be wrong on both paths.

import '../model/dates.dart' show nowUtcString;
import '../model/task_list.dart';
import '../store/store.dart';
import '../store/stored.dart';
import 'ids.dart';

/// The title Google gives every account's built-in list; the reconcile step
/// keys on it so the local seed and the server default converge (never split).
const String defaultListTitle = 'My Tasks';

/// Ensure a default "My Tasks" list exists when [isAuthenticated] is false and
/// the store holds no lists. No-op otherwise. Returns `true` when it created
/// the seed, `false` when it left the store untouched.
///
/// [newId]/[now] are injectable for deterministic tests; production uses a v4
/// UUID and the ambient clock.
Future<bool> ensureDefaultList(
  Store store, {
  required bool isAuthenticated,
  String Function() newId = newLocalId,
  String Function() now = nowUtcString,
}) async {
  // A signed-in user's lists come from sync; never seed over them.
  if (isAuthenticated) return false;
  final lists = await store.allLists();
  if (lists.isNotEmpty) return false;

  final stamp = now();
  await store.upsertList(
    StoredTaskList(
      list: TaskList(id: newId(), title: defaultListTitle, updated: stamp),
      syncState: SyncState.dirty,
      localUpdated: stamp,
      // Pending create; adopted by title on the first authenticated pull.
      pendingOp: 'create',
    ),
  );
  return true;
}
