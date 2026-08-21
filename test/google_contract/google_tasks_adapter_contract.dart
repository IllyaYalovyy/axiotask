import 'dart:math';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';

import 'google_contract_harness.dart';

/// Exercises the admitted Google Tasks contract only through the same typed
/// service boundary used by synchronization.
///
/// Authentication, HTTP decoding, conditional requests, and failure mapping
/// remain owned by the production adapters. This probe deliberately has no
/// access-token or refresh-token input.
final class GoogleTasksAdapterContract {
  GoogleTasksAdapterContract({
    required this.service,
    required this.expectedSubject,
    required this.resolveAuthenticatedSubject,
    required this.requireWebViewLink,
  });

  final GoogleTasksService service;
  final String expectedSubject;
  final Future<String?> Function() resolveAuthenticatedSubject;
  final bool requireWebViewLink;

  Future<GoogleTasksContractResult> run({
    String? cleanupPrefix,
    String? probePrefix,
  }) async {
    if (cleanupPrefix != null && probePrefix != null) {
      throw ArgumentError('Cleanup and probe prefixes are mutually exclusive.');
    }
    final prefix = cleanupPrefix ?? probePrefix ?? newGoogleContractPrefix();
    if (!isSafeGoogleContractPrefix(prefix)) {
      throw const GoogleContractSafetyException(
        'The cleanup prefix is not an Axiotask contract prefix.',
      );
    }
    final harness = GoogleContractHarness(
      expectedSubject: expectedSubject,
      resolveAuthenticatedSubject: resolveAuthenticatedSubject,
      cleanup: () => cleanup(prefix),
    );
    if (cleanupPrefix != null) {
      try {
        await harness.run<void>(() async {});
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          GoogleTasksContractProbeException(prefix, error),
          stackTrace,
        );
      }
      return const GoogleTasksContractResult.cleanupOnly();
    }
    try {
      return await harness.run(() => _exercise(prefix));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        GoogleTasksContractProbeException(prefix, error),
        stackTrace,
      );
    }
  }

  Future<void> cleanup(String prefix) async {
    if (!isSafeGoogleContractPrefix(prefix)) {
      throw const GoogleContractSafetyException(
        'The cleanup prefix is not an Axiotask contract prefix.',
      );
    }
    final lists = await _allTaskLists();
    for (final list in lists.where((item) => item.title.startsWith(prefix))) {
      _expectCommitted<void>(
        await service.deleteTaskList(DeleteTaskListOperation(list.id)),
        'disposable list cleanup',
      );
    }
    final remaining = await _allTaskLists();
    if (remaining.any((item) => item.title.startsWith(prefix))) {
      throw StateError('Disposable list cleanup left matching resources.');
    }
  }

  Future<GoogleTasksContractResult> _exercise(String prefix) async {
    final source = _expectCommitted(
      await service.createTaskList(
        CreateTaskListOperation(title: '$prefix-main'),
      ),
      'disposable list creation',
    );
    _requireListShape(source);

    final first = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-first',
          status: RemoteTaskStatus.needsAction,
          due: const RemoteDate(2026, 8, 10),
        ),
      ),
      'first task creation',
    );
    final second = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-second',
          status: RemoteTaskStatus.needsAction,
          previousId: first.id,
        ),
      ),
      'second task creation',
    );
    _requireTaskShape(first);
    _requireTaskShape(second);

    // API-001/API-002: walk the production adapter's complete pagination
    // contract. The deterministic fake forces multiple pages; the live run
    // validates Google's current wire response without changing page sizing.
    final initialTasks = await _allTasks(source.id);
    _requireContains(initialTasks, first.id, 'initial task walk');
    _requireContains(initialTasks, second.id, 'initial task walk');
    final insertedDuringWalk = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-after-walk',
          status: RemoteTaskStatus.needsAction,
        ),
      ),
      'post-walk task creation',
    );
    _requireContains(
      await _allTasks(source.id),
      insertedDuringWalk.id,
      'clean task walk',
    );

    // API-003/API-004: current writes land, stale task ETags are rejected, and
    // a repeated current write advances the remote version.
    // Creating or positioning another task may rewrite sibling ordering and
    // therefore invalidate an earlier task representation. Re-read the exact
    // mutation base instead of treating the creation response as current.
    final patchBase = _liveTask(await _allTasks(source.id), first.id);
    final firstEtag = _requiredEtag(patchBase);
    final updated = _expectLiveTask(
      await service.patchTask(
        PatchTaskOperation(
          taskListId: source.id,
          taskId: first.id,
          etag: firstEtag,
          title: '$prefix-updated',
          notes: const OptionalFieldWrite<String>.clear(),
          status: RemoteTaskStatus.needsAction,
          due: const OptionalFieldWrite<RemoteDate>.set(
            RemoteDate(2026, 8, 10),
          ),
        ),
      ),
      'current task patch',
    );
    final stalePatch = await service.patchTask(
      PatchTaskOperation(
        taskListId: source.id,
        taskId: first.id,
        etag: firstEtag,
        title: '$prefix-must-not-land',
        notes: const OptionalFieldWrite<String>.clear(),
        status: RemoteTaskStatus.completed,
        due: const OptionalFieldWrite<RemoteDate>.clear(),
      ),
    );
    if (stalePatch case RejectedMutation<RemoteTask>(:final error)) {
      if (error.kind != GoogleTasksErrorKind.conditional) {
        throw StateError('API-003 stale patch had the wrong classification.');
      }
    } else {
      throw StateError('API-003 stale task ETag was not rejected.');
    }
    final replayed = _expectLiveTask(
      await service.patchTask(
        PatchTaskOperation(
          taskListId: source.id,
          taskId: first.id,
          etag: _requiredEtag(updated),
          title: '$prefix-updated',
          notes: const OptionalFieldWrite<String>.clear(),
          status: RemoteTaskStatus.needsAction,
          due: const OptionalFieldWrite<RemoteDate>.set(
            RemoteDate(2026, 8, 10),
          ),
        ),
      ),
      'repeated current task patch',
    );
    if (_requiredEtag(replayed) == _requiredEtag(updated)) {
      throw StateError('API-004 repeated patch did not change its version.');
    }
    final renamed = _expectCommitted(
      await service.renameTaskList(
        RenameTaskListOperation(
          taskListId: source.id,
          title: '$prefix-renamed',
        ),
      ),
      'list rename',
    );
    if (renamed.id != source.id) {
      throw StateError('API-003 list rename changed remote identity.');
    }

    final duplicateA = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-duplicate',
          status: RemoteTaskStatus.needsAction,
        ),
      ),
      'first duplicate create',
    );
    final duplicateB = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-duplicate',
          status: RemoteTaskStatus.needsAction,
        ),
      ),
      'second duplicate create',
    );
    if (duplicateA.id == duplicateB.id) {
      throw StateError('API-004 identical creates reused an ID.');
    }

    final deleteReplay = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-delete-replay',
          status: RemoteTaskStatus.needsAction,
        ),
      ),
      'delete replay task creation',
    );
    final deleteOperation = DeleteTaskOperation(
      taskListId: source.id,
      taskId: deleteReplay.id,
      etag: _requiredEtag(deleteReplay),
      pathFreshness: MutationPathFreshness.current,
    );
    _expectCommitted<void>(
      await service.deleteTask(deleteOperation),
      'task delete',
    );
    final deleteReplayResult = await service.deleteTask(deleteOperation);
    if (deleteReplayResult case RejectedMutation<void>(:final error)) {
      if (error.kind != GoogleTasksErrorKind.conditional) {
        throw const GoogleContractAssertionException(
          'stale task-delete replay had the wrong classification',
        );
      }
    } else {
      throw const GoogleContractAssertionException(
        'stale task-delete replay was not rejected',
      );
    }
    if (!_task(await _allTasks(source.id), deleteReplay.id).deleted) {
      throw const GoogleContractAssertionException(
        'stale task-delete replay did not preserve the tombstone',
      );
    }

    // API-005/API-009: hierarchy semantics, cross-list identity, stale paths,
    // tombstones, and admitted JSON-null field clearing.
    final destination = _expectCommitted(
      await service.createTaskList(
        CreateTaskListOperation(title: '$prefix-destination'),
      ),
      'destination list creation',
    );
    final moveBase = _liveTask(await _allTasks(source.id), second.id);
    final moved = _expectLiveTask(
      await service.moveTask(
        MoveTaskOperation(
          sourceTaskListId: source.id,
          destinationTaskListId: destination.id,
          taskId: moveBase.id,
          etag: _requiredEtag(moveBase),
          pathFreshness: MutationPathFreshness.current,
        ),
      ),
      'cross-list move',
    );
    if (moved.id != second.id) {
      throw StateError('API-005 cross-list move changed task identity.');
    }
    final staleDelete = await service.deleteTask(
      DeleteTaskOperation(
        taskListId: source.id,
        taskId: moveBase.id,
        etag: _requiredEtag(moveBase),
        pathFreshness: MutationPathFreshness.possiblyStale,
      ),
    );
    if (staleDelete case UncertainMutation<void>(:final error)) {
      if (error.kind != GoogleTasksErrorKind.stalePath) {
        throw StateError('API-009 stale delete had the wrong classification.');
      }
    } else {
      throw StateError('API-009 stale-source delete was not kept uncertain.');
    }

    final parent = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-parent',
          status: RemoteTaskStatus.needsAction,
        ),
      ),
      'parent creation',
    );
    final child = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-child',
          status: RemoteTaskStatus.needsAction,
          parentId: parent.id,
        ),
      ),
      'child creation',
    );
    final parentCompletionBase = _liveTask(
      await _allTasks(source.id),
      parent.id,
    );
    final completedParent = _expectLiveTask(
      await service.patchTask(
        PatchTaskOperation(
          taskListId: source.id,
          taskId: parentCompletionBase.id,
          etag: _requiredEtag(parentCompletionBase),
          title: parentCompletionBase.title,
          notes: const OptionalFieldWrite<String>.clear(),
          status: RemoteTaskStatus.completed,
          due: const OptionalFieldWrite<RemoteDate>.clear(),
        ),
      ),
      'parent completion',
    );
    if (completedParent.status != RemoteTaskStatus.completed ||
        _liveTask(await _allTasks(source.id), child.id).status !=
            RemoteTaskStatus.completed) {
      throw StateError('API-005 parent completion did not cascade.');
    }
    final parentDeleteBase = _liveTask(await _allTasks(source.id), parent.id);
    _expectCommitted<void>(
      await service.deleteTask(
        DeleteTaskOperation(
          taskListId: source.id,
          taskId: parentDeleteBase.id,
          etag: _requiredEtag(parentDeleteBase),
          pathFreshness: MutationPathFreshness.current,
        ),
      ),
      'parent deletion',
    );
    final tombstones = await _allTasks(source.id);
    if (!_task(tombstones, parent.id).deleted ||
        !_task(tombstones, child.id).deleted) {
      throw StateError('API-005 parent deletion did not retain tombstones.');
    }

    final clearBase = _liveTask(await _allTasks(source.id), first.id);
    final cleared = _expectLiveTask(
      await service.patchTask(
        PatchTaskOperation(
          taskListId: source.id,
          taskId: clearBase.id,
          etag: _requiredEtag(clearBase),
          title: clearBase.title,
          notes: const OptionalFieldWrite<String>.clear(),
          status: RemoteTaskStatus.needsAction,
          due: const OptionalFieldWrite<RemoteDate>.clear(),
        ),
      ),
      'JSON-null clearing',
    );
    if (cleared.notes != null || cleared.due != null) {
      throw StateError('API-009 JSON-null clearing did not survive decoding.');
    }
    final dueReadBack = _expectLiveTask(
      await service.createTask(
        CreateTaskOperation(
          taskListId: source.id,
          title: '$prefix-utc-due',
          status: RemoteTaskStatus.needsAction,
          due: const RemoteDate(2026, 8, 10),
        ),
      ),
      'due-date creation',
    );
    if (dueReadBack.due != const RemoteDate(2026, 8, 10)) {
      throw StateError('API-009 due date did not round-trip as a date.');
    }

    final currentFirst = _liveTask(await _allTasks(source.id), first.id);
    if (requireWebViewLink &&
        !hasGoogleTasksWebViewLinkShape(currentFirst.webViewLink?.toString())) {
      throw StateError('P10 did not return a valid Google Tasks web link.');
    }

    return GoogleTasksContractResult(
      prefix: prefix,
      webViewLinkObserved: currentFirst.webViewLink != null,
    );
  }

  Future<List<RemoteTaskList>> _allTaskLists() async {
    final values = <RemoteTaskList>[];
    PageToken? token;
    do {
      final page = _expectPage(
        await service.listTaskLists(pageToken: token),
        'task-list enumeration',
      );
      values.addAll(page.items);
      token = page.nextPageToken;
    } while (token != null);
    return values;
  }

  Future<List<RemoteTask>> _allTasks(RemoteTaskListId listId) async {
    final values = <RemoteTask>[];
    PageToken? token;
    do {
      final page = _expectPage(
        await service.listTasks(listId, pageToken: token),
        'task enumeration',
      );
      values.addAll(page.items);
      token = page.nextPageToken;
    } while (token != null);
    return values;
  }
}

