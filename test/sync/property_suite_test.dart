// Property / invariant tests for sync over RANDOM operation orderings — the
// Dart port of `sync_property_test.rs` (MIGRATION-PLAN §3, §5 T5.10, single-
// device layer). The rest of the sync suite is example-based: it proves a
// specific, chosen interleaving behaves. The bug class that shipped (a create
// that never synced) lives in the interleavings nobody thought to write down. These tests generate random sequences of real user operations — the
// same [Commands] methods the UI calls — against the real store and the real
// sync engine, and assert INVARIANTS ON STATE (local store rows and fake-server
// rows), never "a call happened".
//
// The five invariants, one test each:
//  * eventual push   — pending work drains to zero under repeated healthy runs
//  * convergence     — local == server field-for-field after push + pull
//  * idempotency     — a run after the fixpoint changes nothing
//  * crash safety    — nested creates + in-flight markers yield no duplicates
//  * parent integrity— no child ever points at a parent that isn't there
//
// Plus the RESTART invariant (the undo token dies with the process but the
// tombstone pushes exactly once) and the #145 orphan-adoption pin. The dual-device layer + oracle corpus are T5.11.
//
// ## Operation vocabulary (RFC-009 §J)
//
// The generator covers the whole conflict matrix on both sides of the wire:
// §B/§C edits + completes and their remote twins (which manufacture the 412
// path), §D deletes + remote cascade, §E/§F reorder/demote/promote, §G creates
// + §A pull mirrors, §H cross-list move, §I list ops + their remote twins,
// and the fault-injecting syncs (Flaky/Interleave/Crash/Abort) plus
// process Restart. The harness is MULTI-LIST: tasks are addressed by unique
// TITLE across every list, so the same op sequence touches the same logical
// tasks on every run regardless of the ids the store/server assign.
//
// ## Determinism (no flaky tests)
//
// Three sources of nondeterminism are pinned: (1) a fixed-seed [Random] drives
// the hand-rolled generator, so every run explores the SAME sequences — a
// failure is a real defect, reproducible on the next run; (2) an op refers to a
// task by its position in the harness's own creation order, resolved through a
// unique title, never through the id the store/server assigns; (3) an advancing
// (never wall-clock) [Clock] stamps every write, so timestamps and placeholder
// positions are stable AND strictly increasing (the engine's compare-and-set
// mark-clean relies on local_updated advancing when an edit lands). Local ids
// are a monotonic counter that survives a Restart (a real relaunch never
// re-mints an id already on disk). `AXIOTASK_PROPTEST_CASES` raises the depth
// for a soak; the seed is fixed, so a deeper run explores a strict SUPERSET.

import 'dart:io' show Platform;
import 'dart:math';

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/default_list.dart';
import 'package:axiotask/src/model/dates.dart' show DateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/sync_error.dart' show SyncError;
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// The list the harness starts from, seeded on the server so its id is stable
/// across the whole run (no list-create remap to chase).
const String kList = 'L1';

/// Upper bound on the recovery runs a fixpoint may take. Each healthy run makes
/// progress (push a batch, adopt an orphan), so a sequence that still hasn't
/// settled after this many runs is not "slow" — it is stuck, which is exactly
/// what these tests hunt for.
const int kMaxHealRuns = 16;

/// Sequences explored per invariant on a normal `flutter test`. Sized so the
/// whole file stays well under a minute — a property suite that makes the
/// default test run painful gets skipped, which protects nothing. Deep soaks
/// raise it through `AXIOTASK_PROPTEST_CASES`.
const int kDefaultCases = 24;

/// The fixed seed. A failure here reproduces on the next run, forever.
const int kSeed = 0x5eed;

/// `AXIOTASK_PROPTEST_CASES` overrides the case count for a deep soak. The seed
/// is fixed, so a deeper run explores a strict SUPERSET of the default run.
int casesFor(int def) {
  final v = Platform.environment['AXIOTASK_PROPTEST_CASES'];
  final n = v == null ? null : int.tryParse(v);
  return (n == null || n <= 0) ? def : n;
}

/// An advancing (never wall-clock) clock: each read steps forward one
/// millisecond, so every write gets a distinct, ordered, deterministic
/// timestamp. Placeholder positions (which read the clock) stay distinct and
/// the engine's local_updated compare-and-set stays honest.
Clock advancingClock() {
  var micros = DateTime.utc(2026).microsecondsSinceEpoch;
  return Clock(() {
    micros += 1000;
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  });
}

// ─── Operations ──────────────────────────────────────────────────────────────

/// The op kinds. Indices carried by an [Op] are resolved modulo the number of
/// live tasks/lists at execution time, so every generated value is meaningful.
enum OpKind {
  createTop,
  createSub,
  rename,
  setDue,
  toggle,
  delete,
  reorder,
  moveAfter,
  demote,
  promote,
  moveToList,
  createList,
  renameList,
  deleteList,
  remoteEdit,
  remoteComplete,
  remoteDelete,
  remoteCreate,
  remoteCreateDup,
  remoteDemote,
  remoteRenameList,
  remoteDeleteList,
  sync,
  flakySync,
  interleaveSync,
  crashSync,
  abortSync,
  restart,
}

/// One user-or-system action. [a]/[b] are index/selector bytes; [flag] is the
/// reorder direction.
class Op {
  const Op(this.kind, {this.a = 0, this.b = 0, this.flag = false});

  final OpKind kind;
  final int a;
  final int b;
  final bool flag;

  @override
  String toString() => switch (kind) {
    OpKind.reorder => flag ? 'reorder($a, front)' : 'reorder($a, after $b)',
    OpKind.moveAfter => 'moveAfter($a, $b)',
    OpKind.moveToList => 'moveToList($a, $b)',
    OpKind.setDue => 'setDue($a, $b)',
    OpKind.createList => 'createList',
    OpKind.sync => 'sync',
    OpKind.restart => 'restart',
    _ => '${kind.name}($a)',
  };
}

