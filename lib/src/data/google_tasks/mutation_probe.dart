import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/outcome.dart';
import '../../core/randomness.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../sync/engine.dart';
import '../../sync/run.dart';
import '../auth/authorization.dart';
import '../auth/linux/browser_flow.dart';
import '../auth/linux/linux_authorization.dart';
import '../auth/linux/secure_credentials.dart';
import '../database/account_backup_repository.dart';
import '../database/app_database.dart';
import '../database/read_sync_store.dart';
import '../database/sync_health_dao.dart';
import '../database/tasks_repository.dart';
import 'dto.dart';
import 'http_service.dart';
import 'mutation.dart';

final class GoogleTasksMutationProbeConfiguration {
  GoogleTasksMutationProbeConfiguration({
    required this.clientId,
    required this.clientSecret,
    required this.subjectFile,
    required this.instanceName,
  }) {
    if (!clientId.endsWith('.apps.googleusercontent.com') ||
        clientSecret.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(instanceName)) {
      throw ArgumentError(
        'Google Tasks mutation probe configuration is invalid.',
      );
    }
  }

  final String clientId;
  final String clientSecret;
  final File subjectFile;
  final String instanceName;
}

final class GoogleTasksMutationProbeResult {
  const GoogleTasksMutationProbeResult({
    required this.notesNullClearing,
    required this.dueNullClearing,
    required this.staleSourceDeleteStatus,
    required this.destinationTaskLiveAfterStaleDelete,
    required this.destinationTaskDeletedAfterStaleDelete,
    required this.restoreImportEmptyList,
  });

  final bool notesNullClearing;
  final bool dueNullClearing;
  final int staleSourceDeleteStatus;
  final bool destinationTaskLiveAfterStaleDelete;
  final bool destinationTaskDeletedAfterStaleDelete;
  final bool restoreImportEmptyList;

  Map<String, Object> toRecord() => <String, Object>{
    'status': 'passed',
    'accountClass': 'dedicated-test',
    'subjectGuardVerified': true,
    'notesNullClearing': notesNullClearing,
    'dueNullClearing': dueNullClearing,
    'staleSourceDeleteStatus': staleSourceDeleteStatus,
    'destinationTaskLiveAfterStaleDelete': destinationTaskLiveAfterStaleDelete,
    'destinationTaskDeletedAfterStaleDelete':
        destinationTaskDeletedAfterStaleDelete,
    'restoreImportEmptyList': restoreImportEmptyList,
    'cleanupZeroMatchesVerified': true,
    'credentialCleanupVerified': true,
  };
}

final class GoogleTasksMutationProbeException implements Exception {
  GoogleTasksMutationProbeException({
    required Object primary,
    required Iterable<DiagnosticRecord> diagnostics,
    Object? cleanup,
  }) : _primary = const CredentialRedactor().redact(primary),
       _cleanup = cleanup == null
           ? null
           : const CredentialRedactor().redact(cleanup),
       _diagnostics = List<DiagnosticRecord>.unmodifiable(diagnostics);

  final String _primary;
  final String? _cleanup;
  final List<DiagnosticRecord> _diagnostics;

  @override
  String toString() {
    final buffer = StringBuffer(
      'Google Tasks mutation probe failed: $_primary',
    );
    if (_cleanup case final cleanup?) {
      buffer.write('\nCleanup also failed: $cleanup');
    }
    if (_diagnostics.isNotEmpty) {
      buffer.write('\nDevelopment diagnostics:');
      for (final record in _diagnostics) {
        buffer.write('\n- ${record.renderedText}');
      }
    }
    return buffer.toString();
  }
}

