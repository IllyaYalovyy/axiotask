import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Touch helpers for the due-date calendar dialog (Android audit case 09),
/// shared by host widget tests and the native regression contract.
final calendarDialog = find.byKey(const Key('task-date-calendar-dialog'));
final calendarPicker = find.byKey(const Key('task-date-calendar'));
final calendarSelection = find.byKey(const Key('task-date-calendar-selection'));
final calendarSet = find.byKey(const Key('task-date-calendar-set'));
final calendarClear = find.byKey(const Key('task-date-calendar-clear'));
final calendarCancel = find.byKey(const Key('task-date-calendar-cancel'));

const _localizations = DefaultMaterialLocalizations();

/// The header text the calendar shows while displaying [year]/[month].
String calendarMonthLabel(int year, int month) =>
    _localizations.formatMonthYear(DateTime.utc(year, month));

/// The selection summary for [date], or for no selection.
String calendarSelectionLabel(TaskDate? date) => date == null
    ? 'No date selected'
    : _localizations.formatFullDate(
        DateTime.utc(date.year, date.month, date.day),
      );

/// Asserts the dialog shows [year]/[month] with [selected] as its selection,
/// both in the summary and as the selected day cell's semantics.
void expectCalendarState(
  WidgetTester tester, {
  required int year,
  required int month,
  required TaskDate? selected,
}) {
  expect(calendarPicker, findsOneWidget, reason: 'the calendar is open');
  expect(
    find.descendant(
      of: calendarPicker,
      matching: find.text(calendarMonthLabel(year, month)),
    ),
    findsOneWidget,
    reason: 'the calendar displays $year-$month',
  );
  expect(
    tester.widget<Text>(calendarSelection).data,
    calendarSelectionLabel(selected),
  );
  if (selected != null && selected.year == year && selected.month == month) {
    expect(
      tester.getSemantics(_day(selected.day)),
      isSemantics(isSelected: true),
      reason: '${selected.day} is the selected day cell',
    );
  }
}

/// Moves the calendar from [from] to [to] (year, month) by touch: the
/// month/year header and year grid change the year, then the month arrows
/// step through months. The header must name every month it passes.
Future<void> navigateCalendar(
  WidgetTester tester, {
  required (int, int) from,
  required (int, int) to,
}) async {
  var (year, month) = from;
  if (year != to.$1) {
    await tester.tap(
      find.descendant(
        of: calendarPicker,
        matching: find.text(calendarMonthLabel(year, month)),
      ),
    );
    await tester.pumpAndSettle();
    final yearCell = find.descendant(
      of: calendarPicker,
      matching: find.text('${to.$1}'),
    );
    // The year grid builds lazily around the displayed year, so a distant
    // year is first scrolled into the grid, then the grid into the dialog.
    final yearGrid = find.descendant(
      of: calendarPicker,
      matching: find.byType(Scrollable),
    );
    expect(yearGrid, findsOneWidget, reason: 'the year grid is open');
    await tester.scrollUntilVisible(
      yearCell,
      to.$1 > year ? 52 : -52,
      scrollable: yearGrid,
      maxScrolls: 200,
    );
    await tester.ensureVisible(yearCell);
    await tester.pumpAndSettle();
    await tester.tap(yearCell);
    await tester.pumpAndSettle();
    year = to.$1;
  }
  final step = (to.$1 * 12 + to.$2) - (year * 12 + month);
  final arrow = find.descendant(
    of: calendarPicker,
    matching: find.byTooltip(step > 0 ? 'Next month' : 'Previous month'),
  );
  for (var index = 0; index < step.abs(); index += 1) {
    await tester.ensureVisible(arrow);
    await tester.pumpAndSettle();
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    final shown = DateTime.utc(year, month + (step > 0 ? 1 : -1));
    (year, month) = (shown.year, shown.month);
    expect(
      find.descendant(
        of: calendarPicker,
        matching: find.text(calendarMonthLabel(year, month)),
      ),
      findsOneWidget,
    );
  }
}

/// Taps [day] in the displayed month, scrolling it into view first.
Future<void> tapCalendarDay(WidgetTester tester, int day) async {
  final cell = _day(day);
  await tester.ensureVisible(cell);
  await tester.pumpAndSettle();
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

/// Taps one of the dialog's actions after scrolling it into view.
Future<void> tapCalendarAction(WidgetTester tester, Finder action) async {
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  await tester.tap(action);
  await tester.pump();
}

Finder _day(int day) {
  final cell = find.descendant(of: calendarPicker, matching: find.text('$day'));
  expect(cell, findsOneWidget, reason: 'day $day is shown once');
  return cell;
}