/// Transient faults only: a permanent rejection would legitimately leave a row
/// dirty forever, a different (already covered) behavior. Mirrors the reference
/// `TRANSIENT` table.
const List<(Method, ApiError)> kTransient = [
  (Method.listTasks, ServerError(503)),
  (Method.insertTask, Network('reset')),
  (Method.patchTask, ServerError(500)),
  (Method.deleteTask, Network('timeout')),
  (Method.moveTask, RateLimited()),
  (Method.listTasklists, ServerError(502)),
  (Method.insertTasklist, Network('reset')),
  (Method.patchTasklist, ServerError(500)),
  (Method.deleteTasklist, RateLimited()),
];

/// The mutating methods whose response a [OpKind.crashSync] loses after the
/// server committed — the at-least-once hazard, generalized past inserts.
const List<Method> kLost = [
  Method.insertTask,
  Method.patchTask,
  Method.deleteTask,
  Method.moveTask,
];

/// The methods a [OpKind.abortSync] fails FATALLY (auth error), varying the
/// abort point across the push.
const List<Method> kFatal = [
  Method.insertTask,
  Method.patchTask,
  Method.deleteTask,
  Method.moveTask,
  Method.patchTasklist,
];

// ─── Harness ───────────────────────────────────────────────────────────────

/// A whole app instance: real store, real command layer, real sync engine,
/// fake Google. [commands]/[engine] are rebuilt by a Restart over the same
/// [store]; the id counter survives (a relaunch never re-mints a disk id).
class Harness {
  Harness._(this.client, this.store, this._db, this.namespace);

  final FakeTasksApi client;
  final Store store;
  final AppDatabase _db;

  /// Prefix on every task/list title this device mints. A lone device uses ''
  /// (titles `t001`/`L001`); the dual-device harness tags its two devices 'a'
  /// and 'b' so their handles stay disjoint on the one shared server. Mirrors
  /// the reference `Harness::on_shared_client` namespace.
  final String namespace;

  late Commands commands;
  late SyncEngine engine;

  /// Every task this harness created, in creation order, identified by its
  /// CURRENT title. Titles are unique per harness, so this is a stable handle
  /// that survives the local→server id remap AND the wholesale id re-creation
  /// of a cross-list move (invariant #4).
  final List<String> names = [];
  int _nextName = 0;

  /// The task id the detail panel currently holds, mirrored so a cross-list
  /// move can re-point it the way the UI does.

  int _idCounter = 0;
  String _newId() => 'local-${++_idCounter}';

  /// Build a fresh app over a server that already holds the [kList] Inbox, then
  /// run the initial sync (pushes the bootstrap "My Tasks", pulls Inbox) so ops
  /// run against a realistic post-first-sync state.
  static Future<Harness> create() async {
    final client = FakeTasksApi();
    client.seedList(kList, 'Inbox');
    return onSharedClient(client, '');
  }

  /// Build one app instance over an ALREADY-SEEDED shared [client], tagging its
  /// task/list handles with [namespace]. The dual-device harness builds two of
  /// these on ONE client (offline interleaving, n:1 fixpoint); a lone device
  /// passes ''. The client is seeded exactly once by the caller — building B
  /// must NOT re-seed the Inbox A already pushed. Its bootstrap "My Tasks" is a
  /// pending create adopted by title on the first pull, so two devices share
  /// one "My Tasks" rather than forking a duplicate. Mirrors the reference
  /// `Harness::on_shared_client`.
  static Future<Harness> onSharedClient(
    FakeTasksApi client,
    String namespace,
  ) async {
    final db = await AppDatabase.openMemory();
    final store = Store(db);
    final h = Harness._(client, store, db, namespace);
    await ensureDefaultList(store, isAuthenticated: false, newId: h._newId);
    h._buildEngine();
    await h.runSync();
    return h;
  }

  void _buildEngine() {
    commands = Commands(store, newId: _newId);
    engine = SyncEngine.withPush(client, store, true, newId: _newId);
  }

  Future<void> dispose() => _db.close();

  String _freshName() {
    _nextName += 1;
    return '${namespace}t${_nextName.toString().padLeft(3, '0')}';
  }

  /// A list title. Distinct namespace from task titles so a list can never
  /// shadow a task handle.
  String _freshListName() {
    _nextName += 1;
    return '${namespace}L${_nextName.toString().padLeft(3, '0')}';
  }

  /// A sync run — asserting the store's structural invariants on the way out
  /// (#269).
  ///
  /// The check runs after EVERY run, failed runs included: a violation is a
  /// corrupt write, and the run that made it is the only place the sequence
  /// that caused it is still visible. Left to converge, the same corruption
  /// surfaces runs later as a duplicate task, a create pushed into a dead list
  /// id, or an orphaned subtree — with nothing left to point at the write.
  Future<SyncOutcome> runSync() async {
    try {
      return await engine.run();
    } finally {
      await store.checkInvariants();
    }
  }

  /// Lists an op may target, in a deterministic order (sorted by TITLE — a list
  /// id is server-assigned or a counter value, so an id order would send the
  /// same op sequence to different lists on different runs). Tombstoned lists
  /// are already absent from [Store.allLists]; local-only lists are excluded —
  /// they never sync, so a task in one could never converge.
  Future<List<StoredTaskList>> lists() async {
    final ls = (await store.allLists()).where((l) => !l.localOnly).toList()
      ..sort((a, b) => a.list.title.compareTo(b.list.title));
    return ls;
  }

  /// Every VISIBLE task row across every list.
  Future<List<StoredTask>> allRows() => store.allTasks();

