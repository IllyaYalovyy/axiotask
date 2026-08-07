// Desktop single-instance guard (#48) — the Dart port of `acquire_instance_lock`
// from `state.rs`.
//
// Two processes on one database are unsafe REGARDLESS of WAL: the sync mutex is
// per-process, so both would drain the same dirty rows and double-push creates,
// duplicating tasks on Google. The guard is an advisory `flock(2)` on
// `instance.lock` next to the database, scoped to the DATA DIRECTORY — exactly
// the unit that must be exclusive. A `dev`-prefixed instance, the production
// instance, and an e2e run under its own data root all use different
// directories and may run side by side.
//
// Why FFI flock and not `dart:io`'s `RandomAccessFile.lock`: the reference uses
// Rust's `File::try_lock`, which is `flock` on Unix — a lock owned by the OPEN
// FILE DESCRIPTION, so a second holder is excluded even within one process.
// dart:io's lock is POSIX `fcntl`, owned by the PROCESS, so it cannot detect a
// second in-process holder and cannot back this guard's test. We therefore bind
// `flock` directly. The kernel releases the lock when the fd closes or the
// process dies, however it dies — a crash never leaves a stale guard.
//
// Desktop (Linux) only. Android runs one process per app and has no shared data
// root to contend over, so the bootstrap never calls this on mobile.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Raised when another instance already owns the data directory.
class InstanceLockBusy implements Exception {
  const InstanceLockBusy(this.message);

  /// Human-readable explanation, naming the directory and (if known) the pid.
  final String message;

  @override
  String toString() => 'InstanceLockBusy: $message';
}

/// Raised when the lock file cannot be opened or an unexpected OS error occurs.
class InstanceLockError implements Exception {
  const InstanceLockError(this.message);

  /// Human-readable explanation.
  final String message;

  @override
  String toString() => 'InstanceLockError: $message';
}

/// A held single-instance lock. Keep it alive for the process lifetime; the
/// flock (and the fd) live until [release] or process exit.
class InstanceLock {
  InstanceLock._(this._fd);

  final int _fd;
  bool _released = false;

  /// Release the lock and close the underlying fd. Idempotent.
  void release() {
    if (_released) return;
    _released = true;
    _flock(_fd, _lockUn);
    _close(_fd);
  }
}

// ── libc bindings ───────────────────────────────────────────────────────────

const int _oRdWr = 0x0002;
const int _oCreat = 0x0040; // Linux value
const int _lockEx = 2;
const int _lockNb = 4;
const int _lockUn = 8;

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(Pointer<Utf8>, int, int) _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, Int32),
      int Function(Pointer<Utf8>, int, int)
    >('open');

final int Function(int, int) _flock = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'flock',
    );

final int Function(int) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

/// Take the exclusive advisory lock for the data directory holding [dbPath].
///
/// Creates the data directory if missing, opens (or creates) `instance.lock`
/// beside the DB, and `flock`s it non-blocking. On success the lock file is
/// stamped with this process's pid (informational only — the flock is the
/// guard, the pid is for humans). Throws [InstanceLockBusy] if another holder
/// owns it, or [InstanceLockError] on any other failure.
InstanceLock acquireInstanceLock(File dbPath) {
  final dir = Directory(p.dirname(dbPath.path));
  try {
    dir.createSync(recursive: true);
  } on FileSystemException catch (e) {
    throw InstanceLockError('create data dir: ${e.message}');
  }
  final lockPath = p.join(dir.path, 'instance.lock');

  final cPath = lockPath.toNativeUtf8();
  try {
    final fd = _open(cPath, _oRdWr | _oCreat, 0x1B6 /* 0666 */);
    if (fd < 0) {
      throw InstanceLockError('open $lockPath (errno ${_errno()})');
    }
    final r = _flock(fd, _lockEx | _lockNb);
    if (r != 0) {
      _close(fd);
      final holder = _readPid(lockPath);
      throw InstanceLockBusy(
        'another axiotask instance is already running on this data directory '
        '(${dir.path}${holder == null ? '' : ', pid $holder'}). Close it '
        'first — two processes on one database would duplicate tasks on Google.',
      );
    }
    // Informational stamp — the flock is the guard, the pid is for humans.
    try {
      File(lockPath).writeAsStringSync('$pid\n', flush: true);
    } on FileSystemException {
      // A failed stamp does not weaken the flock; ignore.
    }
    return InstanceLock._(fd);
  } finally {
    malloc.free(cPath);
  }
}

String? _readPid(String lockPath) {
  try {
    final s = File(lockPath).readAsStringSync().trim();
    return s.isEmpty ? null : s;
  } on FileSystemException {
    return null;
  }
}

final int Function() _errnoLocation = () {
  // glibc exposes errno via __errno_location; fall back to 0 if absent.
  try {
    final loc = _libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__errno_location',
        );
    return () => loc().value;
  } on ArgumentError {
    return () => 0;
  }
}();

int _errno() => _errnoLocation();
