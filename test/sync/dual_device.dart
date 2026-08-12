// Dual-device layer + oracle-corpus support for the sync property suite
// (MIGRATION-PLAN §3, §5 T5.11). This is a SUPPORT library, not a test entry
// point — it has no `main`, so `flutter test` never runs it directly. The
// dual-device property tests live in `dual_device_test.dart` and the oracle
// corpus replay in `oracle_replay_test.dart`; both import from here.
//
// ## What the single-device suite cannot see
//
// `property_suite_test.dart` proves one app instance stays consistent with one
// server. The bug class it is blind to is the CROSSING: two devices editing the
// same shared row offline, reconnecting in whatever order the generator drew,
// and having to converge. A dropped pull, a phantom local row, or a row wedged
// dirty on ONE device is invisible to a lone-engine soak — it only surfaces
// when a second device holds the same server row and the two must agree.
//
// ## The n:1 fixpoint oracle
//
// Two whole app instances — separate stores and sync engines — over ONE shared
// fake Google. The invariant that makes the oracle sound: whatever the server
// converges to, BOTH devices pull it, so a correct pair each mirrors the server
// field-for-field, and therefore each other. `assertDualConverged` checks
// `A == server` and `B == server` (id-keyed, single shared server), which
// implies `A == B == server`. `assertDualCanonicalAgree` adds the CROSS-
// IMPLEMENTATION comparator the oracle needs: a title-keyed canonical dump with
// ids/etags/positions excluded, so two INDEPENDENT engines (Dart-vs-Dart here,
// Dart-vs-Rust once the oracle binary exists) can be compared even though their
// call-order-dependent ids can never match.
//
// ## Determinism
//
// Same discipline as the single-device suite: a fixed-seed [Random] drives the
// hand-rolled dual generator, tasks are addressed by unique namespaced title
// (device 'a' mints `at001`, device 'b' `bt001`), and an advancing (never
// wall-clock) clock stamps every write. A failure reproduces on the next run
// forever, and persists to a JSON-lines corpus replayable from either side.

import 'dart:convert';
import 'dart:math';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/dates.dart' show normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'property_suite_test.dart';

/// Rounds the two-device heal may take before the shared fixpoint. Each round
/// drains A then B to their own fixpoints; the two can ping-pong (A's drain
/// advances the server under B, whose drain advances it back under A) for a few
/// rounds before both settle. A pair still not quiescent after this many rounds
/// is not "slow" — it is stuck, which is exactly what this hunts for. Mirrors
/// the reference `MAX_DUAL_ROUNDS`.
const int kMaxDualRounds = 16;

/// Which of the two devices an op targets.
enum Side {
  a,
  b;

  Side get other => this == Side.a ? Side.b : Side.a;
}

/// One step of a two-device interleaving.
///
/// * [DualOp.step] — apply a single [Op] to one device. Syncs are ordinary
///   `Op.sync`/`flakySync`/`crashSync` values, so the two devices' pushes and
///   pulls land against the one shared server in whatever order the generator
///   drew — the interleaving nobody writes down by hand.
/// * [DualOp.offline] — one device goes offline and applies a run of local
///   mutations WITH NO SYNC OF ITS OWN, while the OTHER device stays online and
///   syncs after each edit, so the server advances underneath the offline one.
///   The batch is reconciled only when a later `step(side, Op.sync)` or the
///   final [DualHarness.heal] reconnects the device — the classic
///   two-devices-edited-offline crossing.
class DualOp {
  const DualOp.step(this.side, Op op) : batch = const [], _op = op;
  const DualOp.offline(this.side, this.batch) : _op = null;

  final Side side;
  final Op? _op;
  final List<Op> batch;

  bool get isOffline => _op == null;

  /// The single op of a [DualOp.step]. Throws on an offline batch.
  Op get op => _op!;

  @override
  String toString() =>
      isOffline ? 'offline(${side.name}, $batch)' : 'step(${side.name}, $_op)';
}

/// Two whole app instances over ONE shared fake Google — the dual-device
/// harness. Build A first so its bootstrap "My Tasks" reaches the server; B
/// then ADOPTS that list by title on its own first pull instead of forking a
/// duplicate. Distinct title namespaces ('a'/'b') keep every task and list
/// handle disjoint across the two devices sharing this one server.
class DualHarness {
  DualHarness._(this.client, this.a, this.b);