  /// Live tasks in harness creation order, ACROSS EVERY LIST — a task that moved
  /// lists is the same logical task and keeps its handle. A task the store no
  /// longer holds simply drops out.
  Future<List<StoredTask>> live() async {
    final rows = await allRows();
    final byTitle = <String, StoredTask>{for (final r in rows) r.task.title: r};
    return [
      for (final n in names)
        if (byTitle[n] != null) byTitle[n]!,
    ];
  }

  /// Live tasks the server has actually seen — the only ones a "another device
  /// did X" op can touch.
  Future<List<StoredTask>> pushed() async {
    // A row is only addressable on the wire when BOTH it and the list holding
    // it carry a remote id — a cross-list move can park an acknowledged row in
    // a local-only list, which the server has never heard of (#224).
    final listRemote = {
      for (final l in await store.allLists()) l.list.id: l.remoteId,
    };
    return [
      for (final t in await live())
        if (t.remoteId != null &&
            listRemote[t.listId] != null &&
            t.syncState != SyncState.deleted)
          t,
    ];
  }

  /// The LOCAL id of the shared Inbox — [kList] is the id GOOGLE gives it, and
  /// the store mints its own (#224).
  Future<String> inbox() async =>
      (await store.allLists()).firstWhere((l) => l.remoteId == kList).list.id;

  /// The WIRE ids of a row the server has seen: `(remote list id, remote task
  /// id)`. Local ids are immutable and Google has never heard of them (#224),
  /// so every "another device did X" op addresses the server through this.
  Future<(String, String)> wire(StoredTask t) async =>
      ((await store.listRemoteId(t.listId))!, t.remoteId!);

  /// Lists the server has actually seen.
  Future<List<StoredTaskList>> pushedLists() async => [
    for (final l in await lists())
      if (l.remoteId != null) l,
  ];

  /// Create a top-level task in a named list; returns its title, the handle
  /// every later op addresses it by.
  Future<String> createTopIn(String listId) async {
    final title = _freshName();
    await commands.createTask(listId: listId, title: title);
    names.add(title);
    return title;
  }

  /// Whether [id] has any child anywhere in the store.
  Future<bool> hasChildren(String id) async =>
      (await allRows()).any((r) => r.task.parent == id);

