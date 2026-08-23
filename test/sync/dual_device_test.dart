// Dual-device property tests — two app instances over ONE shared fake Google
// (MIGRATION-PLAN §3, §5 T5.11). The single-device suite (property_suite_test.dart)
// proves one engine stays consistent with one server; this proves the CROSSING
// the lone engine is blind to: two devices editing shared rows offline,
// reconnecting in generator-drawn order, and having to converge.
//
// The n:1 fixpoint oracle (assertDualConverged) is sound because whatever the
// server converges to, BOTH devices pull it, so a correct pair each mirrors the
// server — a dropped pull, a phantom row, or a row wedged dirty on ONE device
// diverges from the server the other agrees with. assertDualCanonicalAgree adds
// the title-keyed, id/etag/position-excluded comparator the cross-implementation
// oracle uses (here comparing device A to device B; oracle_replay_test.dart
// wires the same comparator to the Rust reference binary once it exists).

import 'dart:math';

import 'package:axiotask/src/model/dates.dart' show DateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dual_device.dart';
import 'property_suite_test.dart';

/// Sequences explored per dual property on a normal `flutter test`. Smaller
/// than the single-device count: each dual case drives two whole engines and an
/// offline interleaving, so it costs more per case. `AXIOTASK_PROPTEST_CASES`
/// raises it for a soak (the seed is fixed, so a deeper run is a strict
/// superset).
const int kDualCases = 12;

/// Run [body] over [cases] freshly generated dual sequences, each against a
/// fresh two-device harness under an advancing clock, disposed after. A failure
/// prints the exact sequence, reproducible at the fixed seed forever.
Future<int> checkDual(
  int cases,
  Future<void> Function(DualHarness, List<DualOp>) body,
) async {
  final rng = Random(kSeed);
  var compared = 0;
  for (var i = 0; i < cases; i++) {
    final ops = drawDualSeq(rng);
    await withClock(advancingClock(), () async {
      final d = await DualHarness.create();
      try {
        await body(d, ops);
        compared += 1;
      } finally {
        await d.dispose();
      }
    });
  }
  return compared;
}

