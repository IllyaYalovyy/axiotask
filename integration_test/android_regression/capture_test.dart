// Capture-composer subset of the Android behavior manifest (manifest.json).
//
// Cases 08 (notes during capture) and 20 (phone add button and composer)
// failed the 2026-11-15 native audit of v1.5.6: phones showed a desktop-style
// capture bar at the top, with no floating add button and no notes. These
// contracts drive the real shell over the isolated SQLite fixture by touch:
// the floating add button opens and focuses the on-demand top composer,
// Back lowers the keyboard and then closes it, Cancel creates nothing, and
// title plus multiline notes persist in the selected list. Controls are
// measured above a keyboard at phone widths, in both orientations and at 2x
// text. Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

final _addButton = find.byKey(const Key('phone-add-task'));
final _composer = find.byKey(const Key('composer-surface'));
final _title = find.byKey(const Key('quick-add-input'));
final _notes = find.byKey(const Key('quick-add-notes'));
final _submit = find.byKey(const Key('quick-add-submit'));
final _cancel = find.byKey(const Key('composer-cancel'));

/// Every phone shape the composer must stay usable at.
final _composerViewports = <PhoneViewport>[
  for (final shortSide in <double>[360, 443])
    for (final orientation in PhoneOrientation.values)
      for (final textScale in <double>[1, 2])
        PhoneViewport(shortSide, orientation, textScale),
];

void main() {
  ensureRegressionBinding();

  regressionCase('20_phone_add_affordance', phoneOnHost: true, (t, f) async {
    final before = await _taskIds(f);
    await f.capture(t, 'home');
    expect(_title, findsNothing, reason: 'No always-visible capture bar');
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expectTouchTarget(t, _addButton, label: 'New task');
    final button = t.getRect(_addButton);
    final screen = Offset.zero & t.view.physicalSize / t.view.devicePixelRatio;
    // Floating within the screen, in the thumb's bottom-right quarter.
    expect(screen.contains(button.topLeft), isTrue);
    expect(button.bottom, lessThanOrEqualTo(screen.height));
    expect(button.center.dy, greaterThan(screen.height / 2), reason: 'Thumb');
    expect(button.center.dx, greaterThan(screen.width / 2), reason: 'Thumb');

    await _openComposer(t);
    await f.capture(t, 'composer');

    // Back first lowers a raised keyboard, keeping the composer and its
    // draft; the next Back closes the composer. Nothing is created.
    await t.enterText(_title, 'Draft closed by Back');
    await t.pump();
    await _raiseKeyboard(t);
    await f.capture(t, 'composer_keyboard');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_composer, findsOneWidget, reason: 'Back lowered the keyboard');
    expect(_focused(t, _title), isFalse);
    await _lowerKeyboard(t);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_composer, findsNothing, reason: 'Second Back closed it');
    expect(_addButton.hitTestable(), findsOneWidget);
    expect(await _taskIds(f), before, reason: 'Back created nothing');

    // Back kept the draft; Cancel discards it and creates nothing.
    await _openComposer(t);
    expect(_text(t, _title), 'Draft closed by Back');
    await t.enterText(_notes, 'Cancelled notes');
    await t.tap(_cancel);
    await t.pumpAndSettle();
    expect(_composer, findsNothing);
    expect(await _taskIds(f), before, reason: 'Cancel created nothing');
    await _openComposer(t);
    expect(_text(t, _title), isEmpty);
    expect(_text(t, _notes), isEmpty);
    await t.tap(_cancel);
    await t.pumpAndSettle();

    // Cancel and submit stay whole, on screen and above the keyboard at
    // every phone shape; the closed add button never covers a row control.
    for (final viewport in _composerViewports) {
      await usePhoneViewport(t, viewport);
      expect(t.takeException(), isNull, reason: '$viewport home layout');
      expectTouchTarget(t, _addButton, label: 'New task');
      await _openComposer(t);
      final keyboardTop = await _raiseKeyboard(t);
      expect(t.takeException(), isNull, reason: '$viewport composer layout');
      for (final (control, label) in <(Finder, String)>[
        (_cancel, 'Cancel'),
        (_submit, 'Save'),
      ]) {
        final rect = t.getRect(control);
        expect(rect.top, greaterThanOrEqualTo(0), reason: '$viewport $label');
        expect(
          rect.bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: '$viewport $label stays above the keyboard',
        );
        expectTouchTarget(t, control, label: label);
      }
      expect(t.getRect(_title).bottom, lessThanOrEqualTo(keyboardTop));
      await f.capture(t, 'composer_keyboard_${viewport.name}');
      await _lowerKeyboard(t);
      await t.tap(_cancel);
      await t.pumpAndSettle();
    }
    expect(await _taskIds(f), before);
  });

  regressionCase('08_capture_notes', phoneOnHost: true, (t, f) async {
    // Capture into the destination list to prove the selected list is used.
    f.model.selectTaskList(f.destination);
    await t.pumpAndSettle();
    final before = await _taskIds(f);
    await _openComposer(t);

    // An empty title is rejected; the notes stay for the retry.
    await t.enterText(_notes, 'First line\nSecond line');
    await t.tap(_submit);
    await t.pumpAndSettle();
    expect(find.text('Enter a task title.'), findsOneWidget);
    expect(_text(t, _notes), 'First line\nSecond line');
    expect(await _taskIds(f), before, reason: 'Empty title created nothing');

    // Keyboard submit stores title and multiline notes together.
    await t.enterText(_title, 'Captured with notes');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.done);
    final first = await _awaitCreated(t, f, before, 'Captured with notes');
    expect(first.notes, 'First line\nSecond line');
    expect(first.taskListId, f.destination);
    expect(first.parentTaskId, isNull);
    await f.capture(t, 'after_first');
    expect(_composer, findsNothing, reason: 'Save returns to the collection');
    await _lowerKeyboard(t);
    await _openComposer(t);
    expect(_text(t, _title), isEmpty);
    expect(_text(t, _notes), isEmpty);
    expect(_focused(t, _title), isTrue, reason: 'Ready for the next title');

    // A fresh capture after rotating to landscape at 2x text.
    await usePhoneViewport(
      t,
      const PhoneViewport(360, PhoneOrientation.landscape, 2),
    );
    await t.enterText(_title, 'Captured in landscape');
    await t.enterText(_notes, 'Landscape notes');
    await usePhoneViewport(
      t,
      const PhoneViewport(360, PhoneOrientation.portrait, 2),
    );
    expect(_text(t, _title), 'Captured in landscape', reason: 'Rotation');
    expect(_text(t, _notes), 'Landscape notes', reason: 'Rotation');
    await _raiseKeyboard(t);
    await f.capture(t, 'second_draft_2x');
    final afterFirst = await _taskIds(f);
    await t.tap(_submit);
    // A second tap while saving must not create a duplicate.
    await t.tap(_submit, warnIfMissed: false);
    final second = await _awaitCreated(
      t,
      f,
      afterFirst,
      'Captured in landscape',
    );
    expect(second.notes, 'Landscape notes');
    expect(second.taskListId, f.destination);
    await t.pumpAndSettle();
    final created = (await f.tasks())
        .where((task) => !before.contains(task.id))
        .toList();
    expect(
      created.map((task) => task.title),
      unorderedEquals(<String>['Captured with notes', 'Captured in landscape']),
      reason: 'Exactly two tasks, no duplicates',
    );
    expect(created.map((task) => task.id).toSet(), hasLength(2));
    await _lowerKeyboard(t);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_composer, findsNothing);
    expect(find.text('Captured with notes').hitTestable(), findsOneWidget);
  });
}

