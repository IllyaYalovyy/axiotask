import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../domain/export/view_export.dart';
import '../../domain/repository/view_export_destination.dart';

/// The desktop save dialog: the absolute path chosen for [document], or
/// `null` when the user dismissed it.
typedef ViewExportSaveLocationPicker = Future<String?> Function(
  ViewExportDocument document,
);

/// Desktop (Linux): a native save dialog, then the document written to the
/// chosen path through a sibling temporary file, so a failed write never
/// leaves a truncated export behind.
final class FileViewExportDestination implements ViewExportDestination {
  const FileViewExportDestination({this.picker = _chooseSaveLocation});

  final ViewExportSaveLocationPicker picker;

  @override
  Future<ViewExportResult> save(ViewExportDocument document) async {
    final String? picked;
    try {
      picked = await picker(document);
    } on Object catch (error) {
      throw ViewExportDestinationException(
        ViewExportFailure.pickerFailed,
        error.runtimeType.toString(),
      );
    }
    if (picked == null) return const ViewExportCancelled();
    // GTK's dialog does not append the filter's extension, so a typed
    // "groceries" would otherwise produce a file no tool recognizes.
    final extension = '.${document.format.extension}';
    final path = picked.toLowerCase().endsWith(extension)
        ? picked
        : '$picked$extension';
    final temporary = File('$path.next');
    try {
      await temporary.writeAsString(document.text, flush: true);
      await temporary.rename(path);
    } on Object catch (error) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // Best effort; the write failure is reported below.
      }
      throw ViewExportDestinationException(
        ViewExportFailure.writeFailed,
        error.runtimeType.toString(),
      );
    }
    return ViewExportSaved(
      path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last,
    );
  }
}

Future<String?> _chooseSaveLocation(ViewExportDocument document) async =>
    (await getSaveLocation(
      suggestedName: document.fileName,
      confirmButtonText: 'Export',
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: document.format.label,
          extensions: <String>[document.format.extension],
          mimeTypes: <String>[document.mimeType],
        ),
      ],
    ))?.path;
