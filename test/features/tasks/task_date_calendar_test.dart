import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/widgets/task_date_calendar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Date-only semantics of the phone due-date calendar (Android audit 09).
///
/// These hold in every process time zone. Run them with, for example,
/// `TZ=Pacific/Apia`, `TZ=America/Santiago` or `TZ=America/Sao_Paulo`, whose
/// local clocks skip a whole day or midnight, to exercise the cases where a
/// local [DateTime] would name a different calendar day.
void main() {
  final delegate = TaskDateCalendarDelegate(today: TaskDate(2026, 11, 15));

  test('every calendar day from 1999 to 2031 maps to the same task date', () {
    var day = DateTime.utc(1999);
    var count = 0;
    while (day.year < 2032) {
      final date = TaskDate(day.year, day.month, day.day);
      final shown = calendarDayOf(date);
      expect(shown.isUtc, isTrue);
      expect(
        (shown.year, shown.month, shown.day),
        (date.year, date.month, date.day),
      );
      expect(taskDateOfCalendarDay(shown), date);
      // The calendar builds and normalizes day cells through the delegate.
      final built = delegate.getDay(date.year, date.month, date.day);
      expect(taskDateOfCalendarDay(delegate.dateOnly(built)), date);
      day = day.add(const Duration(days: 1));
      count += 1;
    }
    expect(count, 12053);
  });

  test('days whose local midnight is skipped keep their calendar day', () {
    for (final date in <TaskDate>[
      TaskDate(2011, 12, 30), // Pacific/Apia skipped this whole day
      TaskDate(2018, 11, 4), // America/Sao_Paulo skipped midnight
      TaskDate(2026, 9, 6), // America/Santiago skips midnight
      TaskDate(2026, 3, 8), // US daylight-saving start
      TaskDate(2026, 11, 1), // US daylight-saving end
    ]) {
      final built = delegate.getDay(date.year, date.month, date.day);
      expect(built.isUtc, isTrue, reason: '$date');
      expect(taskDateOfCalendarDay(built), date);
      expect(
        taskDateOfCalendarDay(delegate.addDaysToDate(built, 1)),
        _shift(date, 1),
      );
      expect(
        taskDateOfCalendarDay(delegate.addDaysToDate(built, -1)),
        _shift(date, -1),
      );
    }
  });

  test('month and year arithmetic crosses boundaries without local time', () {
    expect(
      delegate.addMonthsToMonthDate(DateTime.utc(2026, 12), 1),
      DateTime.utc(2027),
    );
    expect(
      delegate.addMonthsToMonthDate(DateTime.utc(2027), -1),
      DateTime.utc(2026, 12),
    );
    expect(
      delegate.addMonthsToMonthDate(DateTime.utc(2026, 11), 15),
      DateTime.utc(2028, 2),
    );
    expect(
      taskDateOfCalendarDay(
        delegate.addDaysToDate(DateTime.utc(2026, 12, 31), 1),
      ),
      TaskDate(2027, 1, 1),
    );
    expect(
      taskDateOfCalendarDay(
        delegate.addDaysToDate(DateTime.utc(2028, 2, 28), 1),
      ),
      TaskDate(2028, 2, 29),
    );
    expect(delegate.getDaysInMonth(2028, 2), 29);
    expect(delegate.getDaysInMonth(2024, 2), 29);
    expect(delegate.getDaysInMonth(2000, 2), 29);
    expect(delegate.getDaysInMonth(2100, 2), 28);
    expect(delegate.getDaysInMonth(2026, 2), 28);
    expect(delegate.getMonth(2028, 2), DateTime.utc(2028, 2));
  });

  test('the first weekday offset follows the UTC weekday and locale', () {
    const sundayFirst = DefaultMaterialLocalizations();
    // 2026-11-01 is a Sunday, 2028-02-01 a Tuesday, 2027-01-01 a Friday.
    expect(delegate.firstDayOffset(2026, 11, sundayFirst), 0);
    expect(delegate.firstDayOffset(2028, 2, sundayFirst), 2);
    expect(delegate.firstDayOffset(2027, 1, sundayFirst), 5);
    final mondayFirst = _MondayFirstLocalizations();
    expect(delegate.firstDayOffset(2026, 11, mondayFirst), 6);
    expect(delegate.firstDayOffset(2028, 2, mondayFirst), 1);
    expect(delegate.firstDayOffset(2027, 1, mondayFirst), 4);
  });

  test('today comes from the application clock, not the wall clock', () {
    expect(delegate.now(), DateTime.utc(2026, 11, 15));
    expect(
      TaskDateCalendarDelegate(today: TaskDate(2028, 2, 29)).now(),
      DateTime.utc(2028, 2, 29),
    );
  });

  test('the range includes today and an out-of-range current date', () {
    final standard = calendarRange(today: TaskDate(2026, 11, 15));
    expect(standard.first, DateTime.utc(2000));
    expect(standard.last, DateTime.utc(2100, 12, 31));
    final early = calendarRange(
      today: TaskDate(2026, 11, 15),
      current: TaskDate(1995, 6, 1),
    );
    expect(early.first, DateTime.utc(1995, 6, 1));
    final late = calendarRange(
      today: TaskDate(2026, 11, 15),
      current: TaskDate(2150, 1, 2),
    );
    expect(late.last, DateTime.utc(2150, 1, 2));
  });
}

/// [date] moved by [days], computed independently of the delegate.
TaskDate _shift(TaskDate date, int days) {
  final value = DateTime.fromMillisecondsSinceEpoch(
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch +
        days * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return TaskDate(value.year, value.month, value.day);
}

final class _MondayFirstLocalizations extends DefaultMaterialLocalizations {
  @override
  int get firstDayOfWeekIndex => 1;
}
