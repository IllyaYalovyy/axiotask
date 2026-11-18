import '../model/tasks.dart';

const _months = <String>[
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

/// [date] as an absolute calendar day, "Dec 3", with the year appended when
/// it is not [today]'s ("Jan 2, 2027"). Task rows and view exports share it,
/// so one due date never reads two ways.
String formatAbsoluteTaskDate(TaskDate date, TaskDate today) {
  final label = '${_months[date.month - 1]} ${date.day}';
  return date.year == today.year ? label : '$label, ${date.year}';
}