Future<GoogleTasksMutationProbeResult> runGoogleTasksMutationProbe(
  GoogleTasksMutationProbeConfiguration configuration,
) async {
  if (!await configuration.subjectFile.exists() ||
      (await configuration.subjectFile.readAsString()).trim().isEmpty) {
    throw StateError('The dedicated account subject must already be pinned.');
  }

  final history = InMemoryDiagnosticHistory();
  final diagnostics = SensitiveDevelopmentDiagnosticSink(history);
  final credentialStore = LinuxSecureCredentialStore(
    namespace: 'dev.axiotask.axiotask.probe.s07.${configuration.instanceName}',
    storage: FlutterSecureStorageValueStore(),
    diagnostics: diagnostics,
  );
  final subjectStore = FilePinnedSubjectStore(configuration.subjectFile);
  final auth = _createAuthorization(
    configuration: configuration,
    credentialStore: credentialStore,
    subjectStore: subjectStore,
    diagnostics: diagnostics,
  );

  Object? primaryError;
  StackTrace? primaryStack;
  Object? cleanupError;
  GoogleTasksMutationProbeResult? result;
  HttpGoogleTasksService? service;
  final createdLists = <RemoteTaskListId>[];
  String? prefix;
  try {
    await _expectVoid(credentialStore.delete(), 'initial credential cleanup');
    final session = await _expectSession(
      auth.connect(),
      'dedicated authorization',
    );
    final pinned = await subjectStore.read();
    if (pinned is! Success<AccountSubject?> ||
        pinned.value != session.subject) {
      throw StateError(
        'The authenticated subject did not match the pinned subject.',
      );
    }
    service = HttpGoogleTasksService(
      client: session.authenticatedClient,
      authorization: auth,
      accountGuard: DedicatedAccountGuard(session.subject),
      diagnostics: diagnostics,
      mutationCapabilities: const GoogleTasksMutationCapabilities(
        notesNullClearing: true,
        dueNullClearing: true,
      ),
    );
    prefix = _probePrefix();
    final mutationResult = await _runOperations(service, prefix, createdLists);
    final restoreImportEmptyList = await _runRestoreImportSmoke(
      service: service,
      authorization: auth,
      subject: session.subject,
      prefix: prefix,
      createdLists: createdLists,
    );
    result = GoogleTasksMutationProbeResult(
      notesNullClearing: mutationResult.notesNullClearing,
      dueNullClearing: mutationResult.dueNullClearing,
      staleSourceDeleteStatus: mutationResult.staleSourceDeleteStatus,
      destinationTaskLiveAfterStaleDelete:
          mutationResult.destinationTaskLiveAfterStaleDelete,
      destinationTaskDeletedAfterStaleDelete:
          mutationResult.destinationTaskDeletedAfterStaleDelete,
      restoreImportEmptyList: restoreImportEmptyList,
    );
  } catch (error, stackTrace) {
    primaryError = error;
    primaryStack = stackTrace;
  }

  final cleanupFailures = <Object>[];
  if (service != null) {
    for (final id in createdLists.reversed) {
      try {
        await _expectCommitted<void>(
          service.deleteTaskList(DeleteTaskListOperation(id)),
          'scratch-list cleanup',
        );
      } catch (error) {
        cleanupFailures.add(error);
      }
    }
    if (prefix != null) {
      try {
        final lists = await _allTaskLists(service);
        if (lists.any((list) => list.title.startsWith(prefix!))) {
          throw StateError('Disposable probe-list cleanup was not complete.');
        }
      } catch (error) {
        cleanupFailures.add(error);
      }
    }
    try {
      service.close();
    } catch (error) {
      cleanupFailures.add(error);
    }
  }
  auth.close();
  try {
    await _expectVoid(credentialStore.delete(), 'final credential cleanup');
    final stored = await credentialStore.read();
    if (stored is! Success<CredentialBundle?> || stored.value != null) {
      throw StateError('Final credential cleanup could not be verified.');
    }
  } catch (error) {
    cleanupFailures.add(error);
  }
  if (cleanupFailures.isNotEmpty) {
    cleanupError = StateError(
      'Cleanup failed in ${cleanupFailures.length} phase(s): '
      '${cleanupFailures.map(const CredentialRedactor().redact).join('; ')}',
    );
  }

  if (primaryError != null) {
    Error.throwWithStackTrace(
      GoogleTasksMutationProbeException(
        primary: primaryError,
        cleanup: cleanupError,
        diagnostics: history.records,
      ),
      primaryStack!,
    );
  }
  if (cleanupError != null) {
    throw GoogleTasksMutationProbeException(
      primary: cleanupError,
      diagnostics: history.records,
    );
  }
  return result!;
}

