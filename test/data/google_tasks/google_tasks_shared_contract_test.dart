import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_google_tasks_service.dart';
import '../../support/google_tasks_contract.dart';

const _subject = AccountSubject('synthetic-contract-subject');

void main() {
  defineGoogleTasksServiceContract(
    'stateful fake',
    () => FakeGoogleTasksService(taskListPageSize: 2, taskPageSize: 2),
  );
  defineGoogleTasksServiceContract('HTTP adapter', _httpService);

  test(
    'fake and HTTP adapter expose equal shared observable outcomes',
    () async {
      final fake = FakeGoogleTasksService();
      final http = _httpService();
      addTearDown(fake.close);
      addTearDown(http.close);

      expect(
        await observeGoogleTasksContract(http),
        await observeGoogleTasksContract(fake),
      );
    },
  );
}

GoogleTasksService _httpService() {
  final backend = FakeGoogleTasksService(taskListPageSize: 2, taskPageSize: 2);
  return HttpGoogleTasksService(
    client: FakeGoogleTasksHttpClient(backend),
    authorization: const SyntheticAuthorization(_subject),
    accountGuard: const DedicatedAccountGuard(_subject),
    diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
    endpoint: FakeGoogleTasksHttpClient.endpoint,
  );
}
