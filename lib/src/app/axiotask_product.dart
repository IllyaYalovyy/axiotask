import 'package:material_ui/material_ui.dart';

import '../core/clock.dart';
import '../core/diagnostics/diagnostics.dart';
import '../data/backup/android_account_backup_documents.dart';
import '../data/backup/local_account_backup_exporter.dart';
import '../data/links/url_launcher_adapter.dart';
import '../domain/repository/external_link_launcher.dart';
import '../features/about/about_view.dart';
import '../features/account/account_view.dart';
import '../features/backup/account_backup_view.dart';
import '../features/diagnostics/diagnostics_view.dart';
import '../features/recovery/local_data_recovery_view.dart';
import '../features/recovery/local_data_recovery_view_model.dart';
import '../features/sync_activity/sync_activity_view.dart';
import 'app_bootstrap.dart';
import 'app_destinations.dart';
import 'app_version.dart';
import 'haptics.dart';

/// The platform edges the shipped application needs beyond its runtime.
///
/// Chosen from the target platform in one place, so a feature can never be
/// present on one platform and silently unwired on another: the must-have
/// feature contract builds the product with these same services for Android
/// and for Linux.
final class ProductPlatformServices {
  const ProductPlatformServices({
    required this.backupExporter,
    required this.backupImporter,
    this.links = const UrlLauncherAdapter(),
    this.haptics = const PlatformHaptics(),
  });

  /// The services for [platform]: Storage Access Framework documents on
  /// Android, native file dialogs on the desktop.
  factory ProductPlatformServices.forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.android
      ? const ProductPlatformServices(
          backupExporter: AndroidDocumentAccountBackupExporter(),
          backupImporter: AndroidDocumentAccountBackupImporter(),
        )
      : const ProductPlatformServices(
          backupExporter: LocalAccountBackupExporter(
            FileSelectorAccountBackupSaveLocationPicker(),
          ),
          backupImporter: LocalAccountBackupImporter(
            FileSelectorAccountBackupOpenLocationPicker(),
          ),
        );

  final AccountBackupExporter backupExporter;
  final AccountBackupImporter backupImporter;
  final ExternalLinkLauncher links;
  final Haptics haptics;
}

/// The complete shipped application.
///
/// `main()` runs exactly this widget, and so does the must-have feature
/// contract in `test/contract/`. Wiring a screen here is what makes it part
/// of the product; nothing reachable by users is assembled anywhere else.
final class AxiotaskProduct extends StatelessWidget {
  const AxiotaskProduct({
    required this.openRuntime,
    required this.clock,
    required this.diagnostics,
    required this.diagnosticHistory,
    required this.diagnosticExporter,
    required this.services,
    this.version = appVersion,
    super.key,
  });

  final AxiotaskRuntimeOpener openRuntime;
  final Clock clock;
  final DiagnosticSink diagnostics;
  final DiagnosticHistory diagnosticHistory;
  final DiagnosticExportPort diagnosticExporter;
  final ProductPlatformServices services;
  final String version;

  void _supportProject() => services.links.launch(supportProjectUri);

  @override
  Widget build(BuildContext context) => AxiotaskBootstrap(
    diagnostics: diagnostics,
    hapticsDevice: services.haptics,
    openRuntime: openRuntime,
    accountBackupBuilder:
        (
          _,
          accountId,
          repository,
          restoreRepository,
          healthRepository,
          importCommitted,
        ) => AccountBackupHost(
          accountId: accountId,
          repository: repository,
          exporter: services.backupExporter,
          clock: clock,
          restoreRepository: restoreRepository,
          importer: services.backupImporter,
          syncHealthRepository: healthRepository,
          importCommitted: importCommitted,
        ),
    localDataRecoveryBuilder: (_, accountId, recovery, healthRepository) =>
        LocalDataRecoveryHost(
          viewModel: LocalDataRecoveryViewModel(
            accountId: accountId,
            recovery: recovery,
            healthRepository: healthRepository,
          ),
        ),
    diagnosticsBuilder: (_) => ReleaseDiagnosticsHost(
      history: diagnosticHistory,
      exporter: diagnosticExporter,
    ),
    destinationsBuilder: (runtime, accountBackupBuilder) {
      final activity = runtime.syncActivityRepository;
      final health = runtime.syncHealthRepository;
      final accountId = runtime.viewModel.accountId;
      return AppDestinations(
        about: (context) => AboutPage(
          version: version,
          onSupportProject: () => openExternalPage(
            context,
            services.links.launch,
            supportProjectUri,
          ),
          onOpenSourceCode: () =>
              openExternalPage(context, services.links.launch, sourceCodeUri),
        ),
        supportProject: _supportProject,
        syncActivity: activity == null
            ? null
            : (context) =>
                  SyncActivityPage(accountId: accountId, repository: activity),
        account: health == null
            ? null
            : (_) => AccountPage(
                health: health.watchHealth(accountId),
                onHealthAction: runtime.viewModel.handleSyncHealthAction,
                session: runtime.accountSession,
                accountBackupBuilder: accountBackupBuilder,
              ),
      );
    },
  );
}
