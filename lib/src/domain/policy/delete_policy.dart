const Duration taskDeleteUndoGrace = Duration(seconds: 30);

final class TaskDeletePolicy {
  const TaskDeletePolicy();

  DateTime notBefore(DateTime acknowledgedAt) =>
      acknowledgedAt.toUtc().add(taskDeleteUndoGrace);

  bool isUndoAvailable({required DateTime now, required DateTime notBefore}) =>
      now.toUtc().isBefore(notBefore.toUtc());

  bool isDispatchEligible({
    required DateTime now,
    required DateTime notBefore,
  }) => !now.toUtc().isBefore(notBefore.toUtc());
}
