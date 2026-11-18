// Taking the current list or smart view OUT of the app as a human-readable
// document: the one serializer of tasks for people, in the two formats the
// collection actions offer.
//
// It is pure: `(title, displayed rows, account tasks, lists) → document`. No
// store, no filesystem, no plugin and no path back in. An export is a snapshot
// someone reads, pastes or opens in a spreadsheet; the lossless, restorable
// snapshot is the account backup (`domain/backup/account_backup.dart`), and the
// two must not be confused. Nothing here touches sync state.
//
// The contract follows v1.5.3 (`lib/src/app/task_export.dart` at that tag):
//
//   • Markdown is a GFM task list — `- [ ] Title — Sep 12` — under a `# Title`
//     heading, with notes as an indented paragraph and subtasks as one nested
//     level. Text is escaped so a title or note can never become markup, a
//     link, another checklist item or a heading. An empty view says
//     `_No tasks._` rather than leaving a bare heading.
//   • CSV is RFC 4180 (a field with a comma, quote or line break is quoted and
//     its quotes doubled), LF-terminated UTF-8 without a byte-order mark. Its
//     header is fixed (`title,list,due,status,completed_at,notes,parent_title`)
//     so a script reading the file has a stable schema.
//
// Scope is what the user is looking at: the caller passes the view's top-level
// rows ALREADY filtered and in display order. Subtasks of those rows follow
// them in their stored order, and the view's completed filter applies to
// subtasks as well. Nothing else in the account is read.
//
// Dates: Markdown carries an absolute label ("Sep 12", with the year when it is
// not the current one), never a relative badge that is only true today. CSV's
// `due` is the bare calendar day `YYYY-MM-DD`. A task's OWN date is written,
// never a date inherited from or derived for a parent.
//
// `completed_at` is Google's stored completion instant as RFC 3339 UTC
// (`2026-06-14T10:00:00.000Z`), written only for a task exported as completed.
// It is empty for an open task, even when the last remote state still holds an
// instant (reopened locally, not yet published), and for a task completed
// locally whose completion Google has not yet reported.

import '../model/tasks.dart';

/// The two shapes an export can take, with the file and MIME identity each
/// needs to leave the app.
enum ViewExportFormat {
  /// A GFM checklist — the format that reads as a document.
  markdown('Markdown', 'md', 'text/markdown'),

  /// One row per task — the format that opens in a spreadsheet.
  csv('CSV', 'csv', 'text/csv');

  const ViewExportFormat(this.label, this.extension, this.mimeType);

  /// The name shown in the collection actions.
  final String label;

  /// The file extension, without a dot.
  final String extension;

  /// The MIME type announced to the save destination.
  final String mimeType;
}

/// The fixed CSV header.
const viewExportCsvHeader = <String>[
  'title',
  'list',
  'due',
  'status',
  'completed_at',
  'notes',
  'parent_title',
];

/// A finished export: the text plus what it needs to travel.
final class ViewExportDocument {
  const ViewExportDocument({
    required this.title,
    required this.fileName,
    required this.format,
    required this.text,
    required this.taskCount,
  });

  /// The list or view this is an export of.
  final String title;

  /// Suggested file name, e.g. `axiotask-groceries-20260915.md`.
  final String fileName;

  /// Which format [text] is in.
  final ViewExportFormat format;

  /// The document itself: UTF-8, LF-terminated, no byte-order mark.
  final String text;

  /// How many tasks were written, subtasks included.
  final int taskCount;

  String get mimeType => format.mimeType;
}

/// Builds the export of the view named [title].
///
/// [rows] are the view's displayed top-level tasks in display order. Each
/// row's subtasks are resolved from [tasks] (the account's cached tasks, in
/// stored order), and list names from [taskLists]. [showCompleted] is the
/// view's completed filter, applied to subtasks too. [today] is the local
/// calendar day, used for the file name and the year in Markdown dates.
ViewExportDocument buildViewExport({
  required String title,
  required List<CachedTask> rows,
  required List<CachedTask> tasks,
  required List<CachedTaskList> taskLists,
  required bool showCompleted,
  required ViewExportFormat format,
  required TaskDate today,
}) {
  bool kept(CachedTask task) =>
      showCompleted || task.status != TaskStatus.completed;

  final topLevel = rows
      .where((task) => task.parentTaskId == null && kept(task))
      .toList(growable: false);
  final shown = {for (final task in topLevel) task.id};
  final children = <TaskId, List<CachedTask>>{};
  for (final task in tasks) {
    final parent = task.parentTaskId;
    if (parent == null || !shown.contains(parent) || !kept(task)) continue;
    (children[parent] ??= <CachedTask>[]).add(task);
  }
  final entries = <_Entry>[
    for (final row in topLevel) ...<_Entry>[
      _Entry(row, null),
      for (final child in children[row.id] ?? const <CachedTask>[])
        _Entry(child, row),
    ],
  ];
  final listTitles = {for (final list in taskLists) list.id: list.title};

  return ViewExportDocument(
    title: title,
    fileName: viewExportFileName(title, format, today),
    format: format,
    text: switch (format) {
      ViewExportFormat.markdown => _markdown(title, entries, today),
      ViewExportFormat.csv => _csv(entries, listTitles),
    },
    taskCount: entries.length,
  );
}

