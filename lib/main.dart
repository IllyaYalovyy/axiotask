import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/app_bootstrap.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/composition/release_composition.dart';
import 'src/app/config/linux_profile_configuration.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/features/backup/account_backup_view.dart';
import 'src/features/diagnostics/diagnostics_view.dart';
import 'src/features/recovery/local_data_recovery_view.dart';
import 'src/features/recovery/local_data_recovery_view_model.dart';

export 'src/app/axiotask_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final linuxConfiguration = Platform.isLinux
      ? await _loadLinuxConfiguration(LinuxApplicationProfile.production)
      : null;
  final composition = await ReleaseComposition.open(
    linuxReadConfiguration:
        linuxConfiguration?.google ??
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  );
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  runApp(
    AxiotaskBootstrap(
      diagnostics: composition.diagnostics,
      accountBackupBuilder: Platform.isLinux
          ? (
              _,
              accountId,
              repository,
              restoreRepository,
              healthRepository,
              importCommitted,
            ) => AccountBackupHost(
              accountId: accountId,
              repository: repository,
              exporter: const LocalAccountBackupExporter(
                FileSelectorAccountBackupSaveLocationPicker(),
              ),
              clock: composition.clock,
              restoreRepository: restoreRepository,
              importer: const LocalAccountBackupImporter(
                FileSelectorAccountBackupOpenLocationPicker(),
              ),
              syncHealthRepository: healthRepository,
              importCommitted: importCommitted,
            )
          : null,
      localDataRecoveryBuilder: (_, accountId, recovery, healthRepository) =>
          LocalDataRecoveryHost(
            viewModel: LocalDataRecoveryViewModel(
              accountId: accountId,
              recovery: recovery,
              healthRepository: healthRepository,
            ),
          ),
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

Future<LinuxProfileConfiguration> _loadLinuxConfiguration(
  LinuxApplicationProfile profile,
) async {
  try {
    return await LinuxProfileConfiguration.load(profile: profile);
  } on LinuxProfileConfigurationException catch (error) {
    stderr.writeln(error);
    exit(78);
  }
}
