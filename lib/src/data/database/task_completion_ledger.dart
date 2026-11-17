import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/completion_policy.dart';

/// Undo offers for committed completion commands, owned by one repository.
///
/// The persisted schema is frozen without a migration path, so offers live
/// only as long as the repository that committed them; after a restart a
/// completion is no longer undoable, but its stored state is unchanged.
///
/// Each account keeps at most its latest offer. Every status change the
/// repository commits receives a sequence number while its transaction
/// holds the database's write lock, so sequence order is commit order even
/// though ledger updates run after the commit returns:
///
/// * a newer completion replaces an older offer;
/// * any other committed status change supersedes every older offer;
/// * an Undo is claimed inside its transaction and released if that
///   transaction rolls back, so a concurrent retry cannot apply it twice;
/// * a committed Undo stays recorded, so retrying it is an idempotent no-op.
final class TaskCompletionLedger {
  final Map<AccountId, _CompletionOffer> _offers =
      <AccountId, _CompletionOffer>{};
  final Map<AccountId, int> _supersededThrough = <AccountId, int>{};
  var _sequence = 0;

  /// Reserves the next commit sequence. Call inside the write transaction.
  int reserve() => ++_sequence;

  /// Records a committed completion command as the account's Undo offer.
  TaskCompletionUndo? recordCompletion({
    required AccountId accountId,
    required int sequence,
    required List<TaskStatusChange> changes,
    required String? title,
    required int cascadedCount,
    required DateTime createdAt,
  }) {
    final completed = changes
        .where((change) => change.after == TaskStatus.completed)
        .length;
    if (completed == 0) {
      supersede(accountId, sequence);
      return null;
    }
    final undo = TaskCompletionUndo(
      operationId: sequence,
      title: title,
      completedCount: completed,
      cascadedCount: cascadedCount,
      createdAt: createdAt.toUtc(),
      expiresAt: createdAt.toUtc().add(taskCompletionUndoWindow),
    );
    if (sequence <= (_supersededThrough[accountId] ?? 0)) return null;
    final current = _offers[accountId];
    if (current != null && current.undo.operationId > sequence) return null;
    _offers[accountId] = _CompletionOffer(undo, changes);
    return undo;
  }

  /// Retires every offer committed before [sequence].
  void supersede(AccountId accountId, int sequence) {
    final through = _supersededThrough[accountId] ?? 0;
    if (sequence > through) _supersededThrough[accountId] = sequence;
    final current = _offers[accountId];
    if (current != null && current.undo.operationId < sequence) {
      _offers.remove(accountId);
    }
  }

  /// Looks up an offer for Undo. Call inside the Undo's write transaction.
  TaskCompletionLedgerLookup lookup(
    AccountId accountId,
    int operationId,
    DateTime now,
  ) {
    final offer = _offers[accountId];
    if (offer == null || offer.undo.operationId != operationId) {
      return const TaskCompletionLedgerLookup.unavailable();
    }
    if (offer.state != _OfferState.available) {
      return const TaskCompletionLedgerLookup.alreadyUndone();
    }
    if (offer.undo.isExpiredAt(now)) {
      _offers.remove(accountId);
      return const TaskCompletionLedgerLookup.expired();
    }
    return TaskCompletionLedgerLookup.available(offer.changes);
  }

  /// Claims an available offer for an Undo transaction.
  void claim(AccountId accountId, int operationId) =>
      _setState(accountId, operationId, _OfferState.undoing);

  /// Returns a claimed offer after its Undo transaction rolled back.
  void release(AccountId accountId, int operationId) {
    final offer = _offers[accountId];
    if (offer?.undo.operationId == operationId &&
        offer?.state == _OfferState.undoing) {
      offer!.state = _OfferState.available;
    }
  }

  /// Marks a claimed offer's Undo as committed.
  void commitUndo(AccountId accountId, int operationId) =>
      _setState(accountId, operationId, _OfferState.undone);

  void _setState(AccountId accountId, int operationId, _OfferState state) {
    final offer = _offers[accountId];
    if (offer?.undo.operationId == operationId) offer!.state = state;
  }
}

enum TaskCompletionLedgerLookupKind {
  available,
  alreadyUndone,
  unavailable,
  expired,
}

final class TaskCompletionLedgerLookup {
  const TaskCompletionLedgerLookup.available(List<TaskStatusChange> changes)
    : kind = TaskCompletionLedgerLookupKind.available,
      _changes = changes;

  const TaskCompletionLedgerLookup.alreadyUndone()
    : kind = TaskCompletionLedgerLookupKind.alreadyUndone,
      _changes = const <TaskStatusChange>[];

  const TaskCompletionLedgerLookup.unavailable()
    : kind = TaskCompletionLedgerLookupKind.unavailable,
      _changes = const <TaskStatusChange>[];

  const TaskCompletionLedgerLookup.expired()
    : kind = TaskCompletionLedgerLookupKind.expired,
      _changes = const <TaskStatusChange>[];

  final TaskCompletionLedgerLookupKind kind;
  final List<TaskStatusChange> _changes;

  List<TaskStatusChange> get changes => _changes;
}

enum _OfferState { available, undoing, undone }

final class _CompletionOffer {
  _CompletionOffer(this.undo, List<TaskStatusChange> changes)
    : changes = List<TaskStatusChange>.unmodifiable(changes);

  final TaskCompletionUndo undo;
  final List<TaskStatusChange> changes;
  _OfferState state = _OfferState.available;
}
