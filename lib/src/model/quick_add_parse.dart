// Quick-add natural-language trailing-date parser — the Dart port of
// App.svelte's `parseQuickAddDue`. Per RFC-011 this is model-layer logic.
//
// Recognizes a trailing date phrase at the END of the typed title:
//   • "on YYYY-MM-DD" / bare "YYYY-MM-DD"
//   • "today" / "tomorrow" / "next week" / "next month"  (optional "due " lead)
// and returns the resolved due date as a `YYYY-MM-DD` string, or `null` when no
// phrase is present. The typed title itself is NEVER rewritten — the caller
// keeps it verbatim; this parser only reports the date.
//
// Strip-leaves-title rule: a phrase counts as a date only if removing it leaves
// a non-empty title. So "tomorrow" alone is a title, not a date — the phrase
// must trail some actual title text. Relative dates resolve against the current
// calendar day via `package:clock`'s ambient `clock` (never the wall clock).

import 'package:clock/clock.dart';

import 'dates.dart';

/// Parse a trailing natural-language due date out of [raw]. Returns the due date
/// as `YYYY-MM-DD`, or `null` when there is no trailing date phrase (or removing
/// it would leave an empty title).
String? parseQuickAddDue(String raw) {
  final title = raw.trim();
  final lowered = title.toLowerCase();

  final now = clock.now();
  // Date-only arithmetic on the current CALENDAR day, done in UTC so day
  // additions are DST-free (we only ever read back Y-M-D).
  final today = DateTime.utc(now.year, now.month, now.day);
  String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
  String moved(DateMove mv) => fmt(applyDateMove(today, mv)!);

  final patterns = <(RegExp, String Function(RegExpMatch))>[
    (RegExp(r'\s+(?:on\s+)?(\d{4}-\d{2}-\d{2})$'), (m) => m.group(1)!),
    (RegExp(r'\s+(?:due\s+)?today$'), (_) => moved(DateMove.today)),
    (RegExp(r'\s+(?:due\s+)?tomorrow$'), (_) => moved(DateMove.tomorrow)),
    (RegExp(r'\s+(?:due\s+)?next week$'), (_) => moved(DateMove.nextWeek)),
    (RegExp(r'\s+(?:due\s+)?next month$'), (_) => moved(DateMove.nextMonth)),
  ];

  for (final (re, resolve) in patterns) {
    final m = re.firstMatch(lowered);
    if (m == null) continue;
    // Strip-leaves-title rule: the phrase counts as a date only when removing
    // it leaves a non-empty title (so "tomorrow" alone stays a title).
    final stripped = title
        .substring(0, title.length - m.group(0)!.length)
        .trim();
    if (stripped.isEmpty) return null;
    return resolve(m);
  }
  return null;
}
