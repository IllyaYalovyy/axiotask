import 'package:flutter/services.dart';

import '../../domain/export/view_export.dart';
import '../../domain/repository/view_export_destination.dart';
import 'android_document_export_destination.dart';

/// Android: hands the export to the system share sheet as text, so it can go
/// to mail, chat, notes or any other app that accepts text.
final class AndroidViewExportShare implements ViewExportShare {
  const AndroidViewExportShare({this.channel = documentExportChannel});

  final MethodChannel channel;

  @override
  Future<void> share(ViewExportDocument document) async {
    try {
      await channel.invokeMethod<bool>('shareText', <String, Object>{
        'subject': document.title,
        'text': document.text,
      });
    } on MissingPluginException catch (error) {
      throw ViewExportDestinationException(
        ViewExportFailure.unavailable,
        error.message,
      );
    } on PlatformException catch (error) {
      throw ViewExportDestinationException(
        ViewExportFailure.pickerFailed,
        error.code,
      );
    }
  }
}
