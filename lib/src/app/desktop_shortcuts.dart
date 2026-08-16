import 'package:flutter/services.dart';

enum DesktopShortcutAction {
  showReference,
  search,
  quickAdd,
  bulkCapture,
  focusNavigation,
  focusTasks,
  focusDetails,
  back,
  openTask,
  toggleCompletion,
  editTask,
  chooseDate,
  moveTask,
  deleteTask,
}

enum DesktopTaskAction {
  open,
  toggleCompletion,
  edit,
  chooseDate,
  moveToList,
  delete,
}

typedef DesktopShortcutReference = ({
  String keys,
  String description,
  bool taskOnly,
});

const List<DesktopShortcutReference> desktopShortcutReference =
    <DesktopShortcutReference>[
      (keys: 'Ctrl+N', description: 'Focus quick add', taskOnly: false),
      (keys: 'Ctrl+F', description: 'Search tasks', taskOnly: false),
      (
        keys: 'Ctrl+Shift+V',
        description: 'Paste multiple tasks',
        taskOnly: false,
      ),
      (keys: 'Ctrl+1', description: 'Focus navigation', taskOnly: false),
      (keys: 'Ctrl+2', description: 'Focus task collection', taskOnly: false),
      (keys: 'Ctrl+3', description: 'Focus task details', taskOnly: false),
      (keys: '↑ / ↓', description: 'Move task focus', taskOnly: true),
      (keys: 'Enter', description: 'Open focused task', taskOnly: true),
      (keys: 'Space', description: 'Complete or reopen task', taskOnly: true),
      (keys: 'E', description: 'Edit task', taskOnly: true),
      (keys: 'D', description: 'Choose due date', taskOnly: true),
      (keys: 'M', description: 'Move task to a Google list', taskOnly: true),
      (keys: 'Delete', description: 'Delete task with Undo', taskOnly: true),
      (keys: 'Esc', description: 'Close the current surface', taskOnly: false),
      (keys: 'F1', description: 'Show keyboard shortcuts', taskOnly: false),
    ];

DesktopShortcutAction? resolveDesktopShortcut({
  required KeyEvent event,
  required bool controlPressed,
  required bool shiftPressed,
  required bool altPressed,
  required bool editingText,
  required bool hasTask,
}) {
  if (event is! KeyDownEvent || altPressed) return null;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.f1) {
    return DesktopShortcutAction.showReference;
  }
  if (editingText) return null;
  if (controlPressed) {
    if (key == LogicalKeyboardKey.keyF && !shiftPressed) {
      return DesktopShortcutAction.search;
    }
    if (key == LogicalKeyboardKey.keyN && !shiftPressed) {
      return DesktopShortcutAction.quickAdd;
    }
    if (key == LogicalKeyboardKey.keyV && shiftPressed) {
      return DesktopShortcutAction.bulkCapture;
    }
    if (!shiftPressed && key == LogicalKeyboardKey.digit1) {
      return DesktopShortcutAction.focusNavigation;
    }
    if (!shiftPressed && key == LogicalKeyboardKey.digit2) {
      return DesktopShortcutAction.focusTasks;
    }
    if (!shiftPressed && key == LogicalKeyboardKey.digit3) {
      return DesktopShortcutAction.focusDetails;
    }
    return null;
  }
  if (shiftPressed) return null;
  if (key == LogicalKeyboardKey.escape) return DesktopShortcutAction.back;
  if (!hasTask) return null;
  if (key == LogicalKeyboardKey.enter) return DesktopShortcutAction.openTask;
  if (key == LogicalKeyboardKey.space) {
    return DesktopShortcutAction.toggleCompletion;
  }
  if (key == LogicalKeyboardKey.keyE) return DesktopShortcutAction.editTask;
  if (key == LogicalKeyboardKey.keyD) return DesktopShortcutAction.chooseDate;
  if (key == LogicalKeyboardKey.keyM) return DesktopShortcutAction.moveTask;
  if (key == LogicalKeyboardKey.delete) return DesktopShortcutAction.deleteTask;
  return null;
}
