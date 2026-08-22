import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/development_composition.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/config/linux_profile_configuration.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/features/backup/account_backup_view.dart';
import 'src/features/diagnostics/development_diagnostics_view.dart';
import 'src/features/recovery/local_data_recovery_view.dart';
import 'src/features/recovery/local_data_recovery_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final linuxConfiguration = Platform.isLinux
      ? await _loadLinuxConfiguration()
      : null;
  final composition = await DevelopmentComposition.open(
    expectedDedicatedSubject: linuxConfiguration?.dedicatedAccountSubject,
    linuxReadConfiguration:
        linuxConfiguration?.google ??
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
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
              restoreRepository: runtime.accountBackupRestoreRepository,
              importer: const LocalAccountBackupImporter(
                FileSelectorAccountBackupOpenLocationPicker(),
              ),
              syncHealthRepository: runtime.syncHealthRepository,
              importCommitted: runtime.viewModel.localEditCommitted,
            )
          : null,
      localDataRecoveryBuilder:
          runtime.localDataRecoveryService == null ||
              runtime.syncHealthRepository == null
          ? null
          : (_) => LocalDataRecoveryHost(
              viewModel: LocalDataRecoveryViewModel(
                accountId: runtime.viewModel.accountId,
                recovery: runtime.localDataRecoveryService!,
                healthRepository: runtime.syncHealthRepository!,
              ),
            ),
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

Future<LinuxProfileConfiguration> _loadLinuxConfiguration() async {
  try {
    return await LinuxProfileConfiguration.load(
      profile: LinuxApplicationProfile.development,
    );
  } on LinuxProfileConfigurationException catch (error) {
    stderr.writeln(error);
    exit(78);
  }
}
