import 'package:axiotask/src/app/desktop_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text editing suppresses commands while F1 remains discoverable', () {
    for (final key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
    ]) {
      expect(
        resolveDesktopShortcut(
          event: KeyDownEvent(
            logicalKey: key,
            physicalKey: PhysicalKeyboardKey.keyA,
            timeStamp: Duration.zero,
          ),
          controlPressed: false,
          shiftPressed: false,
          altPressed: false,
          editingText: true,
          hasTask: true,
        ),
        isNull,
      );
    }
    expect(
      resolveDesktopShortcut(
        event: const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.f1,
          physicalKey: PhysicalKeyboardKey.f1,
          timeStamp: Duration.zero,
        ),
        controlPressed: false,
        shiftPressed: false,
        altPressed: false,
        editingText: true,
        hasTask: true,
      ),
      DesktopShortcutAction.showReference,
    );
  });

  test('task accelerators require a focused or selected task', () {
    DesktopShortcutAction? resolve(
      LogicalKeyboardKey key, {
      bool hasTask = true,
    }) => resolveDesktopShortcut(
      event: KeyDownEvent(
        logicalKey: key,
        physicalKey: PhysicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
      controlPressed: false,
      shiftPressed: false,
      altPressed: false,
      editingText: false,
      hasTask: hasTask,
    );

    expect(resolve(LogicalKeyboardKey.enter), DesktopShortcutAction.openTask);
    expect(
      resolve(LogicalKeyboardKey.space),
      DesktopShortcutAction.toggleCompletion,
    );
    expect(resolve(LogicalKeyboardKey.keyE), DesktopShortcutAction.editTask);
    expect(resolve(LogicalKeyboardKey.keyD), DesktopShortcutAction.chooseDate);
    expect(resolve(LogicalKeyboardKey.keyM), DesktopShortcutAction.moveTask);
    expect(
      resolve(LogicalKeyboardKey.delete),
      DesktopShortcutAction.deleteTask,
    );
    expect(resolve(LogicalKeyboardKey.keyE, hasTask: false), isNull);
  });

  test('every shortcut has one non-empty discoverable description', () {
    expect(desktopShortcutReference, isNotEmpty);
    expect(
      desktopShortcutReference.map((shortcut) => shortcut.keys).toSet(),
      hasLength(desktopShortcutReference.length),
    );
    expect(
      desktopShortcutReference.every(
        (shortcut) =>
            shortcut.keys.isNotEmpty && shortcut.description.isNotEmpty,
      ),
      isTrue,
    );
  });
}