/// `axiotask-<slug>-<YYYYMMDD>.<ext>` on the local calendar [today].
String viewExportFileName(
  String title,
  ViewExportFormat format,
  TaskDate today,
) {
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${today.year.toString().padLeft(4, '0')}${two(today.month)}'
      '${two(today.day)}';
  return 'axiotask-${_slug(title)}-$stamp.${format.extension}';
}

/// A filename-safe slug: lowercase ASCII letters and digits, every other run
/// collapsed to one dash, capped at 40 characters. A title with nothing
/// sluggable in it (an emoji-only name) falls back to `tasks`.
String _slug(String title) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final capped = slug.length <= 40 ? slug : slug.substring(0, 40);
  final trimmed = capped.replaceAll(RegExp(r'-+$'), '');
  return trimmed.isEmpty ? 'tasks' : trimmed;
}

final class _Entry {
  const _Entry(this.task, this.parent);

  final CachedTask task;
  final CachedTask? parent;
}

String _markdown(String title, List<_Entry> entries, TaskDate today) {
  final out = StringBuffer()
    ..writeln('# ${escapeMarkdownText(_oneLine(title))}')
    ..writeln();
  if (entries.isEmpty) {
    out.writeln('_No tasks._');
    return out.toString();
  }
  for (final entry in entries) {
    _markdownItem(out, entry.task, entry.parent == null ? '' : '  ', today);
  }
  return out.toString();
}

/// One checklist item at [indent], plus its notes paragraph when it has one.
///
/// The notes are fenced by blank lines so they render as a paragraph of the
/// item, indented to the item's content column; an item without notes writes
/// no blank line, so a plain checklist stays tight.
void _markdownItem(
  StringBuffer out,
  CachedTask task,
  String indent,
  TaskDate today,
) {
  final box = task.status == TaskStatus.completed ? '[x]' : '[ ]';
  final due = task.due;
  final dueLabel = due == null ? '' : ' — ${_absoluteDate(due, today)}';
  out.writeln(
    '$indent- $box ${escapeMarkdownText(_oneLine(task.title))}$dueLabel',
  );
  final notes = task.notes?.replaceAll('\r\n', '\n').trim() ?? '';
  if (notes.isEmpty) return;
  out.writeln();
  for (final line in notes.split(RegExp('[\r\n]'))) {
    final text = line.trim();
    out.writeln(text.isEmpty ? '' : '$indent  ${_escapeMarkdownLine(text)}');
  }
  out.writeln();
}

const _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _absoluteDate(TaskDate date, TaskDate today) {
  final label = '${_months[date.month - 1]} ${date.day}';
  return date.year == today.year ? label : '$label, ${date.year}';
}

/// Collapses a value onto one line: a title carrying a line break would
/// otherwise split one checklist item into an item and a stray paragraph.
String _oneLine(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Characters that are inline markup in CommonMark/GFM: emphasis, code,
/// links, images, autolinks and raw HTML, entities, strikethrough and table
/// cells. Backslash-escaping each one keeps the text literal.
final _inlineMarkup = RegExp(r'[\\`*_\[\]<>&~|!]');

/// Escapes [value] so it renders as the same literal text inside a Markdown
/// paragraph or list item.
String escapeMarkdownText(String value) =>
    value.replaceAllMapped(_inlineMarkup, (match) => '\\${match[0]}');

/// Escapes one notes line, which (unlike a title after `- [ ] `) starts a
/// line, so block markers — headings, quotes, list bullets, ordered-list
/// numbers, thematic breaks, setext underlines and fences — must not open a
/// block.
String _escapeMarkdownLine(String line) {
  final escaped = escapeMarkdownText(line);
  final ordered = RegExp(r'^(\d{1,9})([.)])').firstMatch(escaped);
  if (ordered != null) {
    return '${ordered[1]}\\${ordered[2]}'
        '${escaped.substring(ordered.end)}';
  }
  if (escaped.startsWith(RegExp('[#>+=:-]'))) return '\\$escaped';
  return escaped;
}

String _csv(List<_Entry> entries, Map<TaskListId, String> listTitles) {
  final out = StringBuffer()..write('${viewExportCsvHeader.join(',')}\n');
  for (final entry in entries) {
    final task = entry.task;
    final row = <String>[
      task.title,
      listTitles[task.taskListId] ?? '',
      task.due?.toString() ?? '',
      switch (task.status) {
        TaskStatus.needsAction => 'needsAction',
        TaskStatus.completed => 'completed',
      },
      _completedAt(task),
      task.notes ?? '',
      entry.parent?.title ?? '',
    ];
    out.write('${row.map(_csvField).join(',')}\n');
  }
  return out.toString();
}

String _completedAt(CachedTask task) {
  final completedAt = task.completedAt;
  if (task.status != TaskStatus.completed || completedAt == null) return '';
  return completedAt.toUtc().toIso8601String();
}

/// RFC 4180: quote a field holding a comma, a quote or a line break, and
/// double each quote inside it. Everything else is written bare.
String _csvField(String value) {
  final needsQuotes =
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r');
  if (!needsQuotes) return value;
  return '"${value.replaceAll('"', '""')}"';
}
