import 'package:http/http.dart' as http;

import '../../data/auth/android/android_authorization.dart';
import '../../data/auth/authorization.dart';
import '../../data/google_tasks/http_service.dart';
import 'app_composition.dart';

ReadSliceTransport createAndroidReadTransport({
  required AppComposition composition,
  required AccountSubject? configuredSubject,
}) {
  final authorization = AndroidAuthorization(
    gateway: GoogleAndroidAuthorizationGateway(),
    identityClient: http.Client(),
    clock: composition.clock,
    expectedSubject: configuredSubject,
  );
  return ReadSliceTransport(
    authorization: authorization,
    googleTasks: HttpGoogleTasksService(
      client: AndroidAuthorizedHttpClient(authorization, http.Client()),
      authorization: authorization,
      accountGuard: composition.accountGuard,
      diagnostics: composition.diagnostics,
    ),
    closeTransport: authorization.close,
  );
}
