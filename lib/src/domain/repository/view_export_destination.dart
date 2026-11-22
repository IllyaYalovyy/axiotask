import '../export/view_export.dart';

/// Where a current-view export leaves the app: a platform save surface the
/// user chooses a destination in (the Android document picker, the desktop
/// save dialog).
///
/// Implementations write the whole document or report failure; they never
/// read or change task data.
abstract interface class ViewExportDestination {
  /// Asks for a destination for [document] and writes it there.
  ///
  /// Returns [ViewExportCancelled] when the user dismissed the picker, which
  /// is not a failure. Throws [ViewExportDestinationException] when the
  /// destination could not be chosen or written.
  Future<ViewExportResult> save(ViewExportDocument document);
}

/// Hands a current-view export to another application through the platform
/// share surface. Offered only where one exists (Android).
abstract interface class ViewExportShare {
  /// Opens the share surface for [document]. Completes once the surface is
  /// showing; which application the user picks, if any, is not reported.
  /// Throws [ViewExportDestinationException] when it cannot be opened.
  Future<void> share(ViewExportDocument document);
}

sealed class ViewExportResult {
  const ViewExportResult();
}

/// The user dismissed the destination picker; nothing was written.
final class ViewExportCancelled extends ViewExportResult {
  const ViewExportCancelled();

  @override
  bool operator ==(Object other) => other is ViewExportCancelled;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// The document was written in full to the destination named [displayName].
final class ViewExportSaved extends ViewExportResult {
  const ViewExportSaved(this.displayName);

  /// The file name the destination reports, for feedback only.
  final String displayName;

  @override
  bool operator ==(Object other) =>
      other is ViewExportSaved && displayName == other.displayName;

  @override
  int get hashCode => displayName.hashCode;
}

/// Why a destination could not take an export.
enum ViewExportFailure {
  /// The platform has no destination picker available.
  unavailable,

  /// The picker could not be opened.
  pickerFailed,

  /// The chosen destination could not be written.
  writeFailed,
}

final class ViewExportDestinationException implements Exception {
  const ViewExportDestinationException(this.failure, [this.detail]);

  final ViewExportFailure failure;

  /// A platform detail for diagnostics; never shown with task content.
  final String? detail;

  @override
  String toString() => 'ViewExportDestinationException(${failure.name})';
}
