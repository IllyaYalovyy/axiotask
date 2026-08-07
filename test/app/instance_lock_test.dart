@TestOn('linux')
library;

import 'dart:io';

import 'package:axiotask/src/app/instance_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('axiotask_lock_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File dbPathUnder(Directory dir) => File(p.join(dir.path, 'axiotask.sqlite'));

  test('excludes a second holder and frees on release (#48)', () {
    final db = dbPathUnder(tmp);

    final first = acquireInstanceLock(db);
    addTearDown(first.release);

    // A second acquire on the SAME data directory is refused while the first
    // is held — two processes on one DB would double-push and duplicate tasks
    // on Google. (flock excludes even across handles in one process.)
    expect(
      () => acquireInstanceLock(db),
      throwsA(isA<InstanceLockBusy>()),
      reason: 'the directory is already owned',
    );

    // Releasing the first frees the guard, so a fresh acquire now succeeds.
    first.release();
    final second = acquireInstanceLock(db);
    addTearDown(second.release);
    expect(second, isA<InstanceLock>());
  });

  test('is scoped per data directory — two dirs both acquire', () {
    final dirA = Directory(p.join(tmp.path, 'a'))..createSync();
    final dirB = Directory(p.join(tmp.path, 'b'))..createSync();

    final a = acquireInstanceLock(dbPathUnder(dirA));
    addTearDown(a.release);
    // A different data directory (a `dev` instance, an e2e run under its own
    // data root) is a different lock and may run side by side.
    final b = acquireInstanceLock(dbPathUnder(dirB));
    addTearDown(b.release);

    expect(a, isA<InstanceLock>());
    expect(b, isA<InstanceLock>());
  });

  test('creates the data directory and writes a pid to instance.lock', () {
    final nested = Directory(p.join(tmp.path, 'created', 'by', 'lock'));
    expect(nested.existsSync(), isFalse);

    final lock = acquireInstanceLock(dbPathUnder(nested));
    addTearDown(lock.release);

    expect(nested.existsSync(), isTrue, reason: 'data dir created');
    final lockFile = File(p.join(nested.path, 'instance.lock'));
    expect(lockFile.existsSync(), isTrue);
    expect(int.tryParse(lockFile.readAsStringSync().trim()), pid);
  });
}
