import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/task_date_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = TaskDate(2026, 11, 15);

  test('names the day, adding the year only when it is not today\'s', () {
    expect(formatAbsoluteTaskDate(TaskDate(2026, 12, 3), today), 'Dec 3');
    expect(formatAbsoluteTaskDate(TaskDate(2026, 1, 1), today), 'Jan 1');
    expect(formatAbsoluteTaskDate(TaskDate(2027, 1, 2), today), 'Jan 2, 2027');
    expect(
      formatAbsoluteTaskDate(TaskDate(2025, 12, 31), today),
      'Dec 31, 2025',
    );
    expect(
      formatAbsoluteTaskDate(TaskDate(2028, 2, 29), today),
      'Feb 29, 2028',
    );
  });
}
