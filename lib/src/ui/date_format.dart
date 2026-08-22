// Shared due-date formatting — the Dart port of `dateFormat.js`'s `formatDue`
// (used by the quick-add preview chip now; the task rows and detail panel adopt
// it in T7.2/T7.3). Friendly relative labels near today, an absolute "Mon D"
// (with a year only when it differs) further out — never the raw ISO string
// (#78b). "Now" comes from `package:clock`, never the wall clock.

import 'package:clock/clock.dart';

const List<String> _monthAbbr = [
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

/// Parse the `YYYY-MM-DD` head of a due value into a LOCAL midnight date.
///
/// Due values are date-only (Google sends midnight UTC, e.g.
/// `2026-06-15T00:00:00.000Z`). Parsing the whole string as UTC and rendering
/// in local time shifts to the previous day in negative-UTC zones (#76), so we
/// read the calendar Y-M-D and build a LOCAL date from it.
DateTime parseLocalDate(String due) {
  final head = due.length >= 10 ? due.substring(0, 10) : due;
  final parts = head.split('-');
  final y = int.parse(parts[0]);
  final m = int.parse(parts[1]);
  final d = int.parse(parts[2]);
  return DateTime(y, m, d);
}

/// How urgent a due date is, for the task row's due-badge color (port of
/// `dateFormat.js`'s `dueClass`).
enum DueUrgency {
  /// No date, or a future date — the muted default.
  none,

  /// Due today.
  today,

  /// Due before today.
  overdue,
}

/// Classify [due] relative to "now" (from `package:clock`) for the row's due
/// badge. Undated/blank and future dates are [DueUrgency.none].
DueUrgency dueUrgency(String? due) {
  if (due == null || due.isEmpty) return DueUrgency.none;
  final d = parseLocalDate(due);
  final n = clock.now();
  final now = DateTime(n.year, n.month, n.day);
  final diff = d.difference(now).inDays;
  if (diff < 0) return DueUrgency.overdue;
  if (diff == 0) return DueUrgency.today;
  return DueUrgency.none;
}

/// A friendly, relative due label for [due] (a `YYYY-MM-DD…` string), or the
/// empty string when [due] is null/empty. Never returns the raw ISO string.
String formatDue(String? due) {
  if (due == null || due.isEmpty) return '';
  final d = parseLocalDate(due);
  final n = clock.now();
  final now = DateTime(n.year, n.month, n.day);
  final diff = d.difference(now).inDays;
  if (diff < -1) return '${-diff}d overdue';
  if (diff == -1) return 'yesterday';
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  if (diff < 7) return 'in ${diff}d';
  // Show the year only when it isn't the current calendar year.
  final month = _monthAbbr[d.month - 1];
  return d.year != now.year ? '$month ${d.day}, ${d.year}' : '$month ${d.day}';
}

/// An absolute LOCAL date-and-time label for a stored instant — "Jun 15 14:05",
/// with the year added only when it differs from the current one.
///
/// Sync stamps are persisted as UTC instants but read by a human sitting in a
/// local timezone, so [instant] is converted with [DateTime.toLocal] before a
/// single field is read (#218). 24-hour, zero-padded: unambiguous without a
/// locale, and every row lines up in the Sync activity list. "The current year"
/// comes from `package:clock`, never the wall clock.
String formatAbsoluteLocal(DateTime instant) {
  final t = instant.toLocal();
  final now = clock.now();
  String pad(int n) => n.toString().padLeft(2, '0');
  final time = '${pad(t.hour)}:${pad(t.minute)}';
  final day = '${_monthAbbr[t.month - 1]} ${t.day}';
  return t.year != now.year ? '$day, ${t.year} $time' : '$day $time';
}

/// A relative "how long ago" label for a past [instant] — `'never'` when there
/// is none (the sync stats' "never synced" state, #218). "Now" comes from
/// `package:clock`, never the wall clock.
String formatRelativeSince(DateTime? instant) {
  if (instant == null) return 'never';
  final diff = clock.now().toUtc().difference(instant.toUtc());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
