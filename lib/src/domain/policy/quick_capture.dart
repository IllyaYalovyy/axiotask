import '../model/tasks.dart';
import 'date_workflow.dart';

final class QuickCaptureParseResult {
  const QuickCaptureParseResult({
    required this.rawTitle,
    required this.title,
    required this.due,
  });

  final String rawTitle;
  final String title;
  final TaskDate? due;

  bool get hasDatePreview => due != null;

  @override
  bool operator ==(Object other) =>
      other is QuickCaptureParseResult &&
      rawTitle == other.rawTitle &&
      title == other.title &&
      due == other.due;

  @override
  int get hashCode => Object.hash(rawTitle, title, due);
}

QuickCaptureParseResult parseQuickCapture(
  String rawTitle, {
  required TaskDate today,
}) {
  final title = rawTitle.trim();
  final patterns = <({RegExp expression, TaskDate? Function(String?) due})>[
    (
      expression: RegExp(
        r'\s+(?:on )?(\d{4}-\d{2}-\d{2})$',
        caseSensitive: false,
      ),
      due: _parseIsoDate,
    ),
    (
      expression: RegExp(r'\s+(?:due )?today$', caseSensitive: false),
      due: (_) => today,
    ),
    (
      expression: RegExp(r'\s+(?:due )?tomorrow$', caseSensitive: false),
      due: (_) => resolveDateShortcut(today, DateShortcut.tomorrow),
    ),
    (
      expression: RegExp(r'\s+(?:due )?next week$', caseSensitive: false),
      due: (_) => resolveDateShortcut(today, DateShortcut.nextWeek),
    ),
    (
      expression: RegExp(r'\s+(?:due )?next month$', caseSensitive: false),
      due: (_) => resolveDateShortcut(today, DateShortcut.nextMonth),
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.expression.firstMatch(title);
    if (match == null) continue;
    final stripped = title.substring(0, match.start).trim();
    if (stripped.isEmpty) break;
    final due = pattern.due(match.groupCount == 0 ? null : match.group(1));
    if (due == null) break;
    return QuickCaptureParseResult(
      rawTitle: rawTitle,
      title: stripped,
      due: due,
    );
  }
  return QuickCaptureParseResult(rawTitle: rawTitle, title: title, due: null);
}

TaskDate? _parseIsoDate(String? value) {
  if (value == null) return null;
  final parts = value.split('-');
  if (parts.length != 3) return null;
  try {
    return TaskDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  } on ArgumentError {
    return null;
  }
}
