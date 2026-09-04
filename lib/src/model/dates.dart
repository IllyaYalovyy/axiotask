// Pure date arithmetic for one-keystroke due-date moves (RFC-008) plus
// due-string canonicalization and UTC now-stamps; no IO. The Dart port of
// `dates.rs`. Wall time comes from `package:clock`'s ambient `clock`, never the
// wall-clock constructor (the gate bans that below lib/).

import 'package:clock/clock.dart';

/// Canonicalize a due-date string to the exact form the Google Tasks API emits
/// and requires: `YYYY-MM-DDT00:00:00.000Z`.
///
/// Google rejects a bare `YYYY-MM-DD` with 400 and normalizes any accepted
/// timestamp to `.000Z` in responses (both verified live), so a locally stored
/// `...T00:00:00Z` never string-equals what the server sends back. Parsing is
/// prefix-based: only the leading ten characters are read, and they must be a
/// valid `YYYY-MM-DD` (Feb 30 is rejected, not clamped). Returns `null` when
/// the input has no parseable date prefix.
String? normalizeDue(String raw) {
  // Prefix-based: read exactly the leading ten characters. substring never
  // throws on a surrogate split (it slices by code unit), so a short or
  // multibyte input simply fails the shape check below rather than panicking.
  if (raw.length < 10) return null;
  final head = raw.substring(0, 10);
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(head);
  if (m == null) return null;
  final year = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[3]!);
  // Validate the calendar date: DateTime normalizes overflow (Feb 30 → Mar 2),
  // so a round-trip mismatch means the date was invalid — reject, don't clamp.
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return '${m[1]}-${m[2]}-${m[3]}T00:00:00.000Z';
}

/// Current instant as a true-UTC RFC-3339 string with microsecond precision —
/// the single source for `local_updated` stamps. Sub-second precision guards
/// the push mark-clean race (two edits within the same second must not
/// collide), so consecutive calls against an advancing clock differ.
String nowUtcString() {
  final t = clock.now().toUtc();
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  final micros = t.millisecond * 1000 + t.microsecond;
  return '${pad(t.year, 4)}-${pad(t.month, 2)}-${pad(t.day, 2)}'
      'T${pad(t.hour, 2)}:${pad(t.minute, 2)}:${pad(t.second, 2)}'
      '.${pad(micros, 6)}Z';
}

/// What date-move the user requested (RFC-008 one-keystroke moves).
enum DateMove {
  /// `today` (the current date).
  today,

  /// `today + 1 day`.
  tomorrow,

  /// `today + 7 days`.
  nextWeek,

  /// `today + 1 month`, clamped to month-end.
  nextMonth,

  /// Clear the due date.
  clear,
}

/// Apply [mv] relative to [today] (a date-only UTC value). `null` means "clear
/// the due date". [today] should be a UTC midnight so day arithmetic is
/// DST-free.
DateTime? applyDateMove(DateTime today, DateMove mv) => switch (mv) {
  DateMove.today => today,
  DateMove.tomorrow => today.add(const Duration(days: 1)),
  DateMove.nextWeek => today.add(const Duration(days: 7)),
  DateMove.nextMonth => nextMonthClamped(today),
  DateMove.clear => null,
};

/// `today + 1 month`, clamped to the target month's last day (Jan 31 → Feb 28,
/// or Feb 29 in a leap year).
DateTime nextMonthClamped(DateTime today) {
  var year = today.year;
  var month = today.month;
  if (month == 12) {
    month = 1;
    year += 1;
  } else {
    month += 1;
  }
  // Day 0 of the month after the target is the target month's last day.
  final lastDayOfTarget = DateTime.utc(year, month + 1, 0).day;
  final day = today.day < lastDayOfTarget ? today.day : lastDayOfTarget;
  return DateTime.utc(year, month, day);
}

/// A calendar day as the bare `YYYY-MM-DD` every composer, chip and picker in
/// the app passes around (the same shape [normalizeDue] parses and
/// `parseQuickAddDue` returns), so no surface has to invent its own formatting.
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// The bare `YYYY-MM-DD` [move] resolves to against TODAY, or `null` for
/// [DateMove.clear]. The one place the quick-date vocabulary is turned into a
/// date for a surface that has no task to write it to yet — the composer's
/// draft — so the date a chip advertises and the date a create lands with are
/// resolved by the same arithmetic the command layer uses.
String? ymdForMove(DateMove move) {
  final n = clock.now();
  final today = DateTime.utc(n.year, n.month, n.day);
  final moved = applyDateMove(today, move);
  return moved == null ? null : ymd(moved);
}
