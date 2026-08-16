import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../domain/backup/account_backup.dart';

sealed class AccountBackupSaveResult {
  const AccountBackupSaveResult();

  const factory AccountBackupSaveResult.cancelled() =
      AccountBackupSaveCancelled;

  const factory AccountBackupSaveResult.saved(String fileName) =
      AccountBackupSaved;
}

final class AccountBackupSaveCancelled extends AccountBackupSaveResult {
  const AccountBackupSaveCancelled();

  @override
  bool operator ==(Object other) => other is AccountBackupSaveCancelled;

  @override
  int get hashCode => runtimeType.hashCode;
}

final class AccountBackupSaved extends AccountBackupSaveResult {
  const AccountBackupSaved(this.fileName);

  final String fileName;

  @override
  bool operator ==(Object other) =>
      other is AccountBackupSaved && fileName == other.fileName;

  @override
  int get hashCode => fileName.hashCode;
}

abstract interface class AccountBackupExporter {
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  });
}

abstract interface class AccountBackupSaveLocationPicker {
  Future<String?> chooseSaveLocation({required String suggestedName});
}

sealed class AccountBackupOpenResult {
  const AccountBackupOpenResult();

  const factory AccountBackupOpenResult.cancelled() =
      AccountBackupOpenCancelled;

  const factory AccountBackupOpenResult.opened({
    required String fileName,
    required String contents,
  }) = AccountBackupOpened;
}

final class AccountBackupOpenCancelled extends AccountBackupOpenResult {
  const AccountBackupOpenCancelled();
}

final class AccountBackupOpened extends AccountBackupOpenResult {
  const AccountBackupOpened({required this.fileName, required this.contents});

  final String fileName;
  final String contents;
}

abstract interface class AccountBackupImporter {
  Future<AccountBackupOpenResult> open();
}

abstract interface class AccountBackupOpenLocationPicker {
  Future<String?> chooseOpenLocation();
}

final class FileSelectorAccountBackupOpenLocationPicker
    implements AccountBackupOpenLocationPicker {
  const FileSelectorAccountBackupOpenLocationPicker();

  @override
  Future<String?> chooseOpenLocation() async => (await openFile(
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(
        label: 'Axiotask JSON backup',
        extensions: <String>['json'],
        mimeTypes: <String>['application/json'],
      ),
    ],
  ))?.path;
}

final class LocalAccountBackupImporter implements AccountBackupImporter {
  const LocalAccountBackupImporter(this._picker);

  final AccountBackupOpenLocationPicker _picker;

  @override
  Future<AccountBackupOpenResult> open() async {
    final path = await _picker.chooseOpenLocation();
    if (path == null) return const AccountBackupOpenResult.cancelled();
    final file = File(path);
    if (await file.length() > maxAccountBackupBytes) {
      throw const AccountBackupFormatException('document_too_large');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, maxAccountBackupBytes + 1)) {
      bytes.addAll(chunk);
      if (bytes.length > maxAccountBackupBytes) {
        throw const AccountBackupFormatException('document_too_large');
      }
    }
    final contents = utf8.decode(bytes, allowMalformed: false);
    return AccountBackupOpenResult.opened(
      fileName: _baseName(path),
      contents: contents,
    );
  }
}

final class FileSelectorAccountBackupSaveLocationPicker
    implements AccountBackupSaveLocationPicker {
  const FileSelectorAccountBackupSaveLocationPicker();

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      (await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: 'Export private backup',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: 'Axiotask JSON backup',
            extensions: <String>['json'],
            mimeTypes: <String>['application/json'],
          ),
        ],
      ))?.path;
}

final class LocalAccountBackupExporter implements AccountBackupExporter {
  const LocalAccountBackupExporter(this._picker);

  final AccountBackupSaveLocationPicker _picker;

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async {
    final path = await _picker.chooseSaveLocation(suggestedName: suggestedName);
    if (path == null) return const AccountBackupSaveResult.cancelled();
    final target = File(path);
    final temporary = File('$path.next');
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(path);
      return AccountBackupSaveResult.saved(_baseName(target.path));
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}

String _baseName(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
