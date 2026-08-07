// Quick-add resolution logic — the pure decisions behind the always-visible
// quick-add bar (App.svelte's `quickAddDueFor` + the NL preview via the
// model-layer `parseQuickAddDue`). Kept pure and clock-driven so the "what date
// does a quick-add get" contract is unit-tested without pumping a widget; the
// bar widget (pin-to-top, detail-follow, the preview chip) is UI on top.

import 'package:clock/clock.dart';

export '../model/quick_add_parse.dart' show parseQuickAddDue;

/// The auto-applied due date for a task quick-added from smart view [viewId],
/// as a bare `YYYY-MM-DD`, or `null` when the view imposes no date.
///
/// Focus shows today's tasks, so a task added there is due **today** (else it
/// would not appear in the view it was created from). Upcoming is next week, so
/// its default is **+7 days**. Missed can't be born overdue, so today is the
/// honest default (the bar then toasts that it landed in Focus). Unscheduled,
/// All, and concrete lists impose no date — an undated task is visible there
/// as-is. Port of `App.svelte::quickAddDueFor`.
String? quickAddDueFor(String viewId) {
  final now = clock.now();
  final today = DateTime.utc(now.year, now.month, now.day);
  String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
  return switch (viewId) {
    'focus' => fmt(today),
    'upcoming' => fmt(today.add(const Duration(days: 7))),
    'missed' => fmt(today),
    _ => null,
  };
}