  final FakeTasksApi client;
  final Harness a;
  final Harness b;

  static Future<DualHarness> create() async {
    // A dual harness runs TWO AppDatabases at once, each over its OWN in-memory
    // executor (no shared executor, so no race) — drift's multiple-database
    // warning is a false positive for this deliberate two-device setup.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final client = FakeTasksApi();
    client.seedList(kList, 'Inbox');
    // Seed the shared client ONCE; A pushes its "My Tasks", B adopts it.
    final a = await Harness.onSharedClient(client, 'a');
    final b = await Harness.onSharedClient(client, 'b');
    return DualHarness._(client, a, b);
  }

  Harness side(Side s) => s == Side.a ? a : b;

  Future<void> dispose() async {
    await a.dispose();
    await b.dispose();
  }

  Future<void> apply(DualOp dop) async {
    if (!dop.isOffline) {
      await side(dop.side).apply(dop.op);
      return;
    }
    // OFFLINE BATCH: the targeted device applies each local mutation with no
    // sync of its own; the OTHER device stays online and syncs after each edit,
    // advancing the server underneath the offline one. Tolerate any fault an op
    // left armed on the shared client (a transient leaves the run Ok; a stray
    // fatal is cleared at heal), and any partial-push abort it raises.
    final other = side(dop.side.other);
    for (final op in dop.batch) {
      await side(dop.side).apply(op);
      try {
        await other.runSync();
      } on Object {
        // The other device's opportunistic sync is best-effort; a fault the
        // batch armed on the shared client is disarmed at heal.
      }
    }
  }

  Future<void> applyAll(List<DualOp> ops) async {
    for (final op in ops) {
      await apply(op);
    }
  }

  /// Drive both devices to a SHARED fixpoint. Each round drains A to its own
  /// fixpoint ([Harness.heal]), then B; when a round finds BOTH already drained
  /// — each device's first run a no-op — no pending work remains on either side
  /// and neither changed the server, so the server and both caches agree.
  /// [Harness.heal] clears faults and drops holds on each device first.
  Future<void> heal() async {
    for (var round = 0; round < kMaxDualRounds; round++) {
      final ra = await a.heal();
      final rb = await b.heal();
      if (ra == 1 && rb == 1) return;
    }
    fail(
      'no two-device fixpoint after $kMaxDualRounds rounds\n'
      '== A ==\n${await a.dump()}\n== B ==\n${await b.dump()}',
    );
  }
}

/// The n:1 FIXPOINT ORACLE: after a shared fixpoint, each device's cache equals
/// the server field-for-field — and therefore each other. A device that dropped
/// a pull, kept a phantom row, or wedged a row dirty shows up here as a set that
/// differs from the server the other device agrees with.
Future<void> assertDualConverged(DualHarness d, String ctx) async {
  final server = await d.a.serverRows();
  final a = await d.a.localRows();
  final b = await d.b.localRows();
  expect(
    a,
    server,
    reason:
        '$ctx: device A diverges from the server\n'
        '== A local ==\n${await d.a.dump()}\n== B local ==\n${await d.b.dump()}',
  );
  expect(
    b,
    server,
    reason:
        '$ctx: device B diverges from the server\n'
        '== A local ==\n${await d.a.dump()}\n== B local ==\n${await d.b.dump()}',
  );
}

// ─── Canonical dump — the cross-implementation comparator ────────────────────

/// A local task row reduced to the fields two INDEPENDENTLY-RUNNING engines can
/// be expected to agree on. Deliberately EXCLUDES id, etag and position: those
/// are call-order-dependent and can never match across engines that assigned
/// them in different orders (the dual-device oracle, MIGRATION-PLAN §3). The
/// tree is title-keyed and the parent is expressed by the parent's TITLE, not
/// its id. This mirrors the reference suite's `Row` comparator (content +
/// status, id/position never compared) generalized to cross-engine use.
///
/// Sync markers are intentionally NOT part of the canonical row: the equivalence
/// claim is about user-visible content at a fixpoint, and the concrete `Row`
/// comparator the plan says to mirror carries none. Drainedness is asserted
/// separately (`pendingPushCount == 0`).
class CanonRow implements Comparable<CanonRow> {
  CanonRow({
    required this.listTitle,
    required this.parentTitle,
    required this.title,
    required this.notes,
    required this.due,
    required this.completed,
  });

