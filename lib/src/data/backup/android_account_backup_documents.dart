import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/backup/account_backup.dart';
import '../export/android_document_export_destination.dart';
import 'local_account_backup_exporter.dart';

const _backupMimeType = 'application/json';

/// Android: saves the private account backup through the Storage Access
/// Framework "Save to" picker, so it can land in Downloads, Drive or any
/// other document provider without a storage permission.
final class AndroidDocumentAccountBackupExporter
    implements AccountBackupExporter {
  const AndroidDocumentAccountBackupExporter({
    this.channel = documentExportChannel,
  });

  final MethodChannel channel;

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async {
    final uri = await channel.invokeMethod<String>(
      'createDocument',
      <String, Object>{'fileName': suggestedName, 'mimeType': _backupMimeType},
    );
    if (uri == null) return const AccountBackupSaveResult.cancelled();
    try {
      final name = await channel.invokeMethod<String>(
        'writeDocument',
        <String, Object>{
          'uri': uri,
          'bytes': Uint8List.fromList(utf8.encode(contents)),
        },
      );
      return AccountBackupSaveResult.saved(
        name == null || name.isEmpty ? suggestedName : name,
      );
    } on Object {
      // The picker already created an empty document; a failed write must
      // not leave it behind looking like a complete backup.
      try {
        await channel.invokeMethod<void>('discardDocument', <String, Object>{
          'uri': uri,
        });
      } on Object {
        // Best effort only: the write failure is what the user must hear.
      }
      rethrow;
    }
  }
}

/// Android: opens a backup the user picks with the system document picker and
/// reads it through `ContentResolver`, refusing anything over the format's
/// size limit instead of truncating it.
final class AndroidDocumentAccountBackupImporter
    implements AccountBackupImporter {
  const AndroidDocumentAccountBackupImporter({
    this.channel = documentExportChannel,
  });

  final MethodChannel channel;

  @override
  Future<AccountBackupOpenResult> open() async {
    final uri = await channel.invokeMethod<String>(
      'openDocument',
      <String, Object>{
        // Providers disagree on the type of a .json file.
        'mimeTypes': <String>[
          _backupMimeType,
          'text/plain',
          'application/octet-stream',
        ],
      },
    );
    if (uri == null) return const AccountBackupOpenResult.cancelled();
    final Map<Object?, Object?>? document;
    try {
      document = await channel.invokeMapMethod<Object?, Object?>(
        'readDocument',
        <String, Object>{'uri': uri, 'maxBytes': maxAccountBackupBytes},
      );
    } on PlatformException catch (error) {
      if (error.code == 'too_large') {
        throw const AccountBackupFormatException('document_too_large');
      }
      rethrow;
    }
    final bytes = document?['bytes'];
    if (bytes is! Uint8List) {
      throw const AccountBackupFormatException('document_unreadable');
    }
    final name = document?['name'];
    return AccountBackupOpenResult.opened(
      fileName: name is String && name.isNotEmpty ? name : 'backup.json',
      contents: utf8.decode(bytes, allowMalformed: false),
    );
  }
}