final class GoogleTasksContractResult {
  const GoogleTasksContractResult({
    required this.prefix,
    required this.webViewLinkObserved,
  }) : cleanupOnly = false;

  const GoogleTasksContractResult.cleanupOnly()
    : prefix = '',
      webViewLinkObserved = false,
      cleanupOnly = true;

  final String prefix;
  final bool webViewLinkObserved;
  final bool cleanupOnly;
}

final class GoogleTasksContractProbeException implements Exception {
  const GoogleTasksContractProbeException(this.cleanupPrefix, this.cause);

  final String cleanupPrefix;
  final Object cause;

  @override
  String toString() {
    final safeCause = switch (cause) {
      GoogleContractAssertionException(:final message) => message,
      _ => cause.runtimeType.toString(),
    };
    return 'Google Tasks contract probe failed. '
        'Cleanup prefix: $cleanupPrefix. Cause: $safeCause.';
  }
}

final class GoogleContractAssertionException implements Exception {
  const GoogleContractAssertionException(this.message);

  final String message;

  @override
  String toString() => 'GoogleContractAssertionException: $message';
}

T _expectCommitted<T>(GoogleTasksMutationResult<T> result, String operation) {
  if (result case CommittedMutation<T>(:final value)) return value;
  final classification = switch (result) {
    RejectedMutation<T>(:final error) =>
      'rejected:${error.kind.name}:${error.failure.code}',
    UncertainMutation<T>(:final error) =>
      'uncertain:${error.kind.name}:${error.failure.code}',
    _ => 'unexpected:${result.runtimeType}',
  };
  throw GoogleContractAssertionException(
    '$operation did not commit through the Google adapter ($classification).',
  );
}

