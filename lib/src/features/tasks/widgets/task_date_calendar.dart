import 'package:material_ui/material_ui.dart';

import '../../../domain/model/tasks.dart';
import '../task_detail_view_model.dart';

/// Platforms that choose a due date from a calendar, as v1.5.3 did on
/// phones. Desktop platforms keep the keyboard-first typed date dialog.
const calendarDatePlatforms = <TargetPlatform>{
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.fuchsia,
};

/// The calendar day that displays [date].
///
/// A due date is a date-only value. The calendar works in UTC fields, so no
/// local midnight is ever constructed: in zones whose clocks skip midnight
/// (a daylight-saving gap) or a whole day, a local [DateTime] for the date
/// would name a different calendar day.
DateTime calendarDayOf(TaskDate date) =>
    DateTime.utc(date.year, date.month, date.day);

/// The due date a calendar day selects; the inverse of [calendarDayOf].
TaskDate taskDateOfCalendarDay(DateTime day) =>
    TaskDate(day.year, day.month, day.day);

/// Gregorian calendar arithmetic in UTC fields, with "today" taken from the
/// application's clock rather than the wall clock.
///
/// The Material default builds local [DateTime]s, which in some time zones
/// turn a date that has no local midnight into the previous or next day.
final class TaskDateCalendarDelegate extends GregorianCalendarDelegate {
  const TaskDateCalendarDelegate({required this.today});

  final TaskDate today;

  @override
  DateTime now() => calendarDayOf(today);

  @override
  DateTime dateOnly(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day);

  @override
  DateTime addMonthsToMonthDate(DateTime monthDate, int monthsToAdd) =>
      DateTime.utc(monthDate.year, monthDate.month + monthsToAdd);

  @override
  DateTime addDaysToDate(DateTime date, int days) =>
      DateTime.utc(date.year, date.month, date.day + days);

  @override
  int firstDayOffset(int year, int month, MaterialLocalizations localizations) {
    // Both indices are Monday-based, as in DateUtils.firstDayOffset.
    final weekdayFromMonday = DateTime.utc(year, month).weekday - 1;
    final firstDayOfWeek = (localizations.firstDayOfWeekIndex - 1) % 7;
    return (weekdayFromMonday - firstDayOfWeek) % 7;
  }

  @override
  DateTime getMonth(int year, int month) => DateTime.utc(year, month);

  @override
  DateTime getDay(int year, int month, int day) =>
      DateTime.utc(year, month, day);
}

/// The calendar's first and last selectable days: 2000 through 2100, widened
/// to include [today] and the task's current date so neither is out of range.
({DateTime first, DateTime last}) calendarRange({
  required TaskDate today,
  TaskDate? current,
}) {
  var first = DateTime.utc(2000);
  var last = DateTime.utc(2100, 12, 31);
  for (final date in <TaskDate?>[today, current]) {
    if (date == null) continue;
    final day = calendarDayOf(date);
    if (day.isBefore(first)) first = day;
    if (day.isAfter(last)) last = day;
  }
  return (first: first, last: last);
}

/// Chooses a due date for one task from a calendar.
///
/// The calendar opens on the task's current due date (or today's month when
/// it has none) with that day selected. Month arrows and the month/year
/// header navigate; tapping a day only selects it. `Set date` commits the
/// selection and `Clear date` removes the date, both through the shared due
/// command (so the parent/subtask cascade and its Undo apply); Cancel, Back
/// and a tap outside change nothing. A failed command keeps the dialog open
/// with the failure shown.
final class TaskCalendarDateDialog extends StatefulWidget {
  const TaskCalendarDateDialog({
    required this.viewModel,
    required this.task,
    super.key,
  });

  final TaskDetailViewModel viewModel;
  final CachedTask task;

  @override
  State<TaskCalendarDateDialog> createState() => _TaskCalendarDateDialogState();
}

final class _TaskCalendarDateDialogState extends State<TaskCalendarDateDialog> {
  late final TaskDate _today = widget.viewModel.today;
  late final TaskDate? _initial = _currentDue;
  late final _delegate = TaskDateCalendarDelegate(today: _today);
  late final _range = calendarRange(today: _today, current: _initial);
  late DateTime? _selected = switch (_initial) {
    final due? => calendarDayOf(due),
    null => null,
  };
  bool _submitted = false;

  /// The task's stored date now, which a sync or another edit may have
  /// changed since the dialog opened.
  TaskDate? get _currentDue =>
      (widget.viewModel.taskById(widget.task.id) ?? widget.task).due;

  Future<void> _commit(TaskDate? due) async {
    if (due == _currentDue) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _submitted = true);
    await widget.viewModel.setDue(widget.task.id, due);
    if (mounted && widget.viewModel.commandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) {
      final pending = widget.viewModel.isCommandPending;
      final failure = _submitted
          ? widget.viewModel.commandFailureMessage
          : null;
      final selected = _selected;
      final landscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final theme = Theme.of(context);
      final localizations = MaterialLocalizations.of(context);

      // Like Material's own date picker, the header and actions scale text
      // up to 1.6x and the day grid up to 1.3x, so a narrow or landscape
      // phone at 2x text still shows the selection, whole day numbers and
      // the actions together.
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Choose due date',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(
              selected == null
                  ? 'No date selected'
                  : localizations.formatFullDate(selected),
              key: const Key('task-date-calendar-selection'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (failure != null) ...<Widget>[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                failure,
                key: const Key('task-date-calendar-failure'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      );
      final calendar = SingleChildScrollView(
        key: const Key('task-date-calendar-scroll'),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: _maxCalendarTextScale,
          child: CalendarDatePicker(
            key: const Key('task-date-calendar'),
            initialDate: selected,
            firstDate: _range.first,
            lastDate: _range.last,
            currentDate: calendarDayOf(_today),
            calendarDelegate: _delegate,
            onDateChanged: (day) =>
                setState(() => _selected = _delegate.dateOnly(day)),
          ),
        ),
      );
      // Clear date wraps above Cancel and Set date before they stack.
      final actions = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          TextButton(
            key: const Key('task-date-calendar-clear'),
            onPressed: pending || _currentDue == null
                ? null
                : () => _commit(null),
            child: const Text('Clear date'),
          ),
          OverflowBar(
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 8,
            overflowSpacing: 4,
            children: <Widget>[
              TextButton(
                key: const Key('task-date-calendar-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('task-date-calendar-set'),
                onPressed: pending || selected == null
                    ? null
                    : () => _commit(taskDateOfCalendarDay(selected)),
                child: pending && _submitted
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Set date'),
              ),
            ],
          ),
        ],
      );

      return Dialog(
        key: const Key('task-date-calendar-dialog'),
        insetPadding: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: landscape ? 720 : 400),
          child: landscape
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Flexible(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(
                              child: SingleChildScrollView(
                                child: _clampText(summary),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _clampText(actions),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Flexible(flex: 3, child: calendar),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                      child: _clampText(summary),
                    ),
                    const Divider(height: 1),
                    Flexible(child: calendar),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: _clampText(actions),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

/// Largest text scale of the dialog's header and actions (Material's date
/// picker header limit).
const _maxHeaderTextScale = 1.6;

/// Largest text scale of the day grid, which keeps two-digit days whole in
/// the narrowest phone width.
const _maxCalendarTextScale = 1.3;

Widget _clampText(Widget child) => MediaQuery.withClampedTextScaling(
  maxScaleFactor: _maxHeaderTextScale,
  child: child,
);
