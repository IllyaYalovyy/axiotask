import '../../domain/model/tasks.dart';

/// The complete writable task-content record governed by one conflict clock.
final class TaskContentSnapshot {
  const TaskContentSnapshot({
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  });

  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;

  @override
  bool operator ==(Object other) =>
      other is TaskContentSnapshot &&
      title == other.title &&
      notes == other.notes &&
      status == other.status &&
      due == other.due;

  @override
  int get hashCode => Object.hash(title, notes, status, due);
}

final class TaskListTitleSnapshot {
  const TaskListTitleSnapshot(this.title);

  final String title;

  @override
  bool operator ==(Object other) =>
      other is TaskListTitleSnapshot && title == other.title;

  @override
  int get hashCode => title.hashCode;
}

enum WholeRecordWinner { confirmed, local, google }

enum WholeRecordResolutionReason {
  desiredAlreadyOnGoogle,
  localOnly,
  googleOnly,
  localNewer,
  googleNewer,
  googleTie,
}

sealed class WholeRecordReconciliation<T> {
  const WholeRecordReconciliation();
}

final class WholeRecordResolution<T> extends WholeRecordReconciliation<T> {
  const WholeRecordResolution.confirmed(this.value)
    : winner = WholeRecordWinner.confirmed,
      reason = WholeRecordResolutionReason.desiredAlreadyOnGoogle;

  const WholeRecordResolution.local(this.value, this.reason)
    : assert(
        reason == WholeRecordResolutionReason.localOnly ||
            reason == WholeRecordResolutionReason.localNewer,
      ),
      winner = WholeRecordWinner.local;

  const WholeRecordResolution.google(this.value, this.reason)
    : assert(
        reason == WholeRecordResolutionReason.googleOnly ||
            reason == WholeRecordResolutionReason.googleNewer ||
            reason == WholeRecordResolutionReason.googleTie,
      ),
      winner = WholeRecordWinner.google;

  final T value;
  final WholeRecordWinner winner;
  final WholeRecordResolutionReason reason;

  @override
  bool operator ==(Object other) =>
      other is WholeRecordResolution<T> &&
      value == other.value &&
      winner == other.winner &&
      reason == other.reason;

  @override
  int get hashCode => Object.hash(value, winner, reason);
}

final class WholeRecordConflictEvidenceFailure<T>
    extends WholeRecordReconciliation<T> {
  const WholeRecordConflictEvidenceFailure();

  @override
  bool operator ==(Object other) =>
      other is WholeRecordConflictEvidenceFailure<T>;

  @override
  int get hashCode => T.hashCode;
}

/// Reconciles one complete record against the common base.
///
/// Timestamps are consulted only for a real two-sided change. An exact desired
/// read-back confirms regardless of timestamp availability, and a one-sided
/// change cannot be discarded because unrelated timestamp evidence is absent.
WholeRecordReconciliation<T> reconcileWholeRecord<T>({
  required T base,
  required T local,
  required T remote,
  required DateTime? localModifiedAt,
  required DateTime? remoteModifiedAt,
}) {
  if (local == remote) return WholeRecordResolution<T>.confirmed(remote);

  final localChanged = local != base;
  final remoteChanged = remote != base;
  if (localChanged && !remoteChanged) {
    return WholeRecordResolution<T>.local(
      local,
      WholeRecordResolutionReason.localOnly,
    );
  }
  if (!localChanged && remoteChanged) {
    return WholeRecordResolution<T>.google(
      remote,
      WholeRecordResolutionReason.googleOnly,
    );
  }

  // Both unchanged cannot reach here because it implies local == remote.
  if (localModifiedAt == null ||
      remoteModifiedAt == null ||
      !localModifiedAt.isUtc ||
      !remoteModifiedAt.isUtc) {
    return WholeRecordConflictEvidenceFailure<T>();
  }
  if (localModifiedAt.isAfter(remoteModifiedAt)) {
    return WholeRecordResolution<T>.local(
      local,
      WholeRecordResolutionReason.localNewer,
    );
  }
  return WholeRecordResolution<T>.google(
    remote,
    localModifiedAt.isAtSameMomentAs(remoteModifiedAt)
        ? WholeRecordResolutionReason.googleTie
        : WholeRecordResolutionReason.googleNewer,
  );
}
