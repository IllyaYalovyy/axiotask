// #268 — the rule this file mechanically enforces: inside the sync engine, no
// raw `upsertTask` may follow a network await in the same method.
//
// Every engine write that lands after an `await _client.*` is a write against a
// snapshot the user may have edited while the request was in the air. The
// guarded primitives (`applyPushedTask`, `markTaskClean`, `finishCreate`,
// `mergeConflictIfUnchanged`, `revertMoveIfUnchanged`, `promoteIfUnchanged`)
// arbitrate that race on `local_updated`; a raw `upsertTask` cannot, because it
// writes `local_updated` itself and so overwrites the newer edit AND erases the
// evidence that there was one.
//
// The three sites this caught (the 412 base merge, the move revert, the D7
// flatten) each read correct in isolation and each silently discarded an edit.
// Their behavior is covered by engine_post_network_race_test.dart; this test
// exists so a FOURTH one cannot be added without someone noticing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The engine source, as text.
const _enginePath = 'lib/src/sync/engine.dart';

/// A member declaration at class-member indentation (exactly two spaces),
/// e.g. `  Future<void> _pushUpdate(` or `  static PushRowRef _taskRef(`.
/// Comments, annotations and closing braces are excluded.
final _memberStart = RegExp(
  r'^  [A-Za-z_@][^;]*[({]\s*$|^  [A-Za-z_].*\) (=>|async|\{)',
);

void main() {
  test('no raw upsertTask follows a network await in the same engine method', () {
    final source = File(_enginePath).readAsLinesSync();
    expect(
      source,
      isNotEmpty,
      reason: 'precondition: $_enginePath is readable from the test CWD',
    );

    final violations = <String>[];
    var member = '<file scope>';
    var awaitedClientAt = 0;
    for (var i = 0; i < source.length; i++) {
      final line = source[i];
      if (_memberStart.hasMatch(line)) {
        member = line.trim();
        awaitedClientAt = 0;
      }
      if (line.contains('await _client.')) awaitedClientAt = i + 1;
      if (awaitedClientAt != 0 && line.contains('_store.upsertTask(')) {
        violations.add(
          '$_enginePath:${i + 1}  upsertTask after the `await _client.` on '
          'line $awaitedClientAt, in `$member`',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'A write after a network await must be guarded on local_updated — use '
          'applyPushedTask / markTaskClean / finishCreate / '
          'mergeConflictIfUnchanged / revertMoveIfUnchanged / promoteIfUnchanged '
          'instead of upsertTask (#268):\n${violations.join('\n')}',
    );
  });

  test('the guard recognizes the shape it is meant to reject', () {
    // A scanner that can never fail is not a guard. This is the pattern the
    // three real defects had, run through the same matcher.
    const offending = [
      '  Future<void> _resolveConflict(StoredTask local) async {',
      '    final fetched = await _client.getTask(listId, local.remoteId!);',
      '    await _store.upsertTask(merged);',
      '  }',
    ];
    var seenAwait = false;
    var flagged = false;
    for (final line in offending) {
      if (_memberStart.hasMatch(line)) seenAwait = false;
      if (line.contains('await _client.')) seenAwait = true;
      if (seenAwait && line.contains('_store.upsertTask(')) flagged = true;
    }
    expect(flagged, isTrue);
  });
}