RemoteLiveTask _expectLiveTask(
  GoogleTasksMutationResult<RemoteTask> result,
  String operation,
) {
  final value = _expectCommitted(result, operation);
  if (value case RemoteLiveTask()) return value;
  throw StateError('$operation returned a task tombstone.');
}

RemotePage<T> _expectPage<T>(Outcome<RemotePage<T>> result, String operation) {
  if (result case Success<RemotePage<T>>(:final value)) return value;
  throw StateError('$operation failed through the Google adapter.');
}

String _requiredEtag(RemoteTask task) {
  final value = task.etag;
  if (value == null || value.isEmpty) {
    throw StateError('Google response lacked a task ETag.');
  }
  return value;
}

void _requireListShape(RemoteTaskList value) {
  if (value.id.value.isEmpty ||
      value.etag == null ||
      value.etag!.isEmpty ||
      value.title.isEmpty ||
      value.updated == null) {
    throw StateError('Google response lacked required task-list fields.');
  }
}

void _requireTaskShape(RemoteLiveTask value) {
  if (value.id.value.isEmpty ||
      value.etag == null ||
      value.etag!.isEmpty ||
      value.title.isEmpty ||
      value.position.isEmpty) {
    throw StateError('Google response lacked required task fields.');
  }
}

void _requireContains(
  List<RemoteTask> tasks,
  RemoteTaskId id,
  String operation,
) {
  if (!tasks.any((task) => task.id == id)) {
    throw StateError('$operation omitted a known task.');
  }
}

RemoteTask _task(List<RemoteTask> tasks, RemoteTaskId id) {
  for (final task in tasks) {
    if (task.id == id) return task;
  }
  throw StateError('Task enumeration omitted a known identity.');
}

RemoteLiveTask _liveTask(List<RemoteTask> tasks, RemoteTaskId id) {
  final value = _task(tasks, id);
  if (value case RemoteLiveTask()) return value;
  throw StateError('Expected a live task but received a tombstone.');
}

String newGoogleContractPrefix() {
  final now = DateTime.now().toUtc();
  final timestamp =
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}'
      'T${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}Z';
  final suffix = Random.secure()
      .nextInt(0x100000000)
      .toRadixString(36)
      .padLeft(7, '0');
  return 'axiotask-contract-probe-$timestamp-$suffix';
}
