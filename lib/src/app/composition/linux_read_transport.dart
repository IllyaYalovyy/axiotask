import 'package:http/http.dart' as http;

import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../data/auth/authorization.dart';
import '../../data/auth/linux/browser_flow.dart';
import '../../data/auth/linux/linux_authorization.dart';
import '../../data/auth/linux/secure_credentials.dart';
import '../../data/google_tasks/dto.dart';
import '../../data/google_tasks/http_service.dart';
import '../../data/google_tasks/mutation.dart';
import '../../data/google_tasks/request.dart';
import '../../data/google_tasks/service.dart';
import 'app_composition.dart';

final class LinuxReadConfiguration {
  const LinuxReadConfiguration({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;

  bool get isValid =>
      clientId.endsWith('.apps.googleusercontent.com') &&
      clientSecret.isNotEmpty;
}

Future<ReadSliceTransport> createLinuxReadTransport({
  required AppComposition composition,
  required AccountSubject? configuredSubject,
  required LinuxReadConfiguration configuration,
}) async {
  if (!configuration.isValid) {
    return ReadSliceTransport(
      authorization: const UnavailableAuthorization(),
      googleTasks: const _UnavailableGoogleTasksService(),
    );
  }
  final authorization = LinuxAuthorization(
    config: LinuxAuthorizationConfig.google(
      clientId: configuration.clientId,
      clientSecret: configuration.clientSecret,
    ),
    browserFlow: LinuxBrowserFlow(
      callbackFactory: const HttpLoopbackCallbackFactory(),
      browserLauncher: const SystemBrowserLauncher(),
      randomness: composition.randomness,
      diagnostics: composition.diagnostics,
    ),
    credentialStore: LinuxSecureCredentialStore(
      namespace: composition.boundary.storage.secureStorageNamespace,
      storage: FlutterSecureStorageValueStore(),
      diagnostics: composition.diagnostics,
    ),
    subjectStore: _ConfiguredSubjectStore(configuredSubject),
    identityVerifier: GoogleIdTokenVerifier(clock: composition.clock),
    httpClientFactory: http.Client.new,
    clock: composition.clock,
    randomness: composition.randomness,
    diagnostics: composition.diagnostics,
  );
  final googleTasks = HttpGoogleTasksService(
    client: LinuxAuthorizedHttpClient(authorization),
    authorization: authorization,
    accountGuard: composition.accountGuard,
    diagnostics: composition.diagnostics,
  );
  return ReadSliceTransport(
    authorization: authorization,
    googleTasks: googleTasks,
    closeTransport: authorization.close,
  );
}

final class _ConfiguredSubjectStore implements PinnedSubjectStore {
  const _ConfiguredSubjectStore(this.subject);

  final AccountSubject? subject;

  @override
  Future<Outcome<AccountSubject?>> read() async =>
      Outcome<AccountSubject?>.success(subject);

  @override
  Future<Outcome<void>> pin(AccountSubject candidate) async =>
      subject == null || candidate == subject
      ? const Outcome<void>.success(null)
      : Outcome<void>.failure(
          const Failure(
            code: 'account.subject_mismatch',
            category: FailureCategory.authorization,
            operation: FailureOperation.authorize,
            retry: RetryClassification.permanent,
            impact: 'Google Tasks data cannot be opened for this account.',
            action: FailureAction.connect,
            safeSummary: 'The authenticated account did not match.',
          ),
        );
}

final class _UnavailableGoogleTasksService implements GoogleTasksService {
  const _UnavailableGoogleTasksService();

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async =>
      Outcome<RemotePage<RemoteTaskList>>.failure(_configurationFailure);

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => Outcome<RemotePage<RemoteTask>>.failure(_configurationFailure);

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => throw UnsupportedError('Read-only composition.');

  @override
  void close() {}
}

const Failure _configurationFailure = Failure(
  code: 'auth.configuration',
  category: FailureCategory.configuration,
  operation: FailureOperation.initialize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks connection is unavailable.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'Linux OAuth configuration is missing or invalid.',
);