  /// Map one stored task to its canonical row. [listTitle] and [parentTitle]
  /// are resolved by the caller (both are TITLES, never ids).
  factory CanonRow.of(String listTitle, String? parentTitle, Task t) =>
      CanonRow(
        listTitle: listTitle,
        parentTitle: parentTitle,
        title: t.title,
        // Google returns cleared notes as absent; "" and null are the same
        // user-visible state.
        notes: (t.notes == null || t.notes!.isEmpty) ? null : t.notes,
        due: t.due == null ? null : normalizeDue(t.due!),
        completed: t.status == TaskStatus.completed,
      );

  final String listTitle;
  final String? parentTitle;
  final String title;
  final String? notes;
  final String? due;
  final bool completed;

  String get _key =>
      '$listTitle${String.fromCharCode(0)}$parentTitle${String.fromCharCode(0)}$title';

  @override
  int compareTo(CanonRow other) => _key.compareTo(other._key);

  @override
  bool operator ==(Object other) =>
      other is CanonRow &&
      other.listTitle == listTitle &&
      other.parentTitle == parentTitle &&
      other.title == title &&
      other.notes == notes &&
      other.due == due &&
      other.completed == completed;

  @override
  int get hashCode =>
      Object.hash(listTitle, parentTitle, title, notes, due, completed);

  @override
  String toString() =>
      'CanonRow($listTitle / parent=$parentTitle "$title" '
      'notes=$notes due=$due done=$completed)';

  /// The map form persisted in a corpus / exchanged with the oracle binary.
  Map<String, dynamic> toJson() => {
    'list': listTitle,
    'parent': parentTitle,
    'title': title,
    'notes': notes,
    'due': due,
    'completed': completed,
  };

  /// Parse the canonical row the reference oracle binary emits over its JSON
  /// protocol (same shape as [toJson]).
  factory CanonRow.fromJson(Map<String, dynamic> j) => CanonRow(
    listTitle: j['list'] as String,
    parentTitle: j['parent'] as String?,
    title: j['title'] as String,
    notes: j['notes'] as String?,
    due: j['due'] as String?,
    completed: j['completed'] as bool,
  );
}

/// The canonical dump of one device's LOCAL cache: every VISIBLE task across
/// every list, as sorted [CanonRow]s. Tombstones (hidden rows) are excluded —
/// after a fixpoint there are none, and mid-sequence they are not user-visible
/// state. Duplicate titles are kept as distinct rows (a sorted list, not a map),
/// so a `remoteCreateDup` look-alike still counts.
Future<List<CanonRow>> canonicalDump(Harness h) async {
  final rows = await h.store.allTasks();
  final titleById = <String, String>{
    for (final r in rows) r.task.id: r.task.title,
  };
  final listTitleById = <String, String>{
    for (final l in await h.store.allLists()) l.list.id: l.list.title,
  };
  final out = <CanonRow>[
    for (final r in rows)
      CanonRow.of(
        listTitleById[r.listId] ?? '<list:${r.listId}>',
        r.task.parent == null
            ? null
            : (titleById[r.task.parent] ?? '<missing>'),
        r.task,
      ),
  ]..sort();
  return out;
}

/// After a shared fixpoint, the two devices' canonical dumps agree — the exact
/// comparison the cross-implementation oracle makes, but with the second engine
/// being device B rather than the Rust binary. Because it keys on title and
/// drops ids/etags/positions, it is blind to the call-order divergence that is
/// EXPECTED between independent engines and sensitive only to real content
/// disagreement.
Future<void> assertDualCanonicalAgree(DualHarness d, String ctx) async {
  final a = await canonicalDump(d.a);
  final b = await canonicalDump(d.b);
  expect(
    a,
    b,
    reason:
        "$ctx: the two devices' canonical dumps disagree\n"
        '== A ==\n${await d.a.dump()}\n== B ==\n${await d.b.dump()}',
  );
}