Future<GoogleTasksMutationProbeResult> _runOperations(
  HttpGoogleTasksService service,
  String prefix,
  List<RemoteTaskListId> createdLists,
) async {
  final listA = await _expectCommitted<RemoteTaskList>(
    service.createTaskList(CreateTaskListOperation(title: '$prefix-a')),
    'create scratch list A',
  );
  createdLists.add(listA.id);
  final listB = await _expectCommitted<RemoteTaskList>(
    service.createTaskList(CreateTaskListOperation(title: '$prefix-b')),
    'create scratch list B',
  );
  createdLists.add(listB.id);

  final clearTask = await _expectLiveTask(
    service.createTask(
      CreateTaskOperation(
        taskListId: listA.id,
        title: '$prefix-clear',
        notes: 'synthetic notes',
        status: RemoteTaskStatus.needsAction,
        due: const RemoteDate(2026, 8, 16),
      ),
    ),
    'create optional-field task',
  );
  final cleared = await _expectLiveTask(
    service.patchTask(
      PatchTaskOperation(
        taskListId: listA.id,
        taskId: clearTask.id,
        etag: _requiredEtag(clearTask),
        title: clearTask.title,
        notes: const OptionalFieldWrite<String>.clear(),
        status: clearTask.status,
        due: const OptionalFieldWrite<RemoteDate>.clear(),
      ),
    ),
    'clear optional fields with JSON null',
  );
  final clearedReadback = await _findTask(service, listA.id, cleared.id);
  if (clearedReadback is! RemoteLiveTask ||
      clearedReadback.notes != null ||
      clearedReadback.due != null) {
    throw StateError('JSON null did not clear optional fields on read-back.');
  }

  final moving = await _expectLiveTask(
    service.createTask(
      CreateTaskOperation(
        taskListId: listA.id,
        title: '$prefix-stale-delete',
        status: RemoteTaskStatus.needsAction,
      ),
    ),
    'create stale-delete task',
  );
  final moved = await _expectLiveTask(
    service.moveTask(
      MoveTaskOperation(
        sourceTaskListId: listA.id,
        taskId: moving.id,
        etag: _requiredEtag(moving),
        destinationTaskListId: listB.id,
        pathFreshness: MutationPathFreshness.current,
      ),
    ),
    'move task across lists',
  );
  final staleDelete = await service.deleteTask(
    DeleteTaskOperation(
      taskListId: listA.id,
      taskId: moved.id,
      etag: _requiredEtag(moved),
      pathFreshness: MutationPathFreshness.possiblyStale,
    ),
  );
  if (staleDelete is! UncertainMutation<void>) {
    throw StateError('A stale-source DELETE was not preserved as uncertain.');
  }
  final staleStatus = staleDelete.error.failure.remoteContext?.statusCode;
  if (staleStatus == null) {
    throw StateError('The stale-source DELETE did not return an HTTP status.');
  }
  final destinationTask = await _findTask(service, listB.id, moved.id);
  if (destinationTask == null) {
    throw StateError(
      'The moved task was absent without positive deletion evidence.',
    );
  }

  return GoogleTasksMutationProbeResult(
    notesNullClearing: true,
    dueNullClearing: true,
    staleSourceDeleteStatus: staleStatus,
    destinationTaskLiveAfterStaleDelete: !destinationTask.deleted,
    destinationTaskDeletedAfterStaleDelete: destinationTask.deleted,
    restoreImportEmptyList: false,
  );
}

