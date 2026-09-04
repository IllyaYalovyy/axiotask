// QuickAddPasteSplit suite (#219) — pasting a LIST into the quick-add field.
//
// The BulkAdd split already existed behind a toolbar icon (T7.6); the natural
// gesture is pasting a multi-line clipboard straight into the composer. These
// tests pin the ratified behaviour:
//
//   • a multi-line paste collapses to ONE readable draft line and offers
//     "Add as N tasks" beside the field;
//   • accepting routes into the SAME per-line split BulkAdd commits — one task
//     per non-blank line, each line's trailing natural-language date parsed;
//   • declining creates nothing and leaves the collapsed text as a normal
//     draft that still submits as a single task;
//   • a single-line paste, or a paste spliced into an existing draft, never
//     offers the split;
//   • the offer reaches the phone through the long-press Paste toolbar inside
//     the bottom-sheet composer, and keeps that composer to ONE line.
//
// Everything runs over the in-memory [FakeCommands] with a MOCKED CLIPBOARD, so
// the assertions are about what the user sees (the chip, the draft text, the
// toast) and what the backend HOLDS (titles and dues) — never that a callback
// fired.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composed_list.dart';
import 'detail_harness.dart' show FakeCommands, list;
import 'toast_harness.dart' show wrapWithToast;

/// Fixed clock — "tomorrow" on a pasted line must not read the wall clock.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

const _offerKey = Key('quick-add-paste-split');
const _dismissKey = Key('quick-add-paste-split-dismiss');
const _barKey = Key('quick-add-bar');

final _twoLists = [list('L1', 'My Tasks'), list('L2', 'Work')];

