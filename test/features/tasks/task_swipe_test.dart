import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/domain/policy/date_workflow.dart';
import 'package:axiotask/src/features/tasks/widgets/task_swipe.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Records which row interaction fired, so each test can prove that exactly
/// one of them (or none) did.
final class _Log {
  final events = <String>[];
  void call(String event) => events.add(event);
}

void main() {
  group('TaskSwipeActions touch contract', () {
    testWidgets('a full right swipe completes and a left swipe schedules', (
      tester,
    ) async {
      final log = await _pumpRows(tester);

      await tester.drag(_row(1), const Offset(taskSwipeActionDistance, 0));
      await tester.pumpAndSettle();
      expect(log.events, <String>['complete 1']);

      await tester.drag(_row(2), const Offset(-taskSwipeActionDistance, 0));
      await tester.pumpAndSettle();
      expect(log.events, <String>['complete 1', 'schedule 2']);
    });

    testWidgets('short, flung-short and cancelled swipes do nothing', (
      tester,
    ) async {
      final log = await _pumpRows(tester);

      for (final dx in <double>[
        taskSwipeActionDistance - 1,
        -(taskSwipeActionDistance - 1),
      ]) {
        await tester.drag(_row(1), Offset(dx, 0));
        await tester.pumpAndSettle();
        await tester.fling(_row(1), Offset(dx / 2, 0), 4000);
        await tester.pumpAndSettle();
      }

      // Past the distance, then back again before release.
      final back = await tester.startGesture(tester.getCenter(_row(1)));
      await back.moveBy(const Offset(60, 0));
      await back.moveBy(const Offset(60, 0));
      await tester.pump();
      await back.moveBy(const Offset(-100, 0));
      await back.up();
      await tester.pumpAndSettle();

      // Past the distance, then cancelled by the system.
      final cancelled = await tester.startGesture(tester.getCenter(_row(1)));
      await cancelled.moveBy(const Offset(60, 0));
      await cancelled.moveBy(const Offset(60, 0));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();

      expect(log.events, isEmpty);
      expect(_offsetOf(tester, 1), Offset.zero, reason: 'the row settles');
    });

    testWidgets('vertical scrolling wins over the swipe and acts on nothing', (
      tester,
    ) async {
      final log = await _pumpRows(tester, count: 40);
      final list = tester.state<ScrollableState>(find.byType(Scrollable));

      await tester.drag(_row(2), const Offset(120, -300));
      await tester.pumpAndSettle();

      expect(list.position.pixels, greaterThan(0));
      expect(log.events, isEmpty);
    });

    testWidgets('a steep diagonal without a scrollable does not act', (
      tester,
    ) async {
      final log = await _pumpRows(tester, scrollable: false);

      await tester.drag(_row(1), const Offset(120, 160));
      await tester.pumpAndSettle();
      await tester.drag(_row(1), const Offset(-120, -160));
      await tester.pumpAndSettle();

      expect(log.events, isEmpty);
    });

    testWidgets('tap and long press keep their own meaning', (tester) async {
      final log = await _pumpRows(tester);

      await tester.tap(_row(1));
      await tester.pumpAndSettle();
      await tester.longPress(_row(2));
      await tester.pumpAndSettle();

      expect(log.events, <String>['tap 1', 'long press 2']);
    });

    testWidgets('a mouse drag reaches the pointer reorder handle instead', (
      tester,
    ) async {
      final log = await _pumpRows(tester, mouseDraggable: true);

      final mouse = await tester.startGesture(
        tester.getCenter(_row(1)),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(70, 0));
      await mouse.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(find.text('Dragging 1'), findsOneWidget);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.drag(
        _row(2),
        const Offset(-140, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(log.events, <String>['drag started 1', 'drag started 2']);

      // A touch swipe on the same row never starts the pointer drag.
      await tester.drag(_row(1), const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(log.events.last, 'complete 1');
      expect(log.events.where((e) => e.startsWith('drag')), hasLength(2));
    });

    testWidgets('disabled rows and missing actions ignore the swipe', (
      tester,
    ) async {
      final log = await _pumpRows(
        tester,
        enabled: (index) => index != 1,
        canComplete: (index) => index != 2,
      );

      await tester.drag(_row(1), const Offset(140, 0));
      await tester.drag(_row(1), const Offset(-140, 0));
      await tester.drag(_row(2), const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(log.events, isEmpty);
      expect(_offsetOf(tester, 2), Offset.zero);

      await tester.drag(_row(2), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(log.events, <String>['schedule 2']);
    });

    testWidgets('a row disabled mid-swipe does not act on release', (
      tester,
    ) async {
      final enabled = ValueNotifier<bool>(true);
      addTearDown(enabled.dispose);
      final log = _Log();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (context, value, _) => TaskSwipeActions(
                key: const Key('row-1'),
                enabled: value,
                onComplete: () => log('complete 1'),
                onSchedule: () => log('schedule 1'),
                child: const SizedBox(height: 56, child: Text('Row 1')),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(_row(1)));
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      enabled.value = false;
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(log.events, isEmpty);
    });
  });

  group('quick-date sheet', () {
    testWidgets('returns the chosen action and registers a date dialog', (
      tester,
    ) async {
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);
      final results = <QuickDateAction?>[];
      await tester.pumpWidget(
        AppNavigationScope(
          controller: navigation,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showQuickDateSheet(context, taskTitle: 'Synthetic'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      for (final action in QuickDateAction.values) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Schedule “Synthetic”'), findsOneWidget);
        expect(navigation.state.dialog, AppDialogKind.date);
        expect(
          find
              .descendant(
                of: find.byKey(const Key('quick-date-sheet')),
                matching: find.byType(ListTile),
              )
              .evaluate()
              .map(
                (element) => ((element.widget as ListTile).title! as Text).data,
              ),
          <String>[
            'Today',
            'Tomorrow',
            'Next week',
            'Next month',
            'Choose date',
            'Clear date',
          ],
        );
        await tester.tap(find.byKey(Key('quick-date-${action.name}')));
        await tester.pumpAndSettle();
        expect(navigation.state.dialog, isNull);
      }
      expect(results, QuickDateAction.values);
      expect(QuickDateAction.chooseDate.shortcut, isNull);
      expect(
        QuickDateAction.values.map((action) => action.shortcut).nonNulls,
        DateShortcut.values,
        reason: 'every shared date shortcut is offered once',
      );

      // Back and a tap outside both return no choice.
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(results.skip(QuickDateAction.values.length), <Object?>[
        null,
        null,
      ]);
      expect(navigation.state.dialog, isNull);
    });
  });
}

Finder _row(int index) => find.byKey(Key('row-$index'));

Offset _offsetOf(WidgetTester tester, int index) => tester
    .widget<Transform>(
      find.descendant(of: _row(index), matching: find.byType(Transform)).first,
    )
    .transform
    .getTranslation()
    .xy
    .let((value) => Offset(value.x, value.y));

extension<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}

Future<_Log> _pumpRows(
  WidgetTester tester, {
  int count = 3,
  bool scrollable = true,
  bool mouseDraggable = false,
  bool Function(int index)? enabled,
  bool Function(int index)? canComplete,
}) async {
  final log = _Log();
  Widget row(int index) {
    Widget content = SizedBox(height: 56, child: Text('Row $index'));
    if (mouseDraggable) {
      content = _MouseDraggable(
        data: index,
        feedback: Text('Dragging $index'),
        onDragStarted: () => log('drag started $index'),
        child: content,
      );
    }
    return GestureDetector(
      onLongPress: () => log('long press $index'),
      child: TaskSwipeActions(
        key: Key('row-$index'),
        enabled: enabled?.call(index) ?? true,
        onComplete: canComplete?.call(index) ?? true
            ? () => log('complete $index')
            : null,
        onSchedule: () => log('schedule $index'),
        child: InkWell(onTap: () => log('tap $index'), child: content),
      ),
    );
  }

  final rows = <Widget>[
    for (var index = 1; index <= count; index += 1) row(index),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: scrollable ? ListView(children: rows) : Column(children: rows),
      ),
    ),
  );
  return log;
}

/// The shell's pointer-only drag-and-drop source, reduced to its recognizer.
final class _MouseDraggable extends Draggable<int> {
  const _MouseDraggable({
    required super.data,
    required super.feedback,
    required super.child,
    super.onDragStarted,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => ImmediateMultiDragGestureRecognizer(
    supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
  )..onStart = onStart;
}