// ─── Dual generator ──────────────────────────────────────────────────────────

/// The LOCAL user vocabulary only — no sync/fault/restart ops and none of the
/// `remote*` phantom-device ops. An offline batch is one device editing its own
/// cache with the wire down; a sync inside the batch would defeat the point,
/// and a phantom remote hit would be a THIRD device, which the interleaved step
/// ops already supply. Weighted like the single-device local core so batches
/// build a real tree rather than churning empty indices. Mirrors the reference
/// `local_mutation_op`.
final List<OpWeight> _localMutationTable = [
  OpWeight(6, (r) => Op(OpKind.createTop, a: opByte(r))),
  OpWeight(4, (r) => Op(OpKind.createSub, a: opByte(r))),
  OpWeight(3, (r) => Op(OpKind.rename, a: opByte(r))),
  OpWeight(3, (r) => Op(OpKind.setDue, a: opByte(r), b: opByte(r))),
  OpWeight(3, (r) => Op(OpKind.toggle, a: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.delete, a: opByte(r))),
  OpWeight(
    2,
    (r) => Op(OpKind.reorder, a: opByte(r), b: opByte(r), flag: r.nextBool()),
  ),
  OpWeight(2, (r) => Op(OpKind.moveAfter, a: opByte(r), b: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.demote, a: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.promote, a: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.moveToList, a: opByte(r), b: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.createList)),
  OpWeight(1, (r) => Op(OpKind.renameList, a: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.openPanel, a: opByte(r))),
  OpWeight(2, (r) => Op(OpKind.closePanel)),
];

/// One dual step: mostly interleaved single ops on either device (`anyOp`, so
/// syncs, crashes and phantom-remote events are all in the mix on both sides),
/// with a minority of offline batches on one device while the other stays live.
/// Mirrors the reference `dual_op` 8:2 split.
DualOp drawDualOp(Random r) {
  final s = r.nextBool() ? Side.a : Side.b;
  if (r.nextInt(10) < 8) {
    return DualOp.step(s, drawAnyOp(r));
  }
  final n = 2 + r.nextInt(6); // 2..7 local mutations
  final batch = [for (var i = 0; i < n; i++) drawFrom(r, _localMutationTable)];
  return DualOp.offline(s, batch);
}

/// A whole dual sequence: 1..23 dual ops. Mirrors the reference `dual_ops`.
List<DualOp> drawDualSeq(Random r) {
  final n = 1 + r.nextInt(23);
  return [for (var i = 0; i < n; i++) drawDualOp(r)];
}

// ─── Corpus: JSON-lines, replayable from either side ─────────────────────────

Map<String, dynamic> _opToJson(Op op) => {
  'k': op.kind.name,
  'a': op.a,
  'b': op.b,
  'f': op.flag,
};

Op _opFromJson(Map<String, dynamic> j) => Op(
  OpKind.values.firstWhere((k) => k.name == j['k'] as String),
  a: j['a'] as int,
  b: j['b'] as int,
  flag: j['f'] as bool,
);

Map<String, dynamic> _dualOpToJson(DualOp d) => d.isOffline
    ? {
        't': 'offline',
        'side': d.side.name,
        'batch': [for (final o in d.batch) _opToJson(o)],
      }
    : {'t': 'step', 'side': d.side.name, 'op': _opToJson(d.op)};

DualOp _dualOpFromJson(Map<String, dynamic> j) {
  final side = Side.values.firstWhere((s) => s.name == j['side'] as String);
  if (j['t'] == 'offline') {
    final batch = [
      for (final o in j['batch'] as List)
        _opFromJson((o as Map).cast<String, dynamic>()),
    ];
    return DualOp.offline(side, batch);
  }
  return DualOp.step(
    side,
    _opFromJson((j['op'] as Map).cast<String, dynamic>()),
  );
}

/// One dual sequence as a single JSON-lines record (no embedded newlines).
String encodeSequence(List<DualOp> ops) => jsonEncode({
  'ops': [for (final o in ops) _dualOpToJson(o)],
});

List<DualOp> decodeSequence(String line) {
  final j = (jsonDecode(line) as Map).cast<String, dynamic>();
  return [
    for (final o in j['ops'] as List)
      _dualOpFromJson((o as Map).cast<String, dynamic>()),
  ];
}

