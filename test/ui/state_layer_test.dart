// #259 — the interaction-state pass. What a surface says while a pointer or the
// keyboard is ON it, asserted as PAINT: the M3 hover wash, the press state
// layer under a bounded ripple, and the 2dp focus ring.
//
// Every assertion here asks the tree "did anything actually paint this?" rather
// than "is a widget configured with it" — a state layer that is built but never
// reaches the canvas (an Opacity at zero, an ink feature on a Material that the
// row's own opaque wash paints over) is exactly the regression this file
// exists to catch.
//
// The size assertions are inside the state assertions on purpose: the ux rule
// is "no reflow on hover/focus/press", and a test that only measured the size
// would pass just as well on a surface with no state layers at all.

import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/state_layer.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two state-layer colours are "the same" when every channel agrees to within
/// one 255th. Exact equality is the wrong question twice over: an ink feature
/// paints `color.withAlpha(color.alpha)`, which round-trips a fractional
/// opacity (0.08) through an 8-bit channel (20/255), and a `Paint`'s colour
/// round-trips through float32 on the way to the canvas. Nothing else this app
/// paints is within a 255th of a state layer, so the tolerance cannot make a
/// false match.
bool _sameLayer(Color a, Color b) =>
    (a.r - b.r).abs() < _channelSlack &&
    (a.g - b.g).abs() < _channelSlack &&
    (a.b - b.b).abs() < _channelSlack &&
    (a.a - b.a).abs() < _channelSlack;

const double _channelSlack = 1 / 255 + 0.0001;

/// Every canvas call the tree actually makes this frame.
///
/// Recorded by painting the ROOT once, not each render object in turn: a state
/// layer is painted by an ink surface that sits nowhere near the widget that
/// owns it, and — more importantly — a ring inside a zero-opacity parent must
/// come out of this list EMPTY. Painting render objects individually would
/// paint straight past the parent that is hiding them, and the test would pass
/// on a ring the user cannot see.
List<Invocation> treeCalls(WidgetTester tester) {
  final recording = TestRecordingCanvas();
  tester.allRenderObjects.first.paint(
    TestRecordingPaintingContext(recording),
    Offset.zero,
  );
  return recording.invocations.map((c) => c.invocation).toList();
}

Iterable<Paint> _paintsOf(Invocation call) =>
    call.positionalArguments.whereType<Paint>();

/// Whether the tree paints a filled area in [color] (a state layer / wash).
bool paintsWash(WidgetTester tester, Color color) => treeCalls(tester).any(
  (c) => _paintsOf(
    c,
  ).any((p) => p.style == PaintingStyle.fill && _sameLayer(p.color, color)),
);

/// Whether the tree paints a [width]-thick outline in [color] — the focus ring.
///
/// A `BoxDecoration` border draws a rounded ring as a `drawDRRect` (a filled
/// ring between two rounded rects) and a square one as a stroked rect, so the
/// ring's thickness has to be read out of the shape in the first case rather
/// than off the `Paint`.
bool paintsRing(WidgetTester tester, Color color, {double width = 2}) =>
    treeCalls(tester).any((call) {
      if (!_paintsOf(call).any((p) => _sameLayer(p.color, color))) return false;
      if (call.memberName == #drawDRRect) {
        final outer = call.positionalArguments[0] as RRect;
        final inner = call.positionalArguments[1] as RRect;
        return (inner.left - outer.left - width).abs() < 0.01;
      }
      return _paintsOf(
        call,
      ).any((p) => p.style == PaintingStyle.stroke && p.strokeWidth == width);
    });

/// Whether the tree paints a spreading ink SPLASH — the circle `InkRipple`
/// draws, and the one thing reduced motion must not produce.
bool paintsSplashCircle(WidgetTester tester) =>
    treeCalls(tester).any((c) => c.memberName == #drawCircle);

/// Pump past every state-layer fade.
///
/// Three frames, not one: an ink feature is created while the pointer event is
/// being dispatched, its fade controller only starts ticking on the NEXT frame,
/// and the longest fade is the framework's 200ms pressed highlight. A single
/// timed pump samples the layer at alpha 0 and reads as "no state layer" —
/// which is exactly the false green this helper exists to prevent.
Future<void> settleStates(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 250));
}

const _title = 'buy milk';

/// The M3 state-layer colours the app is asserted to use, derived from the
/// scheme rather than restated as literals.
Color hoverWash(ColorScheme s) => s.onSurface.withValues(alpha: 0.08);
Color pressWash(ColorScheme s) => s.onSurface.withValues(alpha: 0.10);

