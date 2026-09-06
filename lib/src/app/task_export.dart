// Taking a list (or a view) OUT of the app (#297) — the ONE serializer of tasks
// for human consumption, in both formats the user can ask for.
//
// It is pure: `(title, rows, options) → document`. No store, no filesystem, no
// plugin, and — deliberately — no path back IN. An export is a snapshot a
// person reads, pastes into a PR description or opens in a spreadsheet; the
// lossless, restorable snapshot is the BACKUP (`backup_service.dart`), and the
// two must not be confused. Nothing here touches sync state.
//
// What it writes, and why:
//
//   • Markdown is a GFM task list — `- [ ] Title — Sep 12` — with notes as an
//     indented paragraph and subtasks as one nested level (never deeper:
//     subtasks are strictly one level, and a nested checklist is exactly how
//     that reads outside the app).
//   • CSV is RFC 4180 (`"` doubled, any field holding a comma / quote /
//     newline quoted), LF-terminated, plain UTF-8 with NO byte-order mark — a
//     BOM is what makes a "utf-8" file open as mojibake in half the tools that
//     read it, and every consumer that matters defaults to UTF-8 today. Its
//     header is FIXED (`title,list,due,status,completed_at,notes,parent_title`)
//     so a script reading the file has a stable schema: switching a content
//     option off empties a column, it never renames one or moves it.
//
// Dates: the Markdown label is ABSOLUTE ("Sep 12", with the year whenever it
// is not the current one) — the row's relative badge ("in 3d") is true for one
// day and this document outlives that day. CSV's `due` is the bare calendar day
// `YYYY-MM-DD`, which is what a Google due date actually is (the time component
// is discarded server-side), and `completed_at` stays the stored RFC 3339
// instant, which is a real point in time. A task's OWN date is exported —
// never a parent's inherited one, which is a view concern, not data.

import 'package:clock/clock.dart';

import '../model/task.dart';
import '../store/stored.dart';
import '../ui/date_format.dart' show formatAbsoluteDue;

/// The two shapes an export can take, with the names the sheet shows and the
/// file/MIME identity each one needs to leave the app.
enum ExportFormat {
  /// A GFM checklist — the format that reads as a document.
  markdown('Markdown', 'md', 'text/markdown'),

  /// One row per task — the format that opens in a spreadsheet.
  csv('CSV', 'csv', 'text/csv');

  const ExportFormat(this.label, this.extension, this.mimeType);

  /// The name shown in the export sheet.
  final String label;

  /// The file extension (no dot).
  final String extension;

  /// The MIME type handed to the share sheet / save dialog.
  final String mimeType;
}

/// What the user chose in the export sheet. The defaults are the common case:
/// the open work, with its notes and its subtasks, as a checklist.
class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.markdown,
    this.includeCompleted = false,
    this.includeNotes = true,
    this.includeSubtasks = true,
  });

  /// Markdown or CSV.
  final ExportFormat format;

  /// Include completed tasks (and completed subtasks). Off by default — an
  /// export is normally "what is left to do".
  final bool includeCompleted;

  /// Include each task's notes.
  final bool includeNotes;

  /// Include subtasks (nested in Markdown, own rows in CSV).
  final bool includeSubtasks;

  /// A copy with the named fields replaced.
  ExportOptions copyWith({
    ExportFormat? format,
    bool? includeCompleted,
    bool? includeNotes,
    bool? includeSubtasks,
  }) => ExportOptions(
    format: format ?? this.format,
    includeCompleted: includeCompleted ?? this.includeCompleted,
    includeNotes: includeNotes ?? this.includeNotes,
    includeSubtasks: includeSubtasks ?? this.includeSubtasks,
  );

  @override
  bool operator ==(Object other) =>
      other is ExportOptions &&
      other.format == format &&
      other.includeCompleted == includeCompleted &&
      other.includeNotes == includeNotes &&
      other.includeSubtasks == includeSubtasks;

  @override
  int get hashCode =>
      Object.hash(format, includeCompleted, includeNotes, includeSubtasks);
}

/// A finished export: the text itself plus the identity it needs to travel
/// (a filename for a save dialog or a share attachment, a MIME type for the
/// receiving app) and how many tasks it actually holds — what the confirmation
/// toast reports, so "exported" is never a claim about an empty file.
class ExportDocument {
  const ExportDocument({
    required this.title,
    required this.fileName,
    required this.format,
    required this.text,
    required this.taskCount,
  });

  /// The list/view this is an export OF — the share sheet's subject and the
  /// name the confirmation toast uses.
  final String title;

  /// Suggested file name, e.g. `axiotask-groceries-20260915.md`.
  final String fileName;

  /// Which format [text] is in.
  final ExportFormat format;

  /// The document itself, UTF-8, LF-terminated, no BOM.
  final String text;

  /// How many tasks were written (subtasks included).
  final int taskCount;

  /// MIME type of [text] — what the share sheet and the save dialog announce.
  String get mimeType => format.mimeType;
}

