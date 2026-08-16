import '../../core/failure.dart';
import '../model/tasks.dart';

Failure? validateHierarchyChange({
  required CachedTask task,
  required CachedTask? requestedParent,
  required bool taskHasChildren,
}) {
  if (requestedParent == null) {
    return task.parentTaskId == null ? _alreadyTopLevel : null;
  }
  if (task.id == requestedParent.id) return _parentIsTask;
  if (task.accountId != requestedParent.accountId) return _crossAccount;
  if (task.taskListId != requestedParent.taskListId) return _crossList;
  if (requestedParent.parentTaskId != null) return _unsupportedDepth;
  if (taskHasChildren) return _subtreeDepth;
  return null;
}

const _alreadyTopLevel = Failure(
  code: 'task.already_top_level',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'The task is already top-level.',
);

const _parentIsTask = Failure(
  code: 'task.parent_is_task',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'A task cannot be its own parent.',
);

const _crossAccount = Failure(
  code: 'task.parent_cross_account',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'The parent belongs to another account partition.',
);

const _crossList = Failure(
  code: 'task.parent_cross_list',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'The parent belongs to another task list.',
);

const _unsupportedDepth = Failure(
  code: 'task.unsupported_depth',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'Axiotask supports one subtask level.',
);

const _subtreeDepth = Failure(
  code: 'task.subtree_would_exceed_depth',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task hierarchy was not changed.',
  safeSummary: 'A task with subtasks cannot become a subtask.',
);
