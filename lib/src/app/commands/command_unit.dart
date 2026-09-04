part of '../commands.dart';

/// Pending-op for a field edit. A row the server has never acknowledged (no
/// `remote_id`) must stay a `create` — flipping it to `update` would make the
/// push patch an id Google never minted, 404, and delete the task (data loss).
/// Otherwise the edit is an `update`. Port of `commands.rs::dirty_op`.
String dirtyOp(String? remoteId) => remoteId == null ? 'create' : 'update';

// A strictly monotonic tick in NANOseconds since the epoch, mirroring the
// reference's atomic `LAST_TICK`, so two creates in the same microsecond still
// get distinct, ordered positions.
int _lastPositionTick = 0;

// `u64::MAX` — the descending base the reference subtracts the tick from, and
// the same base Google's own top-insert positions descend from. It does NOT fit
// in Dart's SIGNED 64-bit int, so the subtraction runs in [BigInt]: truncating
// it to 2^63-1 would emit a 19-digit placeholder ('!9223372036…') that sorts
// AFTER every 20-digit position Google mints ('!18446744073709551611'), i.e.
// below rows a new task must sit above (#249).
final BigInt _positionBase = BigInt.parse('18446744073709551615');

/// A distinct, ordered placeholder position for a freshly created row. Port of
/// `commands.rs::next_local_position`.
///
/// A local task has no server-assigned position until it syncs (a local-only
/// list never syncs at all). Handing every new row the SAME constant made a
/// later reorder's position-swap a no-op (#80), so each row gets a distinct,
/// ordered value. A larger tick yields a smaller value, so newer rows sort
/// ahead of older ones.
///
/// The value must be the placement GOOGLE will assign, because the sync adopts
/// the server's position and any disagreement re-shuffles the list under the
/// user 3-5s after they typed (#249). Google puts an `insert` with no
/// `previous` at the TOP of its list, so the placeholder has to sort before
/// every position already in play: the `!` prefix (0x21) clears the numeric
/// positions, and `u64::MAX - nowNanos` clears the `u64::MAX - n` values
/// Google's own top inserts carry (the epoch tick dwarfs any `n`).
String nextLocalPosition() {
  final nowNanos = clock.now().toUtc().microsecondsSinceEpoch * 1000;
  final tick = nowNanos > _lastPositionTick ? nowNanos : _lastPositionTick + 1;
  _lastPositionTick = tick;
  return '!${(_positionBase - BigInt.from(tick)).toString().padLeft(19, '0')}';
}

/// Errors a command raises for the caller to surface. The user-facing
/// sanitization allowlist (#128/#135) is a later task (T7.8); for now a missing
/// task is the only command-level failure and carries the reference's exact
/// `"task {id} not found"` shape (the sanitizer keys on it).
class CommandError implements Exception {
  const CommandError(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// THE one spelling of a local field edit: [next] content on the row [current]
/// came from, marked dirty as of [now] so the next sync pushes it.
///
/// [dirtyOp] preserves a `create` for a row the server has never acknowledged
/// (an offline create-then-edit must not flip to `update` and patch an id
/// Google never minted), and the `remote_id` rides along unchanged. Written out
/// by hand at eight call sites before #271, where one of them drifting from the
/// rest would silently mean a lost edit or a 404'd patch.
StoredTask _markDirty(StoredTask current, Task next, String now) => StoredTask(
  task: next,
  listId: current.listId,
  syncState: SyncState.dirty,
  localUpdated: now,
  pendingOp: dirtyOp(current.remoteId),
  remoteId: current.remoteId,
);

/// One slice of the command surface, sharing the [Store] and the id generator
/// with its siblings. Built and owned by [Commands], which is the only public
/// entry point: a unit never fires the mutation trigger itself, so every public
/// mutation notifies exactly once, and only after its write (#271).
abstract class CommandUnit {
  CommandUnit(this._store, this._newId);

  final Store _store;
  final String Function() _newId;

  /// Find a VISIBLE task by id (tombstones read as absent). Port of
  /// `commands.rs::find_task`; raises the reference's exact not-found shape.
  Future<StoredTask> _findTask(String id) async {
    final t = await _store.findTaskAny(id);
    if (t == null || t.syncState == SyncState.deleted) {
      throw CommandError('task $id not found');
    }
    return t;
  }
}
