import '../core/failure.dart';
import '../data/google_tasks/dto.dart';
import '../domain/model/tasks.dart';
import 'create_operations.dart';
import 'delete_operations.dart';
import 'phase.dart';
import 'structure_operations.dart';
import 'update_operations.dart';

final class SyncRunId {
  const SyncRunId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) => other is SyncRunId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SyncRunId(<redacted>)';
}

final class SyncRunRequest {
  SyncRunRequest({
    required this.accountId,
    Set<String> triggers = const <String>{'explicit'},
  }) : triggers = Set<String>.unmodifiable(triggers) {
    if (this.triggers.isEmpty || this.triggers.any((value) => value.isEmpty)) {
      throw ArgumentError.value(triggers, 'triggers', 'must be non-empty');
    }
  }

  final AccountId accountId;
  final Set<String> triggers;
}

enum SyncRunOutcome { succeeded, ineligible, failed, interrupted }

enum SyncRunIneligibleReason {
  accountMissing,
  syncStopped,
  noAuthorization,
  accountMismatch,
}

final class SyncRunReport {
  const SyncRunReport({
    required this.outcome,
    required this.runId,
    required this.complete,
    required this.taskListPages,
    required this.taskPages,
    required this.remoteTaskLists,
    required this.remoteTasks,
    required this.resourceProjectionWrites,
    this.createOperations = 0,
    this.updateOperations = 0,
    this.moveOperations = 0,
    this.deleteOperations = 0,
    this.googleWonReplacements = 0,
    this.googleWonReplacementDetails = const <ContentSupersessionResult>[],
    this.confirmedUpdateReadBacks = 0,
    this.googleWonStructures = 0,
    this.confirmedStructureReadBacks = 0,
    this.conditionalReplans = 0,
    this.ineligibleReason,
    this.failure,
  });

  final SyncRunOutcome outcome;
  final SyncRunId runId;
  final bool complete;
  final SyncRunIneligibleReason? ineligibleReason;
  final Failure? failure;
  final int taskListPages;
  final int taskPages;
  final int remoteTaskLists;
  final int remoteTasks;
  final int resourceProjectionWrites;
  final int createOperations;
  final int updateOperations;
  final int moveOperations;
  final int deleteOperations;
  final int googleWonReplacements;
  final List<ContentSupersessionResult> googleWonReplacementDetails;
  final int confirmedUpdateReadBacks;
  final int googleWonStructures;
  final int confirmedStructureReadBacks;
  final int conditionalReplans;
}

final class ReadSyncEligibility {
  const ReadSyncEligibility({
    required this.exists,
    required this.syncEnabled,
    required this.reauthorizationRequired,
    required this.googleSubject,
  });

  final bool exists;
  final bool syncEnabled;
  final bool reauthorizationRequired;
  final String? googleSubject;
}

final class PublishedTaskList {
  const PublishedTaskList({required this.localId, required this.remoteId});

  final TaskListId localId;
  final RemoteTaskListId remoteId;
}

final class PagePublicationResult<T> {
  PagePublicationResult({required List<T> values, required this.resourceWrites})
    : values = List<T>.unmodifiable(values);

  final List<T> values;
  final int resourceWrites;
}

abstract interface class ReadSyncStore {
  Future<void> recoverReadRun(AccountId accountId);

  Future<ReadSyncEligibility> readEligibility(AccountId accountId);

  Future<void> beginReadRun({
    required AccountId accountId,
    required SyncRunId runId,
    required Set<String> triggers,
    required DateTime startedAt,
  });

  Future<PagePublicationResult<PublishedTaskList>> publishTaskListPage({
    required AccountId accountId,
    required SyncRunId runId,
    required List<RemoteTaskList> items,
    required PageToken? nextPageToken,
    required String? collectionEtag,
  });

  Future<PagePublicationResult<void>> publishTaskPage({
    required AccountId accountId,
    required SyncRunId runId,
    required PublishedTaskList taskList,
    required List<RemoteTask> items,
    required PageToken? nextPageToken,
    required String? collectionEtag,
  });

  Future<bool> isPublicationComplete({
    required AccountId accountId,
    required SyncRunId runId,
  });

  Future<void> finalizeReadSuccess({
    required AccountId accountId,
    required SyncRunId runId,
    required DateTime completedAt,
  });

  Future<void> finalizeReadFailure({
    required AccountId accountId,
    required SyncRunId runId,
    required DateTime failedAt,
    required Failure failure,
  });
}

abstract interface class SyncStore
    implements
        ReadSyncStore,
        CreateSyncStore,
        UpdateSyncStore,
        DeleteSyncStore,
        StructureSyncStore {}

abstract interface class SyncRunObserver {
  void phaseStarted(SyncRunId runId, SyncRunPhase phase);
}

final class NoopSyncRunObserver implements SyncRunObserver {
  const NoopSyncRunObserver();

  @override
  void phaseStarted(SyncRunId runId, SyncRunPhase phase) {}
}

enum SyncRunBoundaryKind {
  phase,
  beforePagePublication,
  afterPagePublication,
  beforeOperationClaim,
  afterOperationClaim,
  beforeRemoteAcknowledgement,
  afterRemoteAcknowledgement,
  beforeFinalization,
}

final class SyncRunBoundary {
  const SyncRunBoundary({
    required this.kind,
    this.scope,
    this.pageIndex,
    this.phase,
    this.operationAttemptId,
  });

  final SyncRunBoundaryKind kind;
  final String? scope;
  final int? pageIndex;
  final SyncRunPhase? phase;
  final int? operationAttemptId;

  @override
  bool operator ==(Object other) =>
      other is SyncRunBoundary &&
      kind == other.kind &&
      scope == other.scope &&
      pageIndex == other.pageIndex &&
      phase == other.phase &&
      operationAttemptId == other.operationAttemptId;

  @override
  int get hashCode =>
      Object.hash(kind, scope, pageIndex, phase, operationAttemptId);
}

enum SyncRunControlDecision { proceed, interrupt }

abstract interface class SyncRunControl {
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary);
}

abstract interface class SyncRunInterruptionFailure {
  Failure? get interruptionFailure;
}

/// Optional active-request cancellation signal implemented by coordinators.
///
/// Boundary checks remain authoritative for stopping the engine. This signal
/// additionally lets a transport abort a read that is already awaiting bytes.
abstract interface class SyncRunCancellationSignal {
  bool get isCancellationRequested;

  Future<void> get whenCancellationRequested;
}

final class NoopSyncRunControl implements SyncRunControl {
  const NoopSyncRunControl();

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async =>
      SyncRunControlDecision.proceed;
}