void main() {
  final light = buildLightTheme();

  Future<void> pumpRow(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.linux,
    bool disableAnimations = false,
    List<String>? opened,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: light.copyWith(platform: platform),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: TaskRow(
              title: _title,
              completed: false,
              onOpen: () => opened?.add(_title),
              onToggle: () {},
              onRename: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(target));
    await settleStates(tester);
    return mouse;
  }

  group('task row', () {
    testWidgets('a mouse resting on the row paints the M3 hover wash, and the '
        'row does not change size', (tester) async {
      await pumpRow(tester);
      final rest = tester.getSize(find.byType(TaskRow));
      expect(
        paintsWash(tester, hoverWash(light.colorScheme)),
        isFalse,
        reason: 'nothing is hovered yet',
      );

      final mouse = await hover(tester, find.text(_title));

      expect(
        paintsWash(tester, hoverWash(light.colorScheme)),
        isTrue,
        reason: 'a hovered row must wash — onSurface at 8%',
      );
      expect(tester.getSize(find.byType(TaskRow)), rest);

      // And it leaves with the pointer: a wash that latched would mark a row
      // the mouse is no longer on.
      await mouse.moveTo(Offset.zero);
      await settleStates(tester);
      expect(paintsWash(tester, hoverWash(light.colorScheme)), isFalse);
      expect(tester.getSize(find.byType(TaskRow)), rest);
    });

    testWidgets('a finger held on the row paints the press state layer under a '
        'bounded ripple, and the row does not change size', (tester) async {
      await pumpRow(tester, platform: TargetPlatform.android);
      final rest = tester.getSize(find.byType(TaskRow));

      final finger = await tester.startGesture(
        tester.getCenter(find.text(_title)),
      );
      await settleStates(tester);

      expect(
        find.byType(InkWell),
        findsWidgets,
        reason: 'the row body is an ink surface',
      );
      expect(
        paintsWash(tester, pressWash(light.colorScheme)),
        isTrue,
        reason: 'a pressed row must wash — onSurface at 10%',
      );
      expect(tester.getSize(find.byType(TaskRow)), rest);

      await finger.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(find.byType(TaskRow)), rest);
    });

    testWidgets('keyboard focus paints a 2dp primary ring, and the row does '
        'not change size', (tester) async {
      await pumpRow(tester);
      final rest = tester.getSize(find.byType(TaskRow));
      expect(paintsRing(tester, light.colorScheme.primary), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await settleStates(tester);

      expect(
        paintsRing(tester, light.colorScheme.primary),
        isTrue,
        reason: 'a row reached by Tab must show where the keyboard is',
      );
      expect(tester.getSize(find.byType(TaskRow)), rest);
    });

    testWidgets('the row body offers the click cursor on a desktop pointer', (
      tester,
    ) async {
      await pumpRow(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text(_title)));
      await tester.pump();

      expect(
        // `TestPointer` gives every mouse gesture device 1.
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: 'a tappable surface points on a desktop pointer',
      );
    });

    testWidgets('reduced motion: the wash is at full strength on the SAME '
        'frame and a press spreads no ripple', (tester) async {
      await pumpRow(tester, disableAnimations: true);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text(_title)));
      await tester.pump();

      expect(
        paintsWash(tester, hoverWash(light.colorScheme)),
        isTrue,
        reason:
            'with animations removed the state layer arrives whole, not '
            'over a 50ms fade',
      );

      final finger = await tester.startGesture(
        tester.getCenter(find.text(_title)),
      );
      await settleStates(tester);
      expect(
        paintsSplashCircle(tester),
        isFalse,
        reason: 'reduced motion keeps the state layer and drops the SPREAD',
      );
      await finger.up();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('the tap still opens the detail', (tester) async {
      final opened = <String>[];
      await pumpRow(tester, opened: opened);
      await tester.tap(find.text(_title));
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, [_title]);
    });
  });

  group('the wrapper', () {
    const box = Key('wrapped');

    Future<void> pumpLayer(
      WidgetTester tester, {
      List<String>? tapped,
      bool disableAnimations = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: light.copyWith(platform: TargetPlatform.linux),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: Scaffold(
              body: Center(
                child: StateLayer(
                  onTap: () => tapped?.add('tap'),
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox(
                    key: box,
                    width: 200,
                    height: 60,
                    child: Text('surface'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the wrapped child keeps its exact geometry through hover, '
        'focus and press', (tester) async {
      await pumpLayer(tester);
      final rect = tester.getRect(find.byKey(box));

      final mouse = await hover(tester, find.byKey(box));
      expect(paintsWash(tester, hoverWash(light.colorScheme)), isTrue);
      expect(tester.getRect(find.byKey(box)), rect, reason: 'hover');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await settleStates(tester);
      expect(paintsRing(tester, light.colorScheme.primary), isTrue);
      expect(tester.getRect(find.byKey(box)), rect, reason: 'focus');

      await mouse.down(tester.getCenter(find.byKey(box)));
      await settleStates(tester);
      expect(paintsWash(tester, pressWash(light.colorScheme)), isTrue);
      expect(tester.getRect(find.byKey(box)), rect, reason: 'press');

      await mouse.up();
      await settleStates(tester);
      expect(tester.getRect(find.byKey(box)), rect, reason: 'released');
    });

    testWidgets('the focus ring is drawn INSIDE the surface, never around it', (
      tester,
    ) async {
      await pumpLayer(tester);
      final rect = tester.getRect(find.byKey(box));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await settleStates(tester);

      final ring = treeCalls(tester).firstWhere(
        (c) =>
            c.memberName == #drawDRRect &&
            _paintsOf(
              c,
            ).any((p) => _sameLayer(p.color, light.colorScheme.primary)),
        orElse: () => throw StateError('no focus ring was painted'),
      );
      final outer = ring.positionalArguments[0] as RRect;
      expect(outer.outerRect.width, lessThanOrEqualTo(rect.width));
      expect(outer.outerRect.height, lessThanOrEqualTo(rect.height));
    });

    testWidgets('a row the DETAIL is showing still shows its press layer — the '
        'state layer is painted OVER the row wash, not under it', (
      tester,
    ) async {
      // The light theme's open-in-detail wash is fully opaque. An ink surface
      // that lived on an ancestor Material would paint the press layer
      // UNDERNEATH it, and the row the user is pressing would answer nothing.
      await tester.pumpWidget(
        MaterialApp(
          theme: light.copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: TaskRow(
              title: _title,
              completed: false,
              openInDetail: true,
              onOpen: () {},
              onToggle: () {},
              onRename: (_) {},
            ),
          ),
        ),
      );
      final finger = await tester.startGesture(
        tester.getCenter(find.text(_title)),
      );
      await settleStates(tester);

      final calls = treeCalls(tester);
      int indexOf(Color color) => calls.indexWhere(
        (c) => _paintsOf(c).any((p) => _sameLayer(p.color, color)),
      );
      final wash = indexOf(openDetailWash(light.colorScheme));
      final press = indexOf(pressWash(light.colorScheme));
      expect(wash, isNonNegative, reason: 'the open-row wash is drawn');
      expect(press, isNonNegative, reason: 'the press layer is drawn');
      expect(
        press,
        greaterThan(wash),
        reason: 'the press layer must land ON TOP of the opaque row wash',
      );

      await finger.up();
      await settleStates(tester);
    });
  });

  group('other surfaces', () {
    StoredTaskList storedList(String id, String title) => StoredTaskList(
      list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
      syncState: SyncState.clean,
      localUpdated: 't',
    );

    Future<void> pumpSidebar(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: light.copyWith(platform: TargetPlatform.linux),
          home: Scaffold(
            body: Row(
              children: [
                Sidebar(
                  selectedViewId: 'all',
                  counts: const {},
                  lists: [storedList('L1', 'Groceries')],
                  excludedLists: const {},
                  onSelectView: (_) {},
                  onCreateList: (t, {localOnly = false}) {},
                  onRenameList: (a, b) {},
                  onDeleteList: (_) {},
                  onToggleExclude: (_) {},
                  onReorderLists: (_) {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a drawer list row wears the same hover wash as a task row', (
      tester,
    ) async {
      await pumpSidebar(tester);
      expect(paintsWash(tester, hoverWash(light.colorScheme)), isFalse);
      await hover(tester, find.text('Groceries'));
      expect(
        paintsWash(tester, hoverWash(light.colorScheme)),
        isTrue,
        reason: 'the drawer rows are part of the same pass',
      );
    });

    testWidgets('a drag handle offers the GRAB cursor, not the pointing hand '
        '— it is dragged, not tapped', (tester) async {
      await pumpSidebar(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.drag_indicator)));
      await tester.pump();

      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.grab,
      );
    });
  });
}