void main() {
  final cases = casesFor(kDualCases);

  test('two devices converge on the shared server', () async {
    // The DoD's ">0 generated dual sequences compared green": every generated
    // crossing drives both engines to a shared fixpoint and the two caches are
    // compared field-for-field (id-keyed against the server AND title-keyed
    // against each other). A non-zero compared count is asserted so a silently
    // empty generator can never pass this vacuously.
    final compared = await checkDual(cases, (d, ops) async {
      await d.applyAll(ops);
      await d.heal();

      await assertDualConverged(d, 'after $ops');
      await assertDualCanonicalAgree(d, 'after $ops');

      // Neither device is left holding pending work once the shared fixpoint is
      // reached (convergence in finite runs), and each is structurally sound.
      for (final (name, h) in [('A', d.a), ('B', d.b)]) {
        expect(
          await h.store.pendingPushCount(),
          0,
          reason:
              'device $name left pending work at the fixpoint for $ops\n'
              '${await h.dump()}',
        );
        await assertParentIntegrity(h, 'device $name after dual convergence');
        await assertBaseNullWhenClean(h, 'device $name after dual convergence');
      }

      // Idempotency at the shared fixpoint: one more run on either device
      // touches nothing (a second run against a quiescent remote is a no-op).
      final extraA = await d.a.runSync();
      final extraB = await d.b.runSync();
      expect(
        isNoop(extraA) && isNoop(extraB),
        isTrue,
        reason:
            'a run after the dual fixpoint was not a no-op '
            '(A=$extraA B=$extraB) for $ops',
      );
    });

    expect(
      compared,
      greaterThan(0),
      reason: 'the dual generator produced no sequences to compare',
    );
  });

  // ─── Deterministic crossing pins ───────────────────────────────────────────

  test('two devices edit the same task offline, then converge', () async {
    // The canonical crossing, pinned so the merge is exact and not left to the
    // generator to stumble on. A sets a due date, B renames — a two-field
    // divergence on one shared row. The 412 resolver settles both caches onto
    // whatever the server holds; the row survives exactly once.
    await withClock(advancingClock(), () async {
      final d = await DualHarness.create();
      try {
        // A creates one task in the shared Inbox and pushes it; B pulls it, so
        // both devices hold the same SERVER row — each under its own local id
        // (#224: local ids are per-device and never leave the device).
        final title = await d.a.createTopIn(await d.a.inbox()); // "at001"
        await d.a.runSync(); // A push
        await d.b.runSync(); // B pull
        final shared = (await d.a.live()).firstWhere(
          (t) => t.task.title == title,
        );
        final remoteId = shared.remoteId!;
        final onB = (await d.b.allRows()).where(
          (r) => r.remoteId == remoteId && r.task.title == title,
        );
        expect(
          onB,
          isNotEmpty,
          reason:
              'B must have pulled the shared task before editing it\n'
              '${await d.b.dump()}',
        );

        // Both edit it OFFLINE (no sync): A sets a due date, B renames it.
        await d.a.commands.setDue(shared.task.id, DateMove.today);
        await d.b.commands.renameTask(onB.first.task.id, 'renamed');

        // Reconnect both and drive to the shared fixpoint.
        await d.heal();

        await assertDualConverged(d, 'after both devices edited offline');
        await assertDualCanonicalAgree(d, 'after both devices edited offline');
        final survivors = (await d.a.serverRows())
            .where((r) => r.id == remoteId)
            .length;
        expect(
          survivors,
          1,
          reason:
              'the shared task must survive the offline merge exactly once\n'
              '${await d.a.dump()}',
        );
      } finally {
        await d.dispose();
      }
    });
  });

  test('two-sided conflicted copy terminates and both devices agree', () async {
    // Both devices rename the SAME shared task to DISTINCT titles while offline
    // — the crossing that forces the 412 resolver to fork a "(conflicted copy)"
    // rather than silently adopt one side (nothing discarded). Proves at once:
    // AGREEMENT (both caches + server end equal), TERMINATION (exactly ONE fork,
    // not copies-of-copies), and NO DATA LOSS (both renamed titles survive).
    const suffix = ' (conflicted copy)';
    await withClock(advancingClock(), () async {
      final d = await DualHarness.create();
      try {
        final title = await d.a.createTopIn(await d.a.inbox()); // "at001"
        await d.a.runSync(); // A push
        await d.b.runSync(); // B pull
        final shared = (await d.a.live()).firstWhere(
          (t) => t.task.title == title,
        );
        final onB = (await d.b.allRows()).where(
          (r) => r.remoteId == shared.remoteId,
        );
        expect(
          onB,
          isNotEmpty,
          reason: 'B must have pulled the shared task before editing it',
        );

        // Both rename it OFFLINE to DISTINCT titles, each through ITS OWN local
        // id for the shared server row (#224).
        await d.a.commands.renameTask(shared.task.id, 'shared-A');
        await d.b.commands.renameTask(onB.first.task.id, 'shared-B');

        await d.heal();
        await assertDualConverged(d, 'after a two-sided offline title edit');
        await assertDualCanonicalAgree(
          d,
          'after a two-sided offline title edit',
        );

        // TERMINATION: exactly one conflicted copy on the server.
        final server = await d.a.serverRows();
        final copies = server.where((r) => r.title.endsWith(suffix)).toList();
        expect(
          copies.length,
          1,
          reason:
              'expected exactly one conflicted copy, got ${copies.length}\n'
              '${await d.a.dump()}',
        );

        // NO DATA LOSS: both renamed titles survive — one canonical, one forked
        // — regardless of which side won the etag race.
        final copyBase = copies.single.title.substring(
          0,
          copies.single.title.length - suffix.length,
        );
        final canonical = {
          for (final r in server)
            if (!r.title.endsWith(suffix)) r.title,
        };
        final survived = {
          for (final t in canonical)
            if (t == 'shared-A' || t == 'shared-B') t,
          copyBase,
        };
        expect(
          survived,
          {'shared-A', 'shared-B'},
          reason:
              'both offline edits must survive the fork (one canonical, one '
              'copy)\n${await d.a.dump()}',
        );

        for (final (name, h) in [('A', d.a), ('B', d.b)]) {
          expect(
            await h.store.pendingPushCount(),
            0,
            reason:
                'device $name left pending work after the fork\n${await h.dump()}',
          );
        }
      } finally {
        await d.dispose();
      }
    });
  });

  // ─── Canonical comparator (unit) ───────────────────────────────────────────

  test('canonical dump excludes id, etag and position', () async {
    // The cross-implementation comparator is only sound if it is BLIND to the
    // call-order-dependent fields two independent engines can never match on. A
    // row with the same user-visible content but a different id/etag/position
    // must map to an EQUAL canonical row; a different title must not.
    Task task({
      required String id,
      String? etag,
      required String position,
      String title = 'buy milk',
      String? notes = 'get 2%',
      String? due = '2026-01-01T00:00:00.000Z',
    }) => Task(
      id: id,
      position: position,
      title: title,
      notes: notes,
      status: TaskStatus.needsAction,
      due: due,
      etag: etag,
      updated: '2026-01-01T00:00:00.000Z',
    );

    final local = CanonRow.of(
      'Inbox',
      null,
      task(id: 'alocal-7', position: '0'),
    );
    final server = CanonRow.of(
      'Inbox',
      null,
      task(id: 'srv-abc123', etag: 'e-999', position: '00000000000000000009'),
    );
    expect(
      local,
      server,
      reason: 'id/etag/position must not affect the canonical row',
    );

    // A genuine content difference IS caught.
    final renamed = CanonRow.of(
      'Inbox',
      null,
      task(id: 'srv-abc123', position: '0', title: 'buy oat milk'),
    );
    expect(local == renamed, isFalse, reason: 'title must be compared');

    // Due dates are normalized, so equivalent RFC-3339 forms collapse — but a
    // different calendar day is a real difference.
    final otherDay = CanonRow.of(
      'Inbox',
      null,
      task(id: 'x', position: '0', due: '2026-02-02T00:00:00.000Z'),
    );
    expect(local == otherDay, isFalse, reason: 'due day must be compared');
    expect(
      normalizeDue('2026-01-01T00:00:00.000Z'),
      normalizeDue('2026-01-01T12:34:56.000Z'),
      reason: 'sanity: normalizeDue discards the time-of-day',
    );
  });
}