Future<bool> _runRestoreImportSmoke({
  required HttpGoogleTasksService service,
  required LinuxAuthorization authorization,
  required AccountSubject subject,
  required String prefix,
  required List<RemoteTaskListId> createdLists,
}) async {
  final database = AppDatabase.inMemory();
  final clock = SystemClock();
  final listTitle = '$prefix-restore';
  try {
    final accountId = AccountId(await database.createAccount(subject.value));
    final initial = await SyncEngine(
      store: DatabaseReadSyncStore(database),
      googleTasks: service,
      authorization: authorization,
      clock: clock,
      random: SecureRandomSource(),
    ).run(SyncRunRequest(accountId: accountId));
    if (initial.outcome != SyncRunOutcome.succeeded) {
      throw StateError(
        'restore smoke initial sync failed: ${initial.failure?.code}',
      );
    }
    final facts = await SyncHealthDao(database).watchFacts(accountId).first;
    final successAt = facts.lastSuccessfulSyncAt;
    if (successAt == null) {
      throw StateError('restore smoke did not record fresh sync evidence.');
    }
    final restored =
        await DatabaseAccountBackupRepository(
          database,
          clock: clock,
        ).restoreImport(
          accountId: accountId,
          document: AccountBackupDocument(
            format: accountBackupFormat,
            version: accountBackupVersion,
            privateDataWarning: accountBackupPrivateDataWarning,
            exportedAt: clock.now().toUtc(),
            sourceGoogleSubject: subject.value,
            lists: <AccountBackupList>[
              AccountBackupList(
                key: 'list-000001',
                googleId: null,
                title: listTitle,
                order: 0,
              ),
            ],
            tasks: <AccountBackupTask>[
              AccountBackupTask(
                key: 'task-000001',
                googleId: null,
                listKey: 'list-000001',
                parentKey: null,
                title: '$prefix-restored-task',
                notes: 'synthetic restore smoke',
                status: TaskStatus.needsAction,
                due: null,
                order: 0,
              ),
            ],
          ),
          readiness: AccountBackupImportReadiness.ready,
          lastSuccessfulSyncAt: successAt,
        );
    if (restored.createdListCount != 1 || restored.createdTaskCount != 1) {
      throw StateError('restore smoke local transaction had wrong counts.');
    }
    final published = await SyncEngine(
      store: DatabaseReadSyncStore(database),
      googleTasks: service,
      authorization: authorization,
      clock: clock,
      random: SecureRandomSource(),
    ).run(SyncRunRequest(accountId: accountId));
    if (published.outcome != SyncRunOutcome.succeeded) {
      throw StateError(
        'restore smoke publication failed: ${published.failure?.code}',
      );
    }
    final snapshot = await DatabaseTasksRepository(
      database,
    ).watchTasks(TasksQuery(accountId: accountId)).first;
    final list = snapshot.taskLists.singleWhere(
      (candidate) => candidate.title == listTitle,
    );
    final task = snapshot.tasks.singleWhere(
      (candidate) => candidate.title == '$prefix-restored-task',
    );
    final listRemoteId = list.remoteId;
    final taskRemoteId = task.remoteId;
    if (listRemoteId == null || taskRemoteId == null) {
      throw StateError('restore smoke did not bind returned Google IDs.');
    }
    createdLists.add(RemoteTaskListId(listRemoteId.value));
    final readBack = await _findTask(
      service,
      RemoteTaskListId(listRemoteId.value),
      RemoteTaskId(taskRemoteId.value),
    );
    if (readBack is! RemoteLiveTask ||
        readBack.title != '$prefix-restored-task') {
      throw StateError('restore smoke Google read-back did not match.');
    }
    return true;
  } finally {
    try {
      final matching = (await _allTaskLists(
        service,
      )).where((list) => list.title == listTitle);
      for (final list in matching) {
        if (!createdLists.contains(list.id)) createdLists.add(list.id);
      }
    } finally {
      await database.close();
    }
  }
}

