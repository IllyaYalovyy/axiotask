// Protects the basic TaskRow contract (T2.3): a body tap opens the detail, a
// checkbox tap toggles completion WITHOUT opening the detail
// (checkbox-toggles-not-selects), and a double-tap on the title starts an
// inline rename that commits the new title. Every assertion is on the rendered
// tree / the callback the user's gesture actually fires.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bounded pump — `pumpAndSettle` hangs on a focused TextField's blinking-cursor
/// animation, so we pump one frame past the double-tap window instead.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String title = 'buy milk',
    bool completed = false,
    String? due,
    required List<String> opened,
    required List<String> toggled,
    required List<String> renamed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskRow(
            title: title,
            completed: completed,
            due: due,
            onOpen: () => opened.add(title),
            onToggle: () => toggled.add(title),
            onRename: renamed.add,
          ),
        ),
      ),
    );
  }

  testWidgets('renders the title (and "Untitled" when blank)', (tester) async {
    await pumpRow(tester, title: '', opened: [], toggled: [], renamed: []);
    expect(find.text('Untitled'), findsOneWidget);
  });

  testWidgets('a body tap opens the detail', (tester) async {
    final opened = <String>[];
    await pumpRow(tester, opened: opened, toggled: [], renamed: []);
    await tester.tap(find.text('buy milk'));
    await settle(tester);
    expect(opened, ['buy milk']);
  });

  testWidgets('a checkbox tap toggles and does NOT open the detail', (
    tester,
  ) async {
    final opened = <String>[];
    final toggled = <String>[];
    await pumpRow(tester, opened: opened, toggled: toggled, renamed: []);
    await tester.tap(find.byType(Checkbox));
    await settle(tester);
    expect(toggled, ['buy milk']);
    expect(opened, isEmpty, reason: 'checkbox must not open the detail');
  });

  testWidgets('a completed task strikes through its title', (tester) async {
    await pumpRow(
      tester,
      completed: true,
      opened: [],
      toggled: [],
      renamed: [],
    );
    final text = tester.widget<Text>(find.text('buy milk'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('a due label renders when provided', (tester) async {
    await pumpRow(
      tester,
      due: 'tomorrow',
      opened: [],
      toggled: [],
      renamed: [],
    );
    expect(find.text('tomorrow'), findsOneWidget);
  });

  testWidgets('double-tap the title to rename inline; submit commits', (
    tester,
  ) async {
    final renamed = <String>[];
    await pumpRow(tester, opened: [], toggled: [], renamed: renamed);

    // Double-tap the title → inline editor.
    await tester.tap(find.text('buy milk'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('buy milk'));
    await settle(tester);

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'buy oat milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(renamed, ['buy oat milk']);
    // Editor closes after commit.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('an unchanged/empty inline title does not rename', (
    tester,
  ) async {
    final renamed = <String>[];
    await pumpRow(tester, opened: [], toggled: [], renamed: renamed);

    await tester.tap(find.text('buy milk'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('buy milk'));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // Empty ⇒ no rename here (the empty-⇒-delete path lands in T2.4).
    expect(renamed, isEmpty);
  });
}