  // One arm per operation.
  Future<void> apply(Op op) async {
    switch (op.kind) {
      case OpKind.createTop:
        final ls = await lists();
        final list = _pick(ls, op.a);
        if (list == null) return;
        await createTopIn(list.list.id);
      case OpKind.createSub:
        final tops = [
          for (final t in await live())
            if (t.task.parent == null) t,
        ];
        final parent = _pick(tops, op.a);
        if (parent == null) return;
        final title = _freshName();
        await commands.createTask(
          listId: parent.listId,
          parentId: parent.task.id,
          title: title,
        );
        names.add(title);
      case OpKind.rename:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        final old = t.task.title;
        final fresh = _freshName();
        await commands.renameTask(t.task.id, fresh);
        final slot = names.indexOf(old);
        if (slot >= 0) names[slot] = fresh;
      case OpKind.setDue:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        await commands.setDue(t.task.id, DateMove.values[op.b % 5]);
      case OpKind.toggle:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        await commands.toggleComplete(t.task.id);
      case OpKind.delete:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        await commands.deleteTask(t.task.id);
      case OpKind.reorder:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        // An anchored reorder (#202): drop t after ANOTHER sibling (same parent
        // + list, position order) chosen by op.b — a MULTI-SLOT target, not just
        // an adjacent step — or at the FRONT when the flag is set. Resolving the
        // anchor id against the store's own order is exactly what the list view
        // now feeds the command.
        final sibs =
            (await allRows())
                .where(
                  (s) => s.listId == t.listId && s.task.parent == t.task.parent,
                )
                .toList()
              ..sort((a, b) => a.task.position.compareTo(b.task.position));
        if (op.flag) {
          await commands.reorderTaskAfter(t.task.id, null); // to the front
        } else {
          final others = sibs.where((s) => s.task.id != t.task.id).toList();
          final anchor = _pick(others, op.b);
          if (anchor == null) return;
          await commands.reorderTaskAfter(t.task.id, anchor.task.id);
        }
      case OpKind.moveAfter:
        final liveNow = await live();
        final t = _pick(liveNow, op.a);
        final anchor = _pick(liveNow, op.b);
        if (t == null || anchor == null) return;
        if (t.task.id == anchor.task.id || t.listId != anchor.listId) return;
        final newParent = anchor.task.parent;
        // Subtasks are strictly one level: adopt a parent only if childless and
        // never become your own descendant's child.
        if (newParent == t.task.id) return;
        if (newParent != null && await hasChildren(t.task.id)) return;
        await commands.moveTask(
          t.task.id,
          parentId: newParent,
          previousId: anchor.task.id,
        );
      case OpKind.demote:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        // Only a childless top-level row can be demoted; anything else would
        // nest a third level, which the command refuses (invariant #1, §F).
        if (t.task.parent != null || await hasChildren(t.task.id)) return;
        final rows = await store.listTasks(t.listId);
        final tops = [
          for (final r in rows)
            if (r.task.parent == null) r,
        ];
        final here = tops.indexWhere((r) => r.task.id == t.task.id);
        if (here <= 0) return; // absent, or already first: nothing above.
        await commands.moveTask(t.task.id, parentId: tops[here - 1].task.id);
      case OpKind.promote:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        final parentId = t.task.parent;
        if (parentId == null) return; // already top level
        await commands.moveTask(t.task.id, previousId: parentId);
      case OpKind.moveToList:
        final t = _pick(await live(), op.a);
        if (t == null) return;
        final targets = [
          for (final l in await lists())
            if (l.list.id != t.listId) l,
        ];
        final target = _pick(targets, op.b);
        if (target == null) return;
        await commands.moveTaskToList(t.task.id, target.list.id);
      case OpKind.createList:
        await commands.createList(_freshListName());
      case OpKind.renameList:
        final l = _pick(await lists(), op.a);
        if (l == null) return;
        await commands.renameList(l.list.id, _freshListName());
      case OpKind.deleteList:
        final ls = await lists();
        // Keep at least one syncable list standing: with none left every later
        // op is a no-op, which explores nothing.
        if (ls.length < 2) return;
        final l = _pick(ls, op.a);
        if (l == null) return;
        await commands.deleteList(l.list.id);
      case OpKind.remoteEdit:
        final t = _pick(await pushed(), op.a);
        if (t == null) return;
        // No If-Match: another device's edit always lands, and OUR next push is
        // the one that meets the 412 (§B).
        try {
          final (listId, taskId) = await wire(t);
          await client.patchTask(
            listId,
            taskId,
            TaskPatch(notes: _freshName()),
          );
        } on ApiError {
          // Racing a local delete of the same row is a benign no-op.
        }
      case OpKind.remoteComplete:
        final t = _pick(await pushed(), op.a);
        if (t == null) return;
        final status = t.task.status == TaskStatus.completed
            ? TaskStatus.needsAction
            : TaskStatus.completed;
        try {
          final (listId, taskId) = await wire(t);
          await client.patchTask(listId, taskId, TaskPatch(status: status));
        } on ApiError {
          // ignore: the row may have gone locally.
        }
      case OpKind.remoteDelete:
        final t = _pick(await pushed(), op.a);
        if (t == null) return;
        // Google cascades to subtasks on its side (#106 probe 5).
        try {
          final (listId, taskId) = await wire(t);
          await client.deleteTask(listId, taskId);
        } on ApiError {
          // already gone.
        }
      case OpKind.remoteCreate:
        final l = _pick(await pushedLists(), op.a);
        if (l == null) return;
        final title = _freshName();
        try {
          await client.insertTask(l.remoteId!, NewTask(title: title));
          // A row we never created locally is still a row the pull must land.
          names.add(title);
        } on ApiError {
          // list vanished mid-op; leave the title untracked.
        }
      case OpKind.remoteCreateDup:
        // Reuse a live SUBTASK's title as a foreign TOP-LEVEL row — a different
        // parent identity. When our subtask is mid-flight, the next recovery
        // must NOT adopt this look-alike (#145). Untracked on purpose (it
        // duplicates a title); id-keyed convergence still covers it.
        final subs = [
          for (final t in await live())
            if (t.task.parent != null) t,
        ];
        final t = _pick(subs, op.a);
        if (t == null) return;
        // The look-alike is inserted into the list the subtask lives in; the
        // subtask itself may still be unpushed, so only the LIST needs a
        // remote id here.
        final listRemote = await store.listRemoteId(t.listId);
        if (listRemote == null) return;
        try {
          await client.insertTask(listRemote, NewTask(title: t.task.title));
        } on ApiError {
          // list vanished; ignore.
        }
      case OpKind.remoteDemote:
        // Another device demotes a pushed top-level task under a pushed
        // top-level sibling on the server. If the task already has a subtask,
        // the server holds a third level — the §F/§G residual D7 repairs.
        final pushedNow = await pushed();
        final t = _pick(pushedNow, op.a);
        if (t == null || t.task.parent != null) return;
        final siblings = [
          for (final r in pushedNow)
            if (r.listId == t.listId &&
                r.task.parent == null &&
                r.task.id != t.task.id)
              r,
        ];
        final parent = _pick(siblings, op.a);
        if (parent == null) return;
        try {
          final (listId, taskId) = await wire(t);
          await client.moveTask(listId, taskId, parent: parent.remoteId!);
        } on ApiError {
          // ignore.
        }
      case OpKind.remoteRenameList:
        final l = _pick(await pushedLists(), op.a);
        if (l == null) return;
        try {
          await client.patchTasklist(l.remoteId!, _freshListName());
        } on ApiError {
          // ignore.
        }
      case OpKind.remoteDeleteList:
        if ((await lists()).length < 2) return;
        final l = _pick(await pushedLists(), op.a);
        if (l == null) return;
        try {
          await client.deleteTasklist(l.remoteId!);
        } on ApiError {
          // ignore.
        }
      case OpKind.sync:
        await runSync();
      case OpKind.flakySync:
        final (m, e) = kTransient[op.a % kTransient.length];
        client.failNext(m, () => e);
        await runSync(); // a transient leaves the run Ok, one row dirty.
      case OpKind.interleaveSync:
        await _interleaveSync(op.a);
      case OpKind.crashSync:
        // Lose the response of ONE mutating call after the server commits it.
        client.commitThenFailNext(kLost[op.a % kLost.length]);
        await runSync();
      case OpKind.abortSync:
        // A FATAL auth error mid-push: run_sync returns Err, the run is left
        // partly applied. Tolerate the error (that IS the state being tested),
        // then disarm — the fatal condition lasts one run.
        client.failNext(
          kFatal[op.a % kFatal.length],
          () => const Unauthorized(),
        );
        try {
          await runSync();
        } on SyncError {
          // expected partial-push abort.
        }
        client.clearFaults();
      case OpKind.restart:
        // Relaunch over the same store: any undo token dies with the process;
        // the store's pending work is all that survives.
        _buildEngine();
    }
  }

