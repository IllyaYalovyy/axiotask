import 'dart:io';

import 'package:axiotask/src/app/composition/development_composition.dart';
import 'package:axiotask/src/app/composition/linux_read_transport.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/google_contract/google_tasks_adapter_contract.dart';

const _clientId = String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID');
const _clientSecret = String.fromEnvironment(
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET',
);
const _subjectFile = String.fromEnvironment('AXIOTASK_LINUX_AUTH_SUBJECT_FILE');
const _interactive = bool.fromEnvironment(
  'AXIOTASK_GOOGLE_CONTRACT_INTERACTIVE',
);
const _cleanupPrefix = String.fromEnvironment(
  'AXIOTASK_GOOGLE_CONTRACT_CLEANUP_PREFIX',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'shipped Linux adapters satisfy the dedicated Google Tasks contract',
    (tester) async {
      final expectedSubject = await _readExpectedSubject();
      final composition = DevelopmentComposition.create(
        expectedDedicatedSubject: expectedSubject,
        linuxReadConfiguration: LinuxReadConfiguration(
          clientId: _clientId,
          clientSecret: _clientSecret,
        ),
      );
      final transport = await composition.createReadTransport(expectedSubject);
      addTearDown(transport.close);

      var authorization = await transport.authorization
          .restoreTasksAuthorization();
      if (authorization case Failed<AccountSubject>()) {
        if (!_interactive) {
          throw StateError(
            'Development authorization is unavailable. Run the explicit '
            'interactive Linux acceptance command.',
          );
        }
        authorization = await transport.authorization
            .requestTasksAuthorization();
      }
      final subject = switch (authorization) {
        Success<AccountSubject>(:final value) => value,
        Failed<AccountSubject>(:final failure) => throw StateError(
          'Linux authorization failed: ${failure.code}.',
        ),
      };
      if (subject != expectedSubject) {
        throw StateError('The authenticated account did not match the pin.');
      }

      final contract = GoogleTasksAdapterContract(
        service: transport.googleTasks,
        expectedSubject: expectedSubject.value,
        resolveAuthenticatedSubject: () async =>
            switch (transport.authorization.currentState) {
              TasksAuthorized(:final subject) => subject.value,
              _ => null,
            },
        requireWebViewLink: _cleanupPrefix.isEmpty,
      );
      final probePrefix = _cleanupPrefix.isEmpty
          ? newGoogleContractPrefix()
          : null;
      if (probePrefix != null) {
        debugPrint('Google contract cleanup prefix: $probePrefix');
      }
      final result = await contract.run(
        cleanupPrefix: _cleanupPrefix.isEmpty ? null : _cleanupPrefix,
        probePrefix: probePrefix,
      );
      if (!result.cleanupOnly && !result.webViewLinkObserved) {
        throw StateError('The live contract did not observe webViewLink.');
      }
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<AccountSubject> _readExpectedSubject() async {
  if (_clientId.isEmpty ||
      !_clientId.endsWith('.apps.googleusercontent.com') ||
      _clientSecret.isEmpty ||
      _subjectFile.isEmpty) {
    throw StateError('Linux contract-probe configuration is incomplete.');
  }
  final file = File(_subjectFile);
  final value = await file.readAsString();
  final subject = AccountSubject(value.trim());
  if (subject.isEmpty) {
    throw StateError('The dedicated account subject is not pinned.');
  }
  return subject;
}
