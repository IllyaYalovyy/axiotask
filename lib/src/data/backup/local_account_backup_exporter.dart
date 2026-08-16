import 'dart:io';

import 'package:file_selector/file_selector.dart';

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