  /// [OpKind.interleaveSync]: another device races us WITHIN one run. The
  /// on_call hook fires on the pull's first `list_tasks` — after our push has
  /// committed — so the injected mutation lands between the engine's own calls,
  /// which no op-boundary event can express.
  Future<void> _interleaveSync(int k) async {
    final pushedNow = await pushed();
    final listsNow = await pushedLists();
    if (pushedNow.isEmpty || listsNow.isEmpty) {
      await runSync(); // nothing on the server to race against yet.
      return;
    }
    if (k % 2 == 0) {
      // A remote DELETE of a pushed task, fired on the FIRST pull list_tasks. A
      // delete of an already-gone id is a safe no-op.
      final victim = pushedNow[k % pushedNow.length];
      final listId = victim.listId;
      final id = victim.task.id;
      var listCalls = 0;
      client.setOnCall((c, m) {
        if (m == Method.listTasks) {
          listCalls += 1;
          if (listCalls == 1) c.deleteTaskFromState(listId, id);
        }
      });
    } else {
      // A remote CREATE into a pushed list, landing mid-pull. It joins the
      // handle set so the oracle tracks that the pull actually lands it.
      final listId = listsNow[k % listsNow.length].list.id;
      final title = _freshName();
      names.add(title);
      final id = 'il-$title';
      var listCalls = 0;
      client.setOnCall((c, m) {
        if (m == Method.listTasks) {
          listCalls += 1;
          if (listCalls == 1) c.seedTaskIfListExists(listId, id, title, '1');
        }
      });
    }
    try {
      await runSync();
    } finally {
      // Disarm before anything else can trip the (now inert) hook.
      client.clearOnCall();
    }
  }

  Future<void> applyAll(List<Op> ops) async {
    for (final op in ops) {
      await apply(op);
    }
  }

  /// Drop every fault, then sync until nothing changes. Returns the number of
  /// runs the fixpoint took.
  Future<int> heal() async {
    client.clearFaults();
    client.clearOnCall();
    for (var run = 1; run <= kMaxHealRuns; run++) {
      final out = await runSync();
      if (isNoop(out)) return run;
    }
    fail(
      'no sync fixpoint after $kMaxHealRuns healthy runs — '
      'pending=${await store.pendingPushCount()}\n${await dump()}',
    );
  }

  // ── State readers ──────────────────────────────────────────────────────────

  Future<List<Task>> serverTasks(String listId) async {
    final all = <Task>[];
    String? token;
    do {
      final page = await client.listTasks(listId, pageToken: token);
      all.addAll(page.items);
      token = page.nextPageToken;
    } while (token != null);
    return all;
  }

  /// Every local task row across every list, as comparable records — the
  /// ORACLE EXPORT PROJECTION.
  ///
  /// The store keys on immutable LOCAL ids and holds Google's in `remote_id`
  /// (#224), while the server obviously keys on Google's. So the export
  /// projects `id := remote_id ?? id` for the row, its list and its parent:
  /// a row the server has acknowledged compares under Google's id (the state
  /// comparison the oracle exists to make), and one it has never seen keeps its
  /// local id — which the server side simply does not have, exactly as before.
  Future<List<Row>> localRows() async {
    final rows = await allRows();
    final remoteTaskId = <String, String>{
      for (final r in rows)
        if (r.remoteId != null) r.task.id: r.remoteId!,
    };
    final remoteListId = <String, String>{
      for (final l in await store.allLists())
        if (l.remoteId != null) l.list.id: l.remoteId!,
    };
    String? exported(String? localId) =>
        localId == null ? null : (remoteTaskId[localId] ?? localId);
    final out = [
      for (final t in rows)
        Row.ofTask(
          remoteListId[t.listId] ?? t.listId,
          t.task,
          id: exported(t.task.id)!,
          parent: exported(t.task.parent),
        ),
    ];
    out.sort();
    return out;
  }

  Future<List<Row>> serverRows() async {
    final out = <Row>[];
    for (final l in await client.listTasklists()) {
      for (final t in await serverTasks(l.id)) {
        out.add(Row.ofTask(l.id, t));
      }
    }
    out.sort();
    return out;
  }

  /// Full local state, including sync metadata — the snapshot idempotency
  /// compares.
  Future<String> dump() async {
    final b = StringBuffer();
    final lists = (await store.allLists())
      ..sort((a, b) => a.list.id.compareTo(b.list.id));
    for (final l in lists) {
      b.writeln(
        "LIST ${l.list.id} '${l.list.title}' etag=${l.list.etag} "
        'state=${l.syncState.name} op=${l.pendingOp} localOnly=${l.localOnly}',
      );
      final tasks = await store.listTasks(l.list.id)
        ..sort((a, b) => a.task.id.compareTo(b.task.id));
      for (final t in tasks) {
        b.writeln(
          '  TASK ${t.task.id} parent=${t.task.parent} '
          "'${t.task.title}' due=${t.task.due} status=${t.task.status.name} "
          'etag=${t.task.etag} pos=${t.task.position} '
          'state=${t.syncState.name} op=${t.pendingOp}',
        );
      }
    }
    final moves = await store.pendingMoves()
      ..sort((a, b) => a.taskId.compareTo(b.taskId));
    for (final m in moves) {
      b.writeln('  MOVE ${m.taskId} parent=${m.parentId} prev=${m.previousId}');
    }
    for (final (local, list) in await store.inflightCreates()) {
      b.writeln('  INFLIGHT $local in $list');
    }
    return b.toString();
  }
}

/// A task reduced to the fields that must agree between the local cache and
/// Google. `position` is deliberately excluded (the move endpoint returns a
/// fresh etag pull then skips, so the opaque position stays server-authoritative
/// and is only re-adopted on a fresh sync). Single-device local and server
/// share ids after a push, so `id` IS compared here — the dual-device oracle
/// (T5.11) is the one that excludes it.
class Row implements Comparable<Row> {
  Row({
    required this.listId,
    required this.id,
    required this.parent,
    required this.title,
    required this.notes,
    required this.due,
    required this.completed,
  });

