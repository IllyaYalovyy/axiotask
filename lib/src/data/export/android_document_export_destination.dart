import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/export/view_export.dart';
import '../../domain/repository/view_export_destination.dart';

/// The channel `MainActivity` serves with the Storage Access Framework.
const documentExportChannel = MethodChannel(
  'dev.axiotask.axiotask/document_export',
);

/// Chooses where a new document goes and answers its URI, or `null` when the
/// user dismissed the picker.
typedef DocumentLocationPicker = Future<String?> Function({
  required String suggestedName,
  required String mimeType,
});

/// Android: the system "Save to" document picker (`ACTION_CREATE_DOCUMENT`),
/// then the bytes written through `ContentResolver`, so the export lands in
/// any provider the user picks (Downloads, Drive, a USB volume) without a
/// storage permission.
///
/// Choosing and writing are separate native calls. A test may inject
/// [picker] to stand in for the system picker activity it cannot drive;
/// the write still goes through the native `ContentResolver` boundary.
final class AndroidDocumentExportDestination implements ViewExportDestination {
  AndroidDocumentExportDestination({
    this.channel = documentExportChannel,
    this.picker,
  });

  final MethodChannel channel;

  /// Stands in for the system picker; `null` uses `ACTION_CREATE_DOCUMENT`.
  final DocumentLocationPicker? picker;

  @override
  Future<ViewExportResult> save(ViewExportDocument document) async {
    final String? uri;
    try {
      uri = await (picker ?? _createDocument)(
        suggestedName: document.fileName,
        mimeType: document.mimeType,
      );
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
    if (uri == null) return const ViewExportCancelled();

    try {
      final name = await channel.invokeMethod<String>(
        'writeDocument',
        <String, Object>{
          'uri': uri,
          'bytes': Uint8List.fromList(utf8.encode(document.text)),
        },
      );
      return ViewExportSaved(
        name == null || name.isEmpty ? document.fileName : name,
      );
    } on Object catch (error) {
      // The picker already created an empty document; a failed write must not
      // leave it behind looking like a finished export.
      try {
        await channel.invokeMethod<void>('discardDocument', <String, Object>{
          'uri': uri,
        });
      } on Object {
        // Best effort only: the write failure is what the user must hear.
      }
      throw ViewExportDestinationException(
        ViewExportFailure.writeFailed,
        error is PlatformException ? error.code : error.runtimeType.toString(),
      );
    }
  }

  Future<String?> _createDocument({
    required String suggestedName,
    required String mimeType,
  }) => channel.invokeMethod<String>('createDocument', <String, Object>{
    'fileName': suggestedName,
    'mimeType': mimeType,
  });
}
