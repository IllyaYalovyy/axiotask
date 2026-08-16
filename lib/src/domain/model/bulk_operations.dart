import 'dart:collection';

import 'tasks.dart';

enum BulkOperationKind { complete, reschedule, move }

final class BulkOperationSummary {
  const BulkOperationSummary({
    required this.operationId,
    required this.kind,
    required this.selectedCount,
    required this.affectedCount,
    required this.confirmedCount,
    required this.pendingCount,
    required this.failedCount,
    required this.createdAt,
  });

  final int operationId;
  final BulkOperationKind kind;
  final int selectedCount;
  final int affectedCount;
  final int confirmedCount;
  final int pendingCount;
  final int failedCount;
  final DateTime createdAt;

  bool get isSettled => pendingCount == 0;
}

final class BulkOperationReceipt {
  BulkOperationReceipt({required this.summary, required List<TaskId> taskIds})
    : taskIds = UnmodifiableListView<TaskId>(taskIds);

  final BulkOperationSummary summary;
  final List<TaskId> taskIds;
}