  /// Project one task into a comparable row. [id] and [parent] default to the
  /// task's own (the server side, where they ARE Google's ids); the local side
  /// overrides them with the exported `remote_id ?? id` projection (#224).
  factory Row.ofTask(String listId, Task t, {String? id, String? parent}) =>
      Row(
        listId: listId,
        id: id ?? t.id,
        parent: parent ?? t.parent,
        title: t.title,
        // Google returns cleared notes as absent; "" and null are the same
        // user-visible state.
        notes: (t.notes == null || t.notes!.isEmpty) ? null : t.notes,
        due: t.due == null ? null : normalizeDue(t.due!),
        completed: t.status == TaskStatus.completed,
      );

  final String listId;
  final String id;
  final String? parent;
  final String title;
  final String? notes;
  final String? due;
  final bool completed;

  String get _key => '$listId${String.fromCharCode(0)}$id';

  @override
  int compareTo(Row other) => _key.compareTo(other._key);

  @override
  bool operator ==(Object other) =>
      other is Row &&
      other.listId == listId &&
      other.id == id &&
      other.parent == parent &&
      other.title == title &&
      other.notes == notes &&
      other.due == due &&
      other.completed == completed;

  @override
  int get hashCode =>
      Object.hash(listId, id, parent, title, notes, due, completed);

  @override
  String toString() =>
      'Row($listId/$id parent=$parent "$title" notes=$notes due=$due '
      'done=$completed)';
}

/// Pick the [i]-th element modulo the length; `null` when empty.
T? _pick<T>(List<T> items, int i) =>
    items.isEmpty ? null : items[i % items.length];

/// A run that changed nothing, locally or remotely.
bool isNoop(SyncOutcome o) =>
    o.pulled == 0 &&
    o.pushed == 0 &&
    o.conflicts == 0 &&
    o.deleted == 0 &&
    o.errors == 0 &&
    !o.listsChanged;

// ─── Universal structural invariants ─────────────────────────────────────────

/// No child ever points at a parent that isn't in the store, and the tree is
/// never deeper than one level (subtasks are strictly one level).
Future<void> assertParentIntegrity(Harness h, String ctx) async {
  for (final l in await h.store.allLists()) {
    for (final t in await h.store.listTasks(l.list.id)) {
      final p = t.task.parent;
      if (p == null) continue;
      // find_task_any on purpose: a parent whose delete hasn't pushed yet is a
      // TOMBSTONE — hidden from every view, but still a real row. What must
      // never happen is a pointer at nothing at all.
      final parent = await h.store.findTaskAny(p);
      if (parent == null) {
        fail(
          '$ctx: task ${t.task.id} points at missing parent $p\n${await h.dump()}',
        );
      }
      expect(
        parent.task.parent,
        isNull,
        reason:
            '$ctx: task ${t.task.id} is nested two levels deep (parent $p itself '
            'has a parent)\n${await h.dump()}',
      );
    }
  }
}

/// After a fixpoint there are no tombstones left, so every visible task's parent
/// must be visible too — nothing stranded under a deleted row.
Future<void> assertNoStrandedChildren(Harness h, String ctx) async {
  for (final l in await h.store.allLists()) {
    final tasks = await h.store.listTasks(l.list.id);
    final visible = {for (final t in tasks) t.task.id};
    for (final t in tasks) {
      final p = t.task.parent;
      if (p != null) {
        expect(
          visible.contains(p),
          isTrue,
          reason:
              '$ctx: task ${t.task.id} is stranded under invisible parent $p\n'
              '${await h.dump()}',
        );
      }
    }
  }
}

/// Schema invariant (#134/#139): a `clean` row carries no base snapshot. base_*
/// is captured only while a row is dirty / a create is in flight, and cleared
/// the moment the row agrees with the server again.
Future<void> assertBaseNullWhenClean(Harness h, String ctx) async {
  for (final t in await h.allRows()) {
    if (t.syncState == SyncState.clean) {
      expect(
        await h.store.baseSnapshot(t.task.id),
        isNull,
        reason:
            '$ctx: clean task ${t.task.id} still carries a base snapshot\n'
            '${await h.dump()}',
      );
    }
  }
}

Future<void> assertConverged(Harness h, String ctx) async {
  final local = await h.localRows();
  final server = await h.serverRows();
  expect(
    local,
    server,
    reason: '$ctx: local and server diverge\nlocal state:\n${await h.dump()}',
  );
}

// ─── Generator ───────────────────────────────────────────────────────────────

/// One weighted entry in the op strategy. Public so the dual-device layer
/// (dual_device.dart) can build its own local-mutation table.
class OpWeight {
  const OpWeight(this.weight, this.build);
  final int weight;
  final Op Function(Random) build;
}

/// Short local alias for the many entries in the op tables below.
typedef _W = OpWeight;

/// A generator index byte (0..255), resolved modulo the live set at exec time.
/// Public alias reused by the dual-device generator.
int opByte(Random r) => r.nextInt(256);

int _b(Random r) => opByte(r);

/// Draw one op from a weighted [table]. Public so the dual-device layer can
/// draw from both the shared any-op mix ([drawAnyOp]) and its own table.
Op drawFrom(Random r, List<OpWeight> table) {
  final total = table.fold<int>(0, (s, e) => s + e.weight);
  var x = r.nextInt(total);
  for (final e in table) {
    if (x < e.weight) return e.build(r);
    x -= e.weight;
  }
  return table.last.build(r);
}

Op _draw(Random r, List<OpWeight> table) => drawFrom(r, table);

/// Draw one op from the full any-op mix — a single interleaved step of a
/// dual-device sequence is exactly this on one of the two devices.
Op drawAnyOp(Random r) => drawFrom(r, _anyOpTable);

