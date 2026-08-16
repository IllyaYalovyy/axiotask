import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/app_bootstrap.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/composition/release_composition.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/features/backup/account_backup_view.dart';
import 'src/features/diagnostics/diagnostics_view.dart';

export 'src/app/axiotask_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = await ReleaseComposition.open(
    linuxReadConfiguration: const LinuxReadConfiguration(
      clientId: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID'),
      clientSecret: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_SECRET'),
    ),
  );
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  runApp(
    AxiotaskBootstrap(
      diagnostics: composition.diagnostics,
      accountBackupBuilder: Platform.isLinux
          ? (_, accountId, repository) => AccountBackupHost(
              accountId: accountId,
              repository: repository,
              exporter: const LocalAccountBackupExporter(
                FileSelectorAccountBackupSaveLocationPicker(),
              ),
              clock: composition.clock,
            )
          : null,
      diagnosticsBuilder: (_) => ReleaseDiagnosticsHost(
        history: composition.diagnosticHistory,
        exporter: composition.diagnosticExporter,
      ),
      openRuntime: () => TasksFeatureRuntime.open(
        composition,
        lifecycle: lifecycle,
        connectivity: connectivity,
      ),
    ),
  );
}
