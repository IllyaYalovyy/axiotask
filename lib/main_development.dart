import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/development_composition.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/auth/authorization.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/features/backup/account_backup_view.dart';
import 'src/features/diagnostics/development_diagnostics_view.dart';

const String _expectedSubject = String.fromEnvironment(
  'AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = await DevelopmentComposition.open(
    expectedDedicatedSubject: _expectedSubject.isEmpty
        ? null
        : const AccountSubject(_expectedSubject),
    linuxReadConfiguration: const LinuxReadConfiguration(
      clientId: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID'),
      clientSecret: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_SECRET'),
    ),
  );
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  final runtime = await TasksFeatureRuntime.open(
    composition,
    lifecycle: lifecycle,
    connectivity: connectivity,
  );
  runApp(
    AxiotaskApp(
      viewModel: runtime.viewModel,
      accountBackupBuilder:
          Platform.isLinux && runtime.accountBackupRepository != null
          ? (_) => AccountBackupHost(
              accountId: runtime.viewModel.accountId,
              repository: runtime.accountBackupRepository!,
              exporter: const LocalAccountBackupExporter(
                FileSelectorAccountBackupSaveLocationPicker(),
              ),
              clock: composition.clock,
            )
          : null,
      diagnosticsBuilder: (_) => DevelopmentDiagnosticsHost(
        history: composition.diagnosticHistory,
        exporter: composition.diagnosticExporter,
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runtime.start());
  });
}