/// The full op mix. Creates are weighted up so sequences actually build a tree
/// to mutate; syncs are frequent so pushes and pulls interleave with edits.
/// Mirrors the reference `any_op` weights.
final List<_W> _anyOpTable = [
  _W(6, (r) => Op(OpKind.createTop, a: _b(r))),
  _W(4, (r) => Op(OpKind.createSub, a: _b(r))),
  _W(3, (r) => Op(OpKind.rename, a: _b(r))),
  _W(3, (r) => Op(OpKind.setDue, a: _b(r), b: _b(r))),
  _W(3, (r) => Op(OpKind.toggle, a: _b(r))),
  _W(2, (r) => Op(OpKind.delete, a: _b(r))),
  _W(2, (r) => Op(OpKind.reorder, a: _b(r), b: _b(r), flag: r.nextBool())),
  _W(2, (r) => Op(OpKind.moveAfter, a: _b(r), b: _b(r))),
  _W(2, (r) => Op(OpKind.demote, a: _b(r))),
  _W(2, (r) => Op(OpKind.promote, a: _b(r))),
  _W(2, (r) => Op(OpKind.moveToList, a: _b(r), b: _b(r))),
  _W(2, (r) => Op(OpKind.createList)),
  _W(1, (r) => Op(OpKind.renameList, a: _b(r))),
  _W(1, (r) => Op(OpKind.deleteList, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteEdit, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteComplete, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteDelete, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteCreate, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteCreateDup, a: _b(r))),
  _W(2, (r) => Op(OpKind.remoteDemote, a: _b(r))),
  _W(1, (r) => Op(OpKind.remoteRenameList, a: _b(r))),
  _W(1, (r) => Op(OpKind.remoteDeleteList, a: _b(r))),
  _W(5, (r) => Op(OpKind.sync)),
  _W(3, (r) => Op(OpKind.flakySync, a: _b(r))),
  _W(2, (r) => Op(OpKind.interleaveSync, a: _b(r))),
  _W(1, (r) => Op(OpKind.crashSync, a: _b(r))),
  _W(1, (r) => Op(OpKind.abortSync, a: _b(r))),
  _W(1, (r) => Op(OpKind.restart)),
];

/// Creates and subtask creates only, with crash-y syncs — the shape the
/// crash-safety invariant is about. Cross-list moves join it because a move IS a
/// create family (§H). Edits ride along so the generator explores an edit made
/// DURING the in-flight window (#122). Mirrors the reference `crash_ops`.
final List<_W> _crashOpTable = [
  _W(5, (r) => Op(OpKind.createTop, a: _b(r))),
  _W(5, (r) => Op(OpKind.createSub, a: _b(r))),
  _W(3, (r) => Op(OpKind.rename, a: _b(r))),
  _W(2, (r) => Op(OpKind.toggle, a: _b(r))),
  _W(2, (r) => Op(OpKind.setDue, a: _b(r), b: _b(r))),
  _W(2, (r) => Op(OpKind.moveToList, a: _b(r), b: _b(r))),
  _W(1, (r) => Op(OpKind.createList)),
  // The crash is deliberately the LOST-INSERT one (crashSync selecting
  // Method.insertTask): "a crashed create never duplicates" is an exact title
  // set. A lost PATCH forks a conflicted copy (an extra title by design),
  // covered by the general convergence properties instead.
  _W(3, (r) => Op(OpKind.crashSync)), // a==0 → insertTask
  _W(2, (r) => Op(OpKind.sync)),
  _W(2, (r) => Op(OpKind.flakySync, a: _b(r))),
];

List<Op> _genSeq(Random r, List<_W> table, int min, int span) {
  final n = min + r.nextInt(span);
  return [for (var i = 0; i < n; i++) _draw(r, table)];
}

List<Op> _anyOps(Random r) => _genSeq(r, _anyOpTable, 1, 39);
List<Op> _crashOps(Random r) => _genSeq(r, _crashOpTable, 2, 16);

/// Run [test] over [cases] freshly generated sequences from [gen], each against
/// a fresh harness under an advancing clock, disposed after. A failure prints
/// the exact sequence, which reproduces at the fixed seed forever.
Future<void> check(
  int cases,
  List<Op> Function(Random) gen,
  Future<void> Function(Harness, List<Op>) body,
) async {
  final rng = Random(kSeed);
  for (var i = 0; i < cases; i++) {
    final ops = gen(rng);
    await withClock(advancingClock(), () async {
      final h = await Harness.create();
      try {
        await body(h, ops);
      } finally {
        await h.dispose();
      }
    });
  }
}