Future<void> _openComposer(WidgetTester t) async {
  expect(_addButton.hitTestable(), findsOneWidget);
  await t.tap(_addButton);
  await t.pumpAndSettle();
  expect(_composer, findsOneWidget);
  expect(_focused(t, _title), isTrue, reason: 'The title takes focus');
  expect(_addButton, findsNothing, reason: 'The button yields to it');
}

/// Simulates a soft keyboard over the bottom of the view (about 40% in
/// portrait, half in landscape). As on Android, it covers the navigation
/// bar, so the bottom system padding becomes zero. Returns the keyboard's
/// top edge in logical pixels.
Future<double> _raiseKeyboard(WidgetTester t) async {
  final size = t.view.physicalSize;
  final share = size.width > size.height ? 0.5 : 0.4;
  final padding = t.view.padding;
  t.view
    ..viewInsets = FakeViewPadding(bottom: size.height * share)
    ..padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
    );
  await t.pumpAndSettle();
  return size.height * (1 - share) / t.view.devicePixelRatio;
}

Future<void> _lowerKeyboard(WidgetTester t) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  t.view
    ..resetViewInsets()
    ..resetPadding();
  await settleUntil(
    t,
    () => t.view.viewInsets.bottom == 0,
    description: 'native keyboard hidden',
  );
}

bool _focused(WidgetTester t, Finder field) => t
    .widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

String _text(WidgetTester t, Finder field) => t
    .widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    )
    .controller
    .text;

Future<Set<TaskId>> _taskIds(RegressionFixture f) async =>
    (await f.tasks()).map((task) => task.id).toSet();

/// Waits until exactly one task beyond [before] is stored in SQLite.
Future<CachedTask> _awaitCreated(
  WidgetTester t,
  RegressionFixture f,
  Set<TaskId> before,
  String title,
) async {
  await settleUntil(
    t,
    () async => (await f.tasks()).any((task) => task.title == title),
    description: '"$title" to persist in SQLite',
  );
  final created = (await f.tasks())
      .where((task) => !before.contains(task.id))
      .toList();
  expect(created, hasLength(1), reason: 'Exactly one new task for "$title"');
  expect(created.single.title, title);
  return created.single;
}
