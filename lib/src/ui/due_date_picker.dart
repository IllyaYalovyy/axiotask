// The due-date surface's calendar (T7.3, #37). A Material [CalendarDatePicker]
// in a dialog that the due badge / "no date" segment opens: it starts on the
// task's CURRENT due month (or today when undated), works entirely in LOCAL
// dates, and offers a one-tap Today and Clear beside Cancel. The caller maps the
// result onto [Commands.setDueRaw] (a picked day) or [Commands.setDue] with
// [DateMove.clear].
//
// Dates are LOCAL end to end (#76): a due value's `YYYY-MM-DD` head is read as a
// local calendar day and the chosen day is emitted the same way, so nothing ever
// shifts across a UTC boundary. "Today" comes from `package:clock`, never the
// wall clock (the gate bans DateTime.now below lib/).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../app/commands.dart' show Commands, SetDueResult;
import 'date_format.dart' show parseLocalDate;
import 'toast.dart' show ToastController;

/// What the picker returned. `null` from [showDueDatePicker] means the user
/// dismissed it (Cancel / barrier tap) — leave the date untouched.
sealed class DuePick {
  const DuePick();
}

/// A concrete day was chosen, as a LOCAL `YYYY-MM-DD` string.
class DuePickDate extends DuePick {
  const DuePickDate(this.ymd);

  /// The chosen calendar day, `YYYY-MM-DD` (local).
  final String ymd;

  @override
  bool operator ==(Object other) => other is DuePickDate && other.ymd == ymd;

  @override
  int get hashCode => ymd.hashCode;

  @override
  String toString() => 'DuePickDate($ymd)';
}

/// The user cleared the date.
class DuePickClear extends DuePick {
  const DuePickClear();
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// Open the calendar for [initial] (a raw due value, or `null`/empty when
/// undated) and resolve to the user's choice ([DuePickDate] / [DuePickClear]) or
/// `null` when dismissed.
Future<DuePick?> showDueDatePicker(BuildContext context, {String? initial}) {
  final n = clock.now();
  final today = DateTime(n.year, n.month, n.day);
  final start = (initial != null && initial.isNotEmpty)
      ? parseLocalDate(initial)
      : today;
  return showDialog<DuePick>(
    context: context,
    builder: (context) => _DueDatePickerDialog(initial: start, today: today),
  );
}

class _DueDatePickerDialog extends StatelessWidget {
  const _DueDatePickerDialog({required this.initial, required this.today});

  final DateTime initial;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      // Clamp text scaling the way the framework's own date picker does, so a
      // large accessibility scale can't overflow the fixed calendar grid.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A fixed height bounds the calendar's Expanded month grid inside the
              // shrink-wrapped dialog.
              SizedBox(
                height: 320,
                child: CalendarDatePicker(
                  initialDate: initial,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  // A day tap picks-and-closes in one gesture (the reference
                  // behaviour); month/year navigation does not fire this.
                  onDateChanged: (d) =>
                      Navigator.of(context).pop(DuePickDate(_ymd(d))),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    TextButton(
                      key: const Key('due-picker-clear'),
                      onPressed: () =>
                          Navigator.of(context).pop(const DuePickClear()),
                      child: const Text('Clear'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const Key('due-picker-today'),
                      onPressed: () =>
                          Navigator.of(context).pop(DuePickDate(_ymd(today))),
                      child: const Text('Today'),
                    ),
                    TextButton(
                      key: const Key('due-picker-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The #164 cascade toast wording for [res], or `null` when the edit moved no
/// other row (no toast). A pulled-down parent reads "Parent date moved to
/// match"; pulled-up children read "N subtask date(s) moved to match". Port of
/// the reference's `offerDueCascadeUndo` message. Pure so the DueConsistency
/// surface and its test share one source of truth.
String? dueCascadeMessage(SetDueResult res) {
  final n = res.cascaded;
  if (n == 0) return null;
  if (res.cascadedParent) return 'Parent date moved to match';
  return '$n subtask date${n == 1 ? '' : 's'} moved to match';
}

/// Surface the #164 cascade for [res] as an undoable toast, or do nothing when
/// the edit moved no other row. Shared by every due surface (the list row's
/// quick strip and the detail panel) so one edit-cascade-undo phrasing lives in
/// one place. Routes through the [ToastController] — the one feedback surface
/// (F19 #198) that out-stacks the detail panel a cascade may be edited from,
/// where a ScaffoldMessenger SnackBar would be hidden behind the panel. The
/// whole cascade reverts as one unit via [Commands.undoSetDue].
void offerDueCascadeUndo(
  ToastController toasts,
  Commands commands,
  SetDueResult res,
) {
  final message = dueCascadeMessage(res);
  if (message == null) return;
  toasts.showUndo(message, () => commands.undoSetDue(res.undo));
}
