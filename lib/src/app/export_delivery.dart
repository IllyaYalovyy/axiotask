// How an export LEAVES the app (#297) — the one seam between the pure
// [ExportDocument] and the three platform surfaces that can carry it away.
//
// The two form factors answer this question differently, and the difference is
// not cosmetic: a phone has no user-visible filesystem to save into, and a
// Linux desktop has no share sheet. So the delivery is chosen by PLATFORM, and
// each one advertises what it can do ([canShare] / [canSave]) rather than the
// sheet guessing from the target platform itself. Copy-to-clipboard is
// universal and lives on the base.
//
// Every platform call is an injected function (the [Sharer], the
// [SaveLocationPicker]), so everything AROUND the plugin — writing the file,
// naming the temp attachment, honouring a cancelled dialog — is exercised on
// the host VM. Only the one-line plugin call itself is untestable here, and it
// is kept to exactly that.

import 'dart:io';

import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup, getSaveLocation;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;

import 'task_export.dart';

/// What the platform share sheet is asked to send: a document as plain text, or
/// as a file at [filePath]. Never both — a receiving app that supports one and
/// not the other should not have to choose.
class ShareRequest {
  const ShareRequest({
    required this.subject,
    this.text,
    this.filePath,
    this.mimeType,
  });

  /// The share sheet's subject/title — the name of what is being exported.
  final String subject;

  /// The document as text, when it is being shared inline.
  final String? text;

  /// The document as a file, when it is being shared as an attachment.
  final String? filePath;

  /// MIME type of [filePath].
  final String? mimeType;
}

/// The system share-sheet call.
typedef Sharer = Future<void> Function(ShareRequest request);

/// The system save dialog: the absolute path the user chose for [doc], or
/// `null` when they dismissed it.
typedef SaveLocationPicker = Future<String?> Function(ExportDocument doc);

/// A way out of the app for an [ExportDocument].
///
/// [share] and [save] throw [UnsupportedError] unless the platform advertises
/// them, so a caller that ignores [canShare]/[canSave] fails loudly in a test
/// rather than silently doing nothing in a user's hands.
abstract class ExportDelivery {
  const ExportDelivery();

  /// Whether this platform can hand the document to another app.
  bool get canShare => false;

  /// Whether this platform can write the document to a file the user picks.
  bool get canSave => false;

  /// Hand [doc] to the platform share sheet.
  Future<void> share(ExportDocument doc) =>
      throw UnsupportedError('this platform cannot share an export');

  /// Ask where to put [doc] and write it there. Returns the path written, or
  /// `null` when the user dismissed the dialog.
  Future<String?> save(ExportDocument doc) =>
      throw UnsupportedError('this platform cannot save an export');

  /// Put [doc]'s text on the system clipboard.
  Future<void> copy(ExportDocument doc) =>
      Clipboard.setData(ClipboardData(text: doc.text));
}

/// Android: the system share sheet is the whole delivery — Markdown as text (so
/// it pastes straight into a message or a note), CSV as a file (so a spreadsheet
/// app can open it).
class ShareExportDelivery extends ExportDelivery {
  ShareExportDelivery({Sharer? sharer, Future<Directory> Function()? tempDir})
    : _share = sharer ?? _shareViaSystem,
      _tempDir = tempDir ?? getTemporaryDirectory;

  final Sharer _share;
  final Future<Directory> Function() _tempDir;

  @override
  bool get canShare => true;

  @override
  Future<void> share(ExportDocument doc) async {
    if (doc.format == ExportFormat.markdown) {
      await _share(ShareRequest(subject: doc.title, text: doc.text));
      return;
    }
    // The attachment lives in the app's CACHE dir, which is the root share_plus'
    // FileProvider is declared over — a file anywhere else is unreadable to the
    // app the user picks, and the share arrives empty.
    final dir = await _tempDir();
    final file = File(p.join(dir.path, doc.fileName));
    await file.writeAsString(doc.text, flush: true);
    await _share(
      ShareRequest(
        subject: doc.title,
        filePath: file.path,
        mimeType: doc.mimeType,
      ),
    );
  }
}

/// Desktop: a save dialog, and the file written where the user pointed it.
class FileExportDelivery extends ExportDelivery {
  FileExportDelivery({SaveLocationPicker? picker})
    : _pick = picker ?? _pickSaveLocation;

  final SaveLocationPicker _pick;

  @override
  bool get canSave => true;

  @override
  Future<String?> save(ExportDocument doc) async {
    final picked = await _pick(doc);
    if (picked == null) return null;
    // GTK's save dialog does not append the filter's extension, so a user who
    // types "groceries" gets a file no tool recognizes unless we add it.
    final path = p.extension(picked).toLowerCase() == '.${doc.format.extension}'
        ? picked
        : '$picked.${doc.format.extension}';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(doc.text, flush: true);
    return path;
  }
}

/// The real share sheet (share_plus).
Future<void> _shareViaSystem(ShareRequest request) async {
  final params = request.filePath == null
      ? ShareParams(subject: request.subject, text: request.text)
      : ShareParams(
          subject: request.subject,
          files: [XFile(request.filePath!, mimeType: request.mimeType)],
        );
  await SharePlus.instance.share(params);
}

/// The real save dialog (file_selector).
Future<String?> _pickSaveLocation(ExportDocument doc) async {
  final FileSaveLocation? location = await getSaveLocation(
    suggestedName: doc.fileName,
    acceptedTypeGroups: [
      XTypeGroup(
        label: doc.format.label,
        extensions: [doc.format.extension],
        mimeTypes: [doc.mimeType],
      ),
    ],
  );
  return location?.path;
}

/// The delivery the export sheet uses. Android shares; every desktop saves.
/// Overridden in tests so no widget test touches a plugin channel.
final exportDeliveryProvider = Provider<ExportDelivery>(
  (ref) => Platform.isAndroid ? ShareExportDelivery() : FileExportDelivery(),
);