/// A corpus: one sequence per line, replayable from either side. Failing
/// sequences persist here so a regression reproduces from the exact crossing.
String encodeCorpus(List<List<DualOp>> corpus) =>
    corpus.map(encodeSequence).join('\n');

List<List<DualOp>> decodeCorpus(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.trim().isNotEmpty) decodeSequence(line),
];

/// Generated dual sequences in the committed corpus. Fixed (not env-tunable) so
/// the committed `dual_corpus.jsonl` stays a stable exchange artifact both this
/// suite and the reference oracle binary replay verbatim.
const int kCorpusGenerated = 16;

/// The "full ported corpus": the deterministic crossings the reference dual
/// suite hard-codes by name, followed by a fixed-seed run of the dual
/// generator. Every sequence is replayable from either side and, at a fixpoint,
/// converges. This is the source of truth for the committed `dual_corpus.jsonl`
/// (regenerate with `AXIOTASK_GEN_CORPUS=1 flutter test
/// test/sync/oracle_replay_test.dart` after any change here — the round-trip
/// test fails until the file matches).
List<List<DualOp>> portedCorpus() {
  final pins = <List<DualOp>>[
    // Racing demotes never form a parent cycle (#155): A builds a parent+child,
    // pushes, then a local move and a remote demote race a third level that D7
    // must flatten — B pulls it and both converge.
    const [
      DualOp.offline(Side.a, [Op(OpKind.createTop), Op(OpKind.createSub)]),
      DualOp.step(Side.a, Op(OpKind.sync)),
      DualOp.step(Side.a, Op(OpKind.moveAfter, a: 29, b: 2)),
      DualOp.step(Side.a, Op(OpKind.remoteDemote, a: 32)),
      DualOp.step(Side.b, Op(OpKind.sync)),
    ],
    // Two devices edit the same shared row offline (due vs rename), then both
    // reconnect — the canonical crossing as a corpus entry.
    const [
      DualOp.step(Side.a, Op(OpKind.createTop)),
      DualOp.step(Side.a, Op(OpKind.sync)),
      DualOp.step(Side.b, Op(OpKind.sync)),
      DualOp.offline(Side.a, [Op(OpKind.setDue), Op(OpKind.rename)]),
      DualOp.offline(Side.b, [Op(OpKind.rename)]),
    ],
  ];
  final rng = Random(kSeed);
  final generated = [
    for (var i = 0; i < kCorpusGenerated; i++) drawDualSeq(rng),
  ];
  return [...pins, ...generated];
}

// ─── Cross-implementation oracle configuration ───────────────────────────────

/// What the cross-implementation oracle replay does in the current environment
/// (MIGRATION-PLAN §3/§4). Two env knobs drive it:
///  * `AXIOTASK_ORACLE_BIN` — path to the reference `axiotask-oracle` binary
///    (built by T4.1 in the Rust repo). Absent/empty ⇒ not available.
///  * `AXIOTASK_ORACLE` — `required` puts the replay in oracle-REQUIRED mode:
///    an absent binary is a FAILURE, not a skip. Any other value (or unset)
///    leaves skip-when-absent mode, which every UNRELATED task's gate run uses
///    so the missing reference binary never blocks them.
enum OracleAction { run, skipAbsent, failAbsent }

class OracleConfig {
  const OracleConfig({required this.binPath, required this.required});

  /// Non-empty path to the reference binary, or null when unavailable.
  final String? binPath;

  /// Whether an absent binary must FAIL (oracle-REQUIRED) rather than skip.
  final bool required;

  factory OracleConfig.fromEnv(Map<String, String> env) {
    final raw = (env['AXIOTASK_ORACLE_BIN'] ?? '').trim();
    final mode = (env['AXIOTASK_ORACLE'] ?? '').trim().toLowerCase();
    return OracleConfig(
      binPath: raw.isEmpty ? null : raw,
      required: mode == 'required',
    );
  }

  bool get available => binPath != null;

  OracleAction get action => available
      ? OracleAction.run
      : (required ? OracleAction.failAbsent : OracleAction.skipAbsent);
}
