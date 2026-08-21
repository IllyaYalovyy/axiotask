import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_google_tasks_service.dart';
import 'google_contract_harness.dart';
import 'google_tasks_adapter_contract.dart';

const _subject = 'dedicated-contract-subject';
const _accountSubject = AccountSubject(_subject);

void main() {
  test(
    'contract qualifies the stateful fake and cleans all probe data',
    () async {
      final service = FakeGoogleTasksService(
        taskListPageSize: 1,
        taskPageSize: 2,
      );
      addTearDown(service.close);
      final contract = GoogleTasksAdapterContract(
        service: service,
        expectedSubject: _subject,
        resolveAuthenticatedSubject: () async => _subject,
        requireWebViewLink: false,
      );

      final result = await contract.run();

      expect(result.cleanupOnly, isFalse);
      expect(service.taskCount, 0);
    },
  );

  test(
    'contract qualifies the shipped HTTP adapter over the stateful fake',
    () async {
      final service = _httpService();
      addTearDown(service.close);
      final contract = GoogleTasksAdapterContract(
        service: service,
        expectedSubject: _subject,
        resolveAuthenticatedSubject: () async => _subject,
        requireWebViewLink: false,
      );

      final result = await contract.run();

      expect(result.cleanupOnly, isFalse);
    },
  );

  test('cleanup-only rejects every broad or malformed prefix', () async {
    final service = FakeGoogleTasksService();
    addTearDown(service.close);
    final contract = GoogleTasksAdapterContract(
      service: service,
      expectedSubject: _subject,
      resolveAuthenticatedSubject: () async => _subject,
      requireWebViewLink: false,
    );

    await expectLater(
      () => contract.run(cleanupPrefix: 'axiotask-contract-probe-'),
      throwsA(isA<GoogleContractSafetyException>()),
    );
  });

  test('failure reports the exact safe prefix for recovery cleanup', () async {
    final service = FakeGoogleTasksService();
    addTearDown(service.close);
    const prefix = 'axiotask-contract-probe-20260820T120000Z-a1b2c3';
    final contract = GoogleTasksAdapterContract(
      service: service,
      expectedSubject: _subject,
      resolveAuthenticatedSubject: () async => 'wrong-subject',
      requireWebViewLink: false,
    );

    await expectLater(
      () => contract.run(cleanupPrefix: prefix),
      throwsA(
        isA<GoogleTasksContractProbeException>().having(
          (error) => error.cleanupPrefix,
          'cleanupPrefix',
          prefix,
        ),
      ),
    );
  });
}

GoogleTasksService _httpService() {
  final backend = FakeGoogleTasksService(taskListPageSize: 1, taskPageSize: 2);
  return HttpGoogleTasksService(
    client: FakeGoogleTasksHttpClient(backend),
    authorization: const SyntheticAuthorization(_accountSubject),
    accountGuard: const DedicatedAccountGuard(_accountSubject),
    diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
    endpoint: FakeGoogleTasksHttpClient.endpoint,
  );
}
