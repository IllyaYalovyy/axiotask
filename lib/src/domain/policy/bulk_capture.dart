const int maxBulkCaptureTasks = 100;
const int maxBulkCaptureInputCharacters = 1024 * 1024;
const int maxBulkCaptureTitleCharacters = 1024;
const int maxBulkCaptureNotesCharacters = 8192;

enum BulkCaptureMode { lines, paragraphs }

final class BulkCaptureEntry {
  const BulkCaptureEntry({required this.title, this.notes});

  final String title;
  final String? notes;

  @override
  bool operator ==(Object other) =>
      other is BulkCaptureEntry && title == other.title && notes == other.notes;

  @override
  int get hashCode => Object.hash(title, notes);
}

final class BulkCaptureFailure {
  const BulkCaptureFailure({required this.code, this.entryNumber});

  final String code;
  final int? entryNumber;
}

final class BulkCapturePreview {
  const BulkCapturePreview({required this.entries, this.failure});

  final List<BulkCaptureEntry> entries;
  final BulkCaptureFailure? failure;

  bool get isValid => failure == null;
}

BulkCapturePreview parseBulkCapture(
  String input, {
  required BulkCaptureMode mode,
}) {
  if (input.length > maxBulkCaptureInputCharacters) {
    return _failure('bulk_capture.input_too_large');
  }
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rawEntries = switch (mode) {
    BulkCaptureMode.lines =>
      normalized
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map((line) => BulkCaptureEntry(title: line))
          .toList(growable: false),
    BulkCaptureMode.paragraphs => _parseParagraphs(normalized),
  };
  if (rawEntries.isEmpty) return _failure('bulk_capture.empty');
  if (rawEntries.length > maxBulkCaptureTasks) {
    return _failure('bulk_capture.too_many_tasks');
  }
  for (var index = 0; index < rawEntries.length; index += 1) {
    final entry = rawEntries[index];
    if (containsUnsupportedBulkControlCharacters(entry.title) ||
        (entry.notes != null &&
            containsUnsupportedBulkControlCharacters(entry.notes!))) {
      return _failure('bulk_capture.malformed_text', index + 1);
    }
    if (entry.title.length > maxBulkCaptureTitleCharacters) {
      return _failure('bulk_capture.title_too_long', index + 1);
    }
    if ((entry.notes?.length ?? 0) > maxBulkCaptureNotesCharacters) {
      return _failure('bulk_capture.notes_too_long', index + 1);
    }
  }
  return BulkCapturePreview(entries: List.unmodifiable(rawEntries));
}

List<BulkCaptureEntry> _parseParagraphs(String input) {
  final blocks = input.split(RegExp(r'\n[ \t]*\n+'));
  return blocks
      .map((block) => block.trim())
      .where((block) => block.isNotEmpty)
      .map((block) {
        final lines = block.split('\n');
        final title = lines.first.trim();
        final notes = lines.length == 1
            ? null
            : lines.skip(1).join('\n').trim();
        return BulkCaptureEntry(
          title: title,
          notes: notes == null || notes.isEmpty ? null : notes,
        );
      })
      .toList(growable: false);
}

bool containsUnsupportedBulkControlCharacters(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 && codeUnit != 0x09 && codeUnit != 0x0a) return true;
    if (codeUnit == 0x7f) return true;
  }
  return false;
}

BulkCapturePreview _failure(String code, [int? entryNumber]) =>
    BulkCapturePreview(
      entries: const <BulkCaptureEntry>[],
      failure: BulkCaptureFailure(code: code, entryNumber: entryNumber),
    );