void main() {
  /// Bounded pump — pumpAndSettle hangs on a focused TextField's cursor timer.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Put [text] on the (mocked) system clipboard for the rest of the test.
  void setClipboard(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => <String, dynamic>{'text': text},
        'Clipboard.hasStrings' => <String, dynamic>{'value': text.isNotEmpty},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<FakeCommands> pumpQuickAdd(
    WidgetTester tester, {
    List<StoredTaskList> lists = const [],
    String viewId = 'all',
    TargetPlatform platform = TargetPlatform.linux,
    Size size = const Size(1200, 900),
    double textScale = 1.0,
  }) async {
    var seq = 0;
    final fake = FakeCommands(const [], newId: () => 'gen-${seq++}');
    addTearDown(fake.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await withClock(_clock, () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(const Prefs()),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            listsProvider.overrideWith((ref) => Stream.value(lists)),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: wrapWithToast(context, child),
            ),
            home: Scaffold(
              body: composedList(viewId: viewId, onOpenTask: (_) {}),
            ),
          ),
        ),
      );
      await settle(tester);
    });
    return fake;
  }

  /// Open the FAB's bottom-sheet composer (#216) — the touch creation surface.
  Future<void> openComposer(WidgetTester tester) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TaskListView)),
      listen: false,
    );
    container.read(newTaskRequestProvider.notifier).bump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Paste into the composer the way a desktop user does: caret in the field,
  /// Ctrl+V.
  Future<void> pasteWithKeyboard(
    WidgetTester tester, {
    bool focusFirst = true,
  }) async {
    await withClock(_clock, () async {
      if (focusFirst) {
        await tester.tap(find.byKey(_barKey).hitTestable());
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    });
  }

  /// Paste the way a phone user does: long-press the field, tap Paste on the
  /// selection toolbar.
  Future<void> pasteWithToolbar(WidgetTester tester) async {
    await withClock(_clock, () async {
      await tester.longPress(find.byType(TextField).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Paste'));
      await settle(tester);
    });
  }

  /// Accept the offer.
  Future<void> acceptOffer(WidgetTester tester) async {
    await withClock(_clock, () async {
      await tester.tap(find.byKey(_offerKey));
      await settle(tester);
    });
  }

  /// The text currently in the composer's input.
  String draft(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  /// The stored task with [title] — the fake is the source of truth for what
  /// the create actually persisted.
  StoredTask stored(FakeCommands fake, String title) =>
      fake.tasks.firstWhere((t) => t.task.title == title);

  testWidgets('a multi-line paste collapses to one draft line and offers '
      '"Add as 3 tasks"', (tester) async {
    // The failure this prevents: a single-line field DELETES the newlines on
    // paste ("buy milkcall bob"), and the three tasks the user actually copied
    // are silently lost inside one mangled title.
    await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk\ncall bob\npay rent');
    await pasteWithKeyboard(tester);

    expect(find.text('Add as 3 tasks'), findsOneWidget);
    expect(draft(tester), 'buy milk call bob pay rent');
  });

  testWidgets('accepting creates one task per line, with each line\'s date '
      'parsed', (tester) async {
    // The core contract: the offer routes into the EXISTING BulkAdd per-line
    // split — blank lines create nothing, titles stay verbatim, and a trailing
    // natural-language date on a line becomes that task's due.
    final fake = await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk\ncall bob tomorrow\n\npay rent 2026-07-01');
    await pasteWithKeyboard(tester);

    expect(find.text('Add as 3 tasks'), findsOneWidget);
    await acceptOffer(tester);

    expect(fake.tasks.length, 3, reason: 'the blank line created nothing');
    expect(stored(fake, 'buy milk').task.due, isNull);
    expect(
      stored(fake, 'call bob tomorrow').task.due,
      '2026-06-16T00:00:00.000Z',
    );
    expect(
      stored(fake, 'pay rent 2026-07-01').task.due,
      '2026-07-01T00:00:00.000Z',
    );
    expect(draft(tester), '', reason: 'the consumed draft is cleared');
    expect(find.byKey(_offerKey), findsNothing);
    expect(find.text('Added 3 tasks'), findsOneWidget);
  });

  testWidgets('the tasks land in the composer\'s picked list (#217)', (
    tester,
  ) async {
    // Non-happy path: the user aimed the composer at another list before
    // pasting. The bulk split must honour that aim, not the view default.
    final fake = await pumpQuickAdd(tester, lists: _twoLists, viewId: 'all');
    await tester.tap(find.byKey(const Key('quick-add-list-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('quick-add-list-L2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    setClipboard(tester, 'buy milk\ncall bob');
    await pasteWithKeyboard(tester);
    await acceptOffer(tester);

    expect(fake.tasks.map((t) => t.listId).toSet(), {'L2'});
  });

  testWidgets('declining creates nothing and keeps the collapsed draft', (
    tester,
  ) async {
    // Declining is not a cancel-everything: the pasted text stays as an
    // ordinary single-task draft the user can still edit and submit.
    final fake = await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk\ncall bob');
    await pasteWithKeyboard(tester);

    await tester.tap(find.byKey(_dismissKey));
    await settle(tester);

    expect(find.byKey(_offerKey), findsNothing);
    expect(fake.tasks, isEmpty);
    expect(draft(tester), 'buy milk call bob');

    // …and it is a NORMAL draft: submitting makes exactly one task.
    await withClock(_clock, () async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
    });
    expect(fake.tasks.length, 1);
    expect(fake.tasks.single.task.title, 'buy milk call bob');
  });

  testWidgets('a single-line paste never offers the split', (tester) async {
    // Non-happy path: the everyday paste must stay invisible — no chip, no
    // rewriting of what was copied.
    final fake = await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk');
    await pasteWithKeyboard(tester);

    expect(find.byKey(_offerKey), findsNothing);
    expect(draft(tester), 'buy milk');
    expect(fake.tasks, isEmpty);
  });

  testWidgets('a paste spliced into an existing draft never offers the split', (
    tester,
  ) async {
    // Non-happy path: with text already typed, the pasted lines are not a
    // standalone list — offering "Add as N tasks" would silently drop the
    // typed prefix. The lines still collapse readably.
    await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'call bob\npay rent');
    await withClock(_clock, () async {
      await tester.enterText(find.byType(TextField), 'today: ');
      await tester.pump();
    });
    await pasteWithKeyboard(tester);

    expect(find.byKey(_offerKey), findsNothing);
    expect(draft(tester), 'today: call bob pay rent');
  });

  testWidgets('pasting OVER the whole draft still offers the split', (
    tester,
  ) async {
    // Select-all + paste leaves nothing of the old draft, so the field holds a
    // pasted list exactly as an empty composer would.
    await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk\ncall bob');
    await withClock(_clock, () async {
      await tester.enterText(find.byType(TextField), 'scratch');
      await tester.pump();
    });
    final controller = tester
        .widget<EditableText>(find.byType(EditableText))
        .controller;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await tester.pump();
    // No re-tap: a tap would collapse the select-all this test depends on.
    await pasteWithKeyboard(tester, focusFirst: false);

    expect(find.text('Add as 2 tasks'), findsOneWidget);
    expect(draft(tester), 'buy milk call bob');
  });

  testWidgets('editing the draft retracts the offer', (tester) async {
    // Once the text is no longer the pasted list, "Add as 2 tasks" would be a
    // lie about what accepting creates.
    await pumpQuickAdd(tester, lists: _twoLists);
    setClipboard(tester, 'buy milk\ncall bob');
    await pasteWithKeyboard(tester);
    expect(find.byKey(_offerKey), findsOneWidget);

    await withClock(_clock, () async {
      await tester.enterText(find.byType(TextField), 'buy milk call bob!');
      await tester.pump();
    });
    expect(find.byKey(_offerKey), findsNothing);
  });

  group('phone bottom-sheet composer', () {
    const phone = Size(400, 800);

    testWidgets('the long-press Paste toolbar offers the split, and accepting '
        'creates the tasks', (tester) async {
      // The primary mobile paste path has no Ctrl+V: it goes through the
      // selection toolbar inside the FAB's sheet composer.
      final fake = await pumpQuickAdd(
        tester,
        lists: _twoLists,
        platform: TargetPlatform.android,
        size: phone,
      );
      await openComposer(tester);
      setClipboard(tester, 'buy milk\ncall bob');
      await pasteWithToolbar(tester);

      expect(find.text('Add as 2 tasks'), findsOneWidget);
      expect(draft(tester), 'buy milk call bob');

      await acceptOffer(tester);
      expect(fake.tasks.map((t) => t.task.title).toList(), [
        'buy milk',
        'call bob',
      ]);
    });

    testWidgets('at text scale 2.0 the offer ellipsises instead of overflowing '
        'the phone row', (tester) async {
      // An uncapped label at an accessibility text scale overran the 400dp row
      // once the date chip and picker joined it (#217) — the offer must not
      // repeat that: it truncates, the row stays one line, and both answers
      // stay reachable.
      await pumpQuickAdd(
        tester,
        lists: _twoLists,
        platform: TargetPlatform.android,
        size: phone,
        textScale: 2.0,
      );
      await openComposer(tester);
      final before = tester.getSize(find.byKey(_barKey)).height;

      setClipboard(tester, 'buy milk\ncall bob\npay rent');
      await pasteWithToolbar(tester);

      expect(find.byKey(_offerKey), findsOneWidget);
      expect(find.byKey(_dismissKey), findsOneWidget);
      expect(tester.getSize(find.byKey(_barKey)).height, before);
      expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    });

    testWidgets('the offer keeps the composer to ONE line with finger-sized '
        'targets', (tester) async {
      // The hard mobile constraint (#217): the composer never grows a second
      // line, and both answers to the offer are ≥48dp.
      await pumpQuickAdd(
        tester,
        lists: _twoLists,
        platform: TargetPlatform.android,
        size: phone,
      );
      await openComposer(tester);
      final before = tester.getSize(find.byKey(_barKey)).height;

      setClipboard(tester, 'buy milk\ncall bob\npay rent');
      await pasteWithToolbar(tester);

      expect(
        tester.getSize(find.byKey(_barKey)).height,
        before,
        reason: 'the offer must live on the composer\'s single line',
      );
      for (final target in [_offerKey, _dismissKey]) {
        final size = tester.getSize(find.byKey(target));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$target');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$target');
      }
      // The destination picker and the send button keep their slots — the
      // offer stands in for the DATE chip, so the row holds exactly what it
      // already holds with a date parsed, and the draft stays visible. (The
      // test font renders ~1em per character, roughly double production, so
      // the input measures far narrower here than on a real phone; the floor
      // matches the #217 scale test rather than a production width.)
      expect(find.byKey(const Key('quick-add-list-picker')), findsOneWidget);
      expect(
        find.widgetWithIcon(IconButton, Icons.arrow_upward),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(EditableText)).width,
        greaterThan(24),
        reason: 'the collapsed draft must stay visible behind the offer',
      );
      expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    });
  });

  testWidgets('a paste split leaves the composer\'s date aim standing — the '
      'next single add still gets it (#264)', (tester) async {
    // The chip describes the NEXT add, not the last one: a burst of adds
    // interrupted by a pasted list must not silently lose the date the user
    // set for the burst.
    final fake = await pumpQuickAdd(tester, lists: [list('L1', 'My Tasks')]);
    await withClock(_clock, () async {
      await tester.tap(find.byKey(const Key('quick-add-date-button')));
      await settle(tester);
      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await settle(tester);
    });

    setClipboard(tester, 'buy milk\ncall bob');
    await pasteWithKeyboard(tester);
    await acceptOffer(tester);

    // The split's lines carry their OWN dates and neither had one, so the aim
    // was not spent on them...
    expect(stored(fake, 'buy milk').task.due, isNull);
    expect(stored(fake, 'call bob').task.due, isNull);
    // ...and it is still on the composer, for the next thing typed into it.
    expect(
      find.descendant(of: find.byKey(_barKey), matching: find.text('tomorrow')),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'pay rent');
    await settle(tester);
    await withClock(_clock, () async {
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await settle(tester);
    });
    expect(stored(fake, 'pay rent').task.due, '2026-06-16T00:00:00.000Z');
  });
}
