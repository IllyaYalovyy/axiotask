import 'package:axiotask/src/app/axiotask_product.dart';
import 'package:axiotask/src/data/backup/android_account_backup_documents.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/data/links/url_launcher_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// v1.5.4–v1.5.8 wired account backup for Linux only
/// (`accountBackupBuilder: Platform.isLinux ? … : null`), so the feature
/// silently did not exist on Android. The product now takes its platform
/// edges from one place; this pins what each shipped platform receives.
void main() {
  test('Android backs up and restores through the document pickers', () {
    final services = ProductPlatformServices.forPlatform(
      TargetPlatform.android,
    );
    expect(
      services.backupExporter,
      isA<AndroidDocumentAccountBackupExporter>(),
    );
    expect(
      services.backupImporter,
      isA<AndroidDocumentAccountBackupImporter>(),
    );
    expect(services.links, isA<UrlLauncherAdapter>());
  });

  test('Linux backs up and restores through native file dialogs', () {
    final services = ProductPlatformServices.forPlatform(TargetPlatform.linux);
    expect(services.backupExporter, isA<LocalAccountBackupExporter>());
    expect(services.backupImporter, isA<LocalAccountBackupImporter>());
    expect(services.links, isA<UrlLauncherAdapter>());
  });
}
