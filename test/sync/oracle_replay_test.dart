// Oracle corpus replay (MIGRATION-PLAN §3, §5 T5.11). Three layers, weakest to
// strongest:
//
//  1. The corpus round-trips through its JSON-lines format, and the committed
//     `dual_corpus.jsonl` matches the in-code [portedCorpus] source of truth —
//     the artifact both sides replay is exactly the sequences the generator
//     produces.
//  2. The full corpus replays GREEN through the Dart dual harness: every
//     sequence drives both engines to a shared fixpoint where the two caches
//     agree (the n:1 + canonical oracle). This is ">0 sequences compared green"
//     with the achievable, binary-free oracle.
//  3. The CROSS-IMPLEMENTATION oracle: each corpus sequence is replayed by the
//     reference `axiotask-oracle` binary and its canonical dump compared to the
//     Dart engine's. In oracle-REQUIRED mode an absent binary is a FAILURE, not
//     a skip; in the default mode every unrelated task's gate run uses, it skips
//     when absent so the missing reference binary never blocks them.
//     (MIGRATION-PLAN §4 T4.1 builds that binary in the Rust repo.)

import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dual_device.dart';
import 'property_suite.dart';

/// The committed corpus both this suite and the reference oracle replay.
final File _corpusFile = File('test/sync/corpus/dual_corpus.jsonl');

Future<void> _replayThroughDualHarness(List<DualOp> ops, String ctx) async {
  await withClock(advancingClock(), () async {
    final d = await DualHarness.create();
    try {
      await d.applyAll(ops);
      await d.heal();
      await assertDualConverged(d, ctx);
      await assertDualCanonicalAgree(d, ctx);
    } finally {
      await d.dispose();
    }
  });
}