/// Build the document for [title] from [topLevel] — the view's rows, ALREADY in
/// display order and top-level only — resolving each row's subtasks out of
/// [allTasks] and each task's list name out of [listTitles].
///
/// [options] decides the format and what is left out. Completed filtering is
/// applied here as well as by the caller's view filter, because the subtasks
/// come from the full task set, which is never view-filtered.
ExportDocument buildExport({
  required String title,
  required List<StoredTask> topLevel,
  required List<StoredTask> allTasks,
  required Map<String, String> listTitles,
  ExportOptions options = const ExportOptions(),
}) {
  bool kept(StoredTask t) =>
      options.includeCompleted || t.task.status != TaskStatus.completed;

  final rows = topLevel.where(kept).toList(growable: false);
  final children = <String, List<StoredTask>>{};
  if (options.includeSubtasks) {
    for (final t in allTasks) {
      final parent = t.task.parent;
      if (parent == null || !kept(t)) continue;
      (children[parent] ??= <StoredTask>[]).add(t);
    }
  }

  var count = 0;
  for (final row in rows) {
    count += 1 + (children[row.task.id]?.length ?? 0);
  }

  final text = switch (options.format) {
    ExportFormat.markdown => _markdown(title, rows, children, options),
    ExportFormat.csv => _csv(rows, children, listTitles, options),
  };

  return ExportDocument(
    title: title,
    fileName: exportFileName(title, options.format),
    format: options.format,
    text: text,
    taskCount: count,
  );
}

/// The suggested file name for [title] in [format] —
/// `axiotask-<slug>-<YYYYMMDD>.<ext>`, on the LOCAL calendar day (the day the
/// user believes they exported on), via `package:clock`.
String exportFileName(String title, ExportFormat format) {
  final now = clock.now().toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}';
  return 'axiotask-${_slug(title)}-$stamp.${format.extension}';
}

/// A filename-safe slug of [title]: lowercase, every run of anything else
/// collapsed to one dash, capped so a long list name cannot produce a path the
/// filesystem refuses. A title with nothing sluggable in it (an emoji-only list
/// name) still has to produce a usable name, so it falls back to `tasks`.
String _slug(String title) {
  final s = title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  final capped = s.length <= 40 ? s : s.substring(0, 40);
  final trimmed = capped.replaceAll(RegExp(r'-+$'), '');
  return trimmed.isEmpty ? 'tasks' : trimmed;
}

/// The Markdown checklist.
String _markdown(
  String title,
  List<StoredTask> rows,
  Map<String, List<StoredTask>> children,
  ExportOptions options,
) {
  final out = StringBuffer()
    ..writeln('# ${_oneLine(title)}')
    ..writeln();
  if (rows.isEmpty) {
    // A heading over nothing reads as a broken export. Say what happened.
    out.writeln('_No tasks._');
    return out.toString();
  }
  for (final row in rows) {
    _markdownItem(out, row, '', options);
    for (final child in children[row.task.id] ?? const <StoredTask>[]) {
      _markdownItem(out, child, '  ', options);
    }
  }
  return out.toString();
}

/// One checklist item at [indent], plus its note paragraph when there is one.
///
/// The note is fenced by blank lines so it renders as a PARAGRAPH of the item
/// rather than being lazily joined onto the title's line; an item with no note
/// writes no blank line at all, so a plain checklist stays tight.
void _markdownItem(
  StringBuffer out,
  StoredTask stored,
  String indent,
  ExportOptions options,
) {
  final t = stored.task;
  final box = t.status == TaskStatus.completed ? '[x]' : '[ ]';
  final due = (t.due == null || t.due!.isEmpty)
      ? ''
      : ' — ${formatAbsoluteDue(t.due!)}';
  out.writeln('$indent- $box ${_oneLine(t.title)}$due');

  if (!options.includeNotes) return;
  final notes = t.notes?.trim() ?? '';
  if (notes.isEmpty) return;
  out.writeln();
  for (final line in notes.split('\n')) {
    final text = line.trimRight();
    out.writeln(text.isEmpty ? '' : '$indent  $text');
  }
  out.writeln();
}

/// Collapse a value onto one line — a title carrying a newline would otherwise
/// split one checklist item into an item and a stray paragraph.
String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The CSV table. The header is fixed; an excluded option empties its column
/// (and, for subtasks, drops the rows) rather than changing the schema.
String _csv(
  List<StoredTask> rows,
  Map<String, List<StoredTask>> children,
  Map<String, String> listTitles,
  ExportOptions options,
) {
  final out = StringBuffer()
    ..writeln('title,list,due,status,completed_at,notes,parent_title');
  for (final row in rows) {
    _csvRow(out, row, null, listTitles, options);
    for (final child in children[row.task.id] ?? const <StoredTask>[]) {
      _csvRow(out, child, row.task.title, listTitles, options);
    }
  }
  return out.toString();
}

void _csvRow(
  StringBuffer out,
  StoredTask stored,
  String? parentTitle,
  Map<String, String> listTitles,
  ExportOptions options,
) {
  final t = stored.task;
  final due = (t.due == null || t.due!.isEmpty)
      ? ''
      // Google due values ARE calendar days (the time component is discarded
      // server-side), so the column carries the day, not the midnight instant.
      : (t.due!.length >= 10 ? t.due!.substring(0, 10) : t.due!);
  out.writeln(
    [
      t.title,
      listTitles[stored.listId] ?? '',
      due,
      t.status.apiStr,
      t.completed ?? '',
      options.includeNotes ? (t.notes ?? '') : '',
      parentTitle ?? '',
    ].map(_csvField).join(','),
  );
}

/// RFC 4180: quote a field that holds a comma, a quote or a line break, and
/// double any quote inside it. Everything else is written bare.
String _csvField(String value) {
  final needsQuotes =
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r');
  if (!needsQuotes) return value;
  return '"${value.replaceAll('"', '""')}"';
}