LinuxAuthorization _createAuthorization({
  required GoogleTasksMutationProbeConfiguration configuration,
  required CredentialStore credentialStore,
  required PinnedSubjectStore subjectStore,
  required DiagnosticSink diagnostics,
}) => LinuxAuthorization(
  config: LinuxAuthorizationConfig.google(
    clientId: configuration.clientId,
    clientSecret: configuration.clientSecret,
  ),
  browserFlow: LinuxBrowserFlow(
    callbackFactory: const HttpLoopbackCallbackFactory(),
    browserLauncher: const SystemBrowserLauncher(),
    randomness: SecureRandomSource(),
    diagnostics: diagnostics,
  ),
  credentialStore: credentialStore,
  subjectStore: subjectStore,
  identityVerifier: GoogleIdTokenVerifier(clock: SystemClock()),
  httpClientFactory: http.Client.new,
  clock: SystemClock(),
  randomness: SecureRandomSource(),
  diagnostics: diagnostics,
);

String _probePrefix() {
  final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final suffix = SecureRandomSource()
      .nextBytes(6)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'axiotask-s07-probe-$date-$suffix';
}

String _requiredEtag(RemoteTask task) {
  final etag = task.etag;
  if (etag == null) throw StateError('A mutation response omitted its ETag.');
  return etag;
}

Future<List<RemoteTaskList>> _allTaskLists(
  HttpGoogleTasksService service,
) async {
  final lists = <RemoteTaskList>[];
  PageToken? pageToken;
  do {
    final result = await service.listTaskLists(pageToken: pageToken);
    final page = switch (result) {
      Success<RemotePage<RemoteTaskList>>(:final value) => value,
      Failed<RemotePage<RemoteTaskList>>(:final failure) => throw StateError(
        'task-list verification failed: ${failure.code}',
      ),
    };
    lists.addAll(page.items);
    pageToken = page.nextPageToken;
  } while (pageToken != null);
  return lists;
}

Future<RemoteTask?> _findTask(
  HttpGoogleTasksService service,
  RemoteTaskListId listId,
  RemoteTaskId taskId,
) async {
  PageToken? pageToken;
  do {
    final result = await service.listTasks(listId, pageToken: pageToken);
    final page = switch (result) {
      Success<RemotePage<RemoteTask>>(:final value) => value,
      Failed<RemotePage<RemoteTask>>(:final failure) => throw StateError(
        'task read-back failed: ${failure.code}',
      ),
    };
    for (final task in page.items) {
      if (task.id == taskId) return task;
    }
    pageToken = page.nextPageToken;
  } while (pageToken != null);
  return null;
}

Future<LinuxAuthorizedSession> _expectSession(
  Future<Outcome<LinuxAuthorizedSession>> operation,
  String phase,
) async => switch (await operation) {
  Success<LinuxAuthorizedSession>(:final value) => value,
  Failed<LinuxAuthorizedSession>(:final failure) => throw StateError(
    '$phase failed: ${failure.code}',
  ),
};

Future<T> _expectCommitted<T>(
  Future<GoogleTasksMutationResult<T>> operation,
  String phase,
) async => switch (await operation) {
  CommittedMutation<T>(:final value) => value,
  RejectedMutation<T>(:final error) => throw StateError(
    '$phase was rejected: ${error.failure.code}',
  ),
  UncertainMutation<T>(:final error) => throw StateError(
    '$phase was uncertain: ${error.failure.code}',
  ),
};

Future<RemoteLiveTask> _expectLiveTask(
  Future<GoogleTasksMutationResult<RemoteTask>> operation,
  String phase,
) async {
  final task = await _expectCommitted<RemoteTask>(operation, phase);
  if (task is! RemoteLiveTask) {
    throw StateError('$phase returned a tombstone.');
  }
  return task;
}

Future<void> _expectVoid(Future<Outcome<void>> operation, String phase) async {
  switch (await operation) {
    case Success<void>():
      return;
    case Failed<void>(:final failure):
      throw StateError('$phase failed: ${failure.code}');
  }
}