void main() {
  // Regeneration hook: `AXIOTASK_GEN_CORPUS=1 flutter test
  // test/sync/oracle_replay_test.dart` rewrites the committed corpus from the
  // in-code source of truth. Inert (a no-op that still asserts round-trip)
  // during a normal gate run.
  final regen = Platform.environment['AXIOTASK_GEN_CORPUS'] == '1';

  test(
    'corpus round-trips through JSON-lines and matches the committed file',
    () {
      final corpus = portedCorpus();
      // Structural round-trip: decode∘encode is the identity on the corpus.
      final text = encodeCorpus(corpus);
      expect(
        encodeCorpus(decodeCorpus(text)),
        text,
        reason: 'a corpus must survive a JSON-lines encode/decode round-trip',
      );

      if (regen) {
        _corpusFile.parent.createSync(recursive: true);
        _corpusFile.writeAsStringSync('$text\n');
        // ignore: avoid_print
        print('regenerated ${corpus.length} sequences → ${_corpusFile.path}');
        return;
      }

      expect(
        _corpusFile.existsSync(),
        isTrue,
        reason:
            'committed corpus ${_corpusFile.path} is missing — regenerate with '
            'AXIOTASK_GEN_CORPUS=1',
      );
      // The committed file is exactly the in-code corpus (regenerate on drift).
      expect(
        encodeCorpus(decodeCorpus(_corpusFile.readAsStringSync())),
        text,
        reason:
            'committed corpus drifted from portedCorpus() — regenerate with '
            'AXIOTASK_GEN_CORPUS=1 flutter test test/sync/oracle_replay_test.dart',
      );
    },
  );

  test('the full corpus replays green through the dual harness', () async {
    if (regen) return; // regeneration run does not need the (slow) replay
    final corpus = decodeCorpus(_corpusFile.readAsStringSync());
    expect(
      corpus,
      isNotEmpty,
      reason: 'the committed corpus is empty — nothing to compare',
    );
    var compared = 0;
    for (var i = 0; i < corpus.length; i++) {
      await _replayThroughDualHarness(corpus[i], 'corpus[$i] ${corpus[i]}');
      compared += 1;
    }
    // The DoD's non-zero compared count, guarded so an empty corpus cannot pass
    // this vacuously.
    expect(compared, greaterThan(0));
  });

  // ─── Cross-implementation oracle configuration (unit) ──────────────────────

  test('oracle config maps the environment to the right disposition', () {
    OracleConfig cfg(Map<String, String> env) => OracleConfig.fromEnv(env);

    // No binary, default mode → skip (so unrelated gate runs stay green).
    expect(cfg(const {}).action, OracleAction.skipAbsent);
    expect(
      cfg(const {'AXIOTASK_ORACLE_BIN': '  '}).action,
      OracleAction.skipAbsent,
    );

    // No binary, oracle-REQUIRED mode → FAIL (never a silent skip).
    expect(
      cfg(const {'AXIOTASK_ORACLE': 'required'}).action,
      OracleAction.failAbsent,
    );
    expect(
      cfg(const {
        'AXIOTASK_ORACLE': 'REQUIRED',
        'AXIOTASK_ORACLE_BIN': '',
      }).action,
      OracleAction.failAbsent,
    );

    // A binary present → run the comparison, whatever the mode.
    final withBin = cfg(const {'AXIOTASK_ORACLE_BIN': '/opt/axiotask-oracle'});
    expect(withBin.action, OracleAction.run);
    expect(withBin.binPath, '/opt/axiotask-oracle');
    expect(
      cfg(const {
        'AXIOTASK_ORACLE_BIN': '/opt/axiotask-oracle',
        'AXIOTASK_ORACLE': 'required',
      }).action,
      OracleAction.run,
    );
  });

  test('oracle corpus compares green against the reference implementation', () async {
    if (regen) return;
    final cfg = OracleConfig.fromEnv(Platform.environment);
    switch (cfg.action) {
      case OracleAction.skipAbsent:
        markTestSkipped(
          'axiotask-oracle binary absent (AXIOTASK_ORACLE_BIN unset). '
          'Set it to the reference binary, or AXIOTASK_ORACLE=required to make '
          'its absence a failure. (MIGRATION-PLAN §4 T4.1.)',
        );
        return;
      case OracleAction.failAbsent:
        fail(
          'oracle-REQUIRED: the axiotask-oracle reference binary is absent. '
          'Set AXIOTASK_ORACLE_BIN to the binary built by MIGRATION-PLAN §4 '
          'T4.1 in the Rust repo. The Dart side of the oracle (canonical dump, '
          'corpus, comparator) is ready; the cross-implementation comparison is '
          'blocked on that binary.',
        );
      case OracleAction.run:
        final corpus = decodeCorpus(_corpusFile.readAsStringSync());
        expect(corpus, isNotEmpty, reason: 'empty corpus — nothing to compare');
        var compared = 0;
        for (var i = 0; i < corpus.length; i++) {
          final ops = corpus[i];
          // The reference dump: two devices over one shared server, healed to a
          // fixpoint, canonical dump of each side.
          final reference = await _runReferenceOracle(cfg.binPath!, ops);
          // The Dart dump: the same sequence through the dual harness.
          late List<CanonRow> dartA;
          late List<CanonRow> dartB;
          await withClock(advancingClock(), () async {
            final d = await DualHarness.create();
            try {
              await d.applyAll(ops);
              await d.heal();
              dartA = await canonicalDump(d.a);
              dartB = await canonicalDump(d.b);
            } finally {
              await d.dispose();
            }
          });
          expect(
            dartA,
            reference.a,
            reason:
                'device A canonical dump diverges from the oracle for '
                'corpus[$i] $ops',
          );
          expect(
            dartB,
            reference.b,
            reason:
                'device B canonical dump diverges from the oracle for '
                'corpus[$i] $ops',
          );
          compared += 1;
        }
        expect(compared, greaterThan(0));
    }
  });
}

/// A reference dump: the canonical local cache of each device after the oracle
/// binary replayed a dual sequence to a fixpoint.
class _ReferenceDump {
  _ReferenceDump(this.a, this.b);
  final List<CanonRow> a;
  final List<CanonRow> b;
}

/// Drive the reference `axiotask-oracle` binary with one dual sequence over its
/// JSON protocol: the encoded sequence on stdin, `{"a":[...],"b":[...]}` of
/// canonical rows on stdout. Exercised only when AXIOTASK_ORACLE_BIN points at a
/// real binary (T4.1); absent that, the surrounding switch never reaches here.
Future<_ReferenceDump> _runReferenceOracle(String bin, List<DualOp> ops) async {
  final proc = await Process.start(bin, const ['replay']);
  proc.stdin.writeln(encodeSequence(ops));
  await proc.stdin.close();
  final out = await proc.stdout.transform(utf8.decoder).join();
  final code = await proc.exitCode;
  if (code != 0) {
    final err = await proc.stderr.transform(utf8.decoder).join();
    fail('axiotask-oracle exited $code for $ops\n$err');
  }
  final j = (jsonDecode(out) as Map).cast<String, dynamic>();
  List<CanonRow> side(String k) => [
    for (final r in j[k] as List)
      CanonRow.fromJson((r as Map).cast<String, dynamic>()),
  ]..sort();
  return _ReferenceDump(side('a'), side('b'));
}
