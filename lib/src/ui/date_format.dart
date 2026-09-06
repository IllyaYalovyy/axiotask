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
  return formatAbsoluteDue(due);
}

/// An ABSOLUTE calendar-day label for [due] — "Sep 12", with the year appended
/// whenever it is not the current one.
///
/// [formatDue]'s tail, and what anything that OUTLIVES today must use instead
/// of it: a relative label ("in 3d") is true for one day, so an exported
/// document (#297) that carried one would be lying the morning after it was
/// written. "The current year" comes from `package:clock`.
String formatAbsoluteDue(String due) {
  final d = parseLocalDate(due);
  final month = _monthAbbr[d.month - 1];
  return d.year != clock.now().year
      ? '$month ${d.day}, ${d.year}'
      : '$month ${d.day}';
}

/// [formatDue]'s date in words a SCREEN READER can say (#289).
///
/// The badge is written for the eye — "5d overdue", "in 3d" — and a screen
/// reader is free to read "5d" as a letter after a number. Same reasoning as
/// the subtask pill's "1 of 3 subtasks complete" (#287): what is announced has
/// to be a phrase, not a glyph. The absolute form ("Jul 4") already is one, so
/// beyond a week out this IS [formatDue].
///
/// Returns the empty string when [due] is null/empty — an undated task has no
/// date to say, and the caller words that state itself.
String formatDueSpoken(String? due) {
  if (due == null || due.isEmpty) return '';
  final d = parseLocalDate(due);
  final n = clock.now();
  final now = DateTime(n.year, n.month, n.day);
  final diff = d.difference(now).inDays;
  if (diff < -1) return '${-diff} days ago';
  if (diff == -1) return 'yesterday';
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  if (diff < 7) return 'in $diff days';
  return formatDue(due);
}

/// The spoken NAME of a due-date CONTROL — "Due 5 days ago", or "No due date"
/// when there is none (#289/#299).
///
/// The row's date segment and the detail panel's Due field are the same
/// concept on two surfaces, and a screen reader must not hear a different
/// phrase depending on which one the user reached: the row said
/// "Due 5 days ago" while the panel said "5d overdue" for the very same task.
/// One task, one vocabulary — so the wording lives here, once, and both
/// surfaces read it.
///
/// The bare date ([formatDueSpoken]) is not enough on its own: neither surface
/// gives a screen reader the position or the colour a sighted user reads the
/// meaning off, so the label carries the field's name too.
String formatDueFieldSpoken(String? due) {
  final spoken = formatDueSpoken(due);
  return spoken.isEmpty ? 'No due date' : 'Due $spoken';
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

/// The last-synced label the Sync STATS surfaces render — the relative phrase,
/// and, when there is a stamp behind it, the absolute LOCAL time beside it:
/// "3m ago · Aug 22 10:48", or plain "never" (#218/#222).
///
/// Properties → Sync and the Sync activity screen both read this; the sidebar
/// footer does not (there the absolute time is a tooltip, never inline).
String formatLastSynced(DateTime? instant) => instant == null
    ? formatRelativeSince(null)
    : '${formatRelativeSince(instant)} · ${formatAbsoluteLocal(instant)}';