void main() {
  final cases = casesFor(kDefaultCases);

  // ─── The six invariants ────────────────────────────────────────────────────

  test('eventual push drains all pending work', () async {
    await check(cases, _anyOps, (h, ops) async {
      await h.applyAll(ops);
      await h.heal();
      expect(
        await h.store.pendingPushCount(),
        0,
        reason: 'pending work never drained for $ops\n${await h.dump()}',
      );
      expect(
        await h.store.pendingMoves(),
        isEmpty,
        reason: 'move intents left over for $ops\n${await h.dump()}',
      );
      expect(
        await h.store.inflightCreates(),
        isEmpty,
        reason: 'in-flight markers left over for $ops\n${await h.dump()}',
      );
    });
  });

  test('local converges with server', () async {
    await check(cases, _anyOps, (h, ops) async {
      await h.applyAll(ops);
      await h.heal();
      await assertConverged(h, 'after $ops');
      await assertParentIntegrity(h, 'after convergence');
      await assertBaseNullWhenClean(h, 'after convergence');
    });
  });

  test('sync after fixpoint is a no-op', () async {
    await check(cases, _anyOps, (h, ops) async {
      await h.applyAll(ops);
      await h.heal();
      final before = await h.dump();
      final out = await h.runSync();
      expect(
        isNoop(out),
        isTrue,
        reason: 'extra run was not a no-op for $ops\n$before',
      );
      expect(
        await h.dump(),
        before,
        reason: 'extra run mutated the store for $ops',
      );
    });
  });

  test('crashed creates never duplicate', () async {
    await check(cases, _crashOps, (h, ops) async {
      await h.applyAll(ops);
      await h.heal();

      final want = (h.names.toSet().toList())..sort();
      final server = [for (final r in await h.serverRows()) r.title]..sort();
      final local = [for (final t in await h.allRows()) t.task.title]..sort();

      expect(
        server,
        want,
        reason:
            'server task set wrong after crashes for $ops\n${await h.dump()}',
      );
      expect(
        local,
        want,
        reason:
            'local task set wrong after crashes for $ops\n${await h.dump()}',
      );
      await assertParentIntegrity(h, 'after crash recovery');
      await assertBaseNullWhenClean(h, 'after crash recovery');
    });
  });

  test('parent integrity under paged and partial pulls', () async {
    await check(cases, _anyOps, (h, ops) async {
      // Small pages + a dropped page force the detach/relink path.
      h.client.setPageSize(2);
      await h.applyAll(ops);
      h.client.failListTasksPage(1, () => const ServerError(503));
      await h.runSync();
      await assertParentIntegrity(h, 'immediately after a partial pull');

      await h.heal();
      await assertParentIntegrity(h, 'after a complete pull');
      await assertNoStrandedChildren(h, 'after a complete pull');
      await assertConverged(h, 'parent relink, $ops');
    });
  });

  // ─── #145 orphan adoption (deterministic) ──────────────────────────────────

  test('orphan adoption never claims a foreign parent', () async {
    await withClock(advancingClock(), () async {
      final h = await Harness.create();
      try {
        // Two synced top-level parents in the same list.
        await h.apply(const Op(OpKind.createTop, a: 0)); // t001 = P1
        await h.apply(const Op(OpKind.createTop, a: 0)); // t002 = P2
        await h.apply(const Op(OpKind.sync));
        // The server names P1 by ITS id; the store names it by the local one.
        final p1Remote = (await h.live())
            .firstWhere((t) => t.task.title == 't001')
            .remoteId!;

        // A subtask under P1 whose insert is lost pre-commit → in-flight,
        // nothing committed server-side.
        await h.apply(const Op(OpKind.createSub, a: 0)); // t003 under P1
        await h.apply(
          const Op(OpKind.flakySync, a: 1),
        ); // insert fails pre-commit
        // Another device inserts an identical-content row TOP-LEVEL.
        await h.apply(const Op(OpKind.remoteCreateDup, a: 0));

        await h.heal();

        final server = await h.serverRows();
        final ours = server
            .where((r) => r.title == 't003' && r.parent == p1Remote)
            .length;
        final foreign = server
            .where((r) => r.title == 't003' && r.parent == null)
            .length;
        expect(
          ours,
          1,
          reason:
              'our subtask must land under P1, not be swallowed by the foreign '
              'row\n${await h.dump()}',
        );
        expect(
          foreign,
          1,
          reason:
              'the foreign top-level look-alike must survive as its own row\n'
              '${await h.dump()}',
        );
        await assertConverged(h, 'after #145 recovery');
        await assertParentIntegrity(h, 'after #145 recovery');
      } finally {
        await h.dispose();
      }
    });
  });

  // ─── Restart (deterministic) ───────────────────────────────────────────────

  test(
    'restart kills the undo token and pushes the delete exactly once',
    () async {
      await withClock(advancingClock(), () async {
        final h = await Harness.create();
        try {
          await h.apply(const Op(OpKind.createTop, a: 0)); // t001
          await h.apply(const Op(OpKind.sync)); // push it to the server.

          final t = (await h.pushed()).firstWhere(
            (t) => t.task.title == 't001',
          );
          final id = t.task.id;
          final remoteId = t.remoteId!;

          // Delete it: the command tombstones the row and returns an undo token.
          // The delete has NOT pushed — the server still holds t001.
          final token = await h.commands.deleteTask(id);
          expect(
            (await h.serverRows()).any((r) => r.id == remoteId),
            isTrue,
            reason: 'the server must still hold t001 before the delete pushes',
          );
          final deletesBefore = h.client.callCount(Method.deleteTask);

          // Process death: the undo token dies with the frontend. Model it by
          // dropping the token and never calling undoDelete.
          await h.apply(const Op(OpKind.restart));
          expect(token, isNotNull); // held only to model "the frontend had it".

          // The surviving tombstone is all that drives the delete now.
          await h.heal();

          expect(
            h.client.callCount(Method.deleteTask),
            deletesBefore + 1,
            reason:
                'the surviving tombstone must push its delete exactly once\n'
                '${await h.dump()}',
          );
          expect(
            (await h.serverRows()).any((r) => r.id == remoteId),
            isFalse,
            reason:
                't001 must be deleted on the server after the restart\n'
                '${await h.dump()}',
          );
          expect(
            await h.store.findTaskAny(id),
            isNull,
            reason:
                'the local tombstone must be cleared once the delete pushes\n'
                '${await h.dump()}',
          );
          await assertConverged(h, 'after restart pushes the delete');

          // And never again: a further run neither re-pushes nor resurrects.
          final out = await h.runSync();
          expect(
            isNoop(out),
            isTrue,
            reason:
                'a post-drain sync re-touched the deleted row: $out\n'
                '${await h.dump()}',
          );
          expect(
            h.client.callCount(Method.deleteTask),
            deletesBefore + 1,
            reason: 'the delete must never push a second time',
          );
        } finally {
          await h.dispose();
        }
      });
    },
  );
}
