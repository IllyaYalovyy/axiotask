// How the detail arrives and leaves (#253).
//
// Before this, opening a task was a hard cut on both layouts: on the phone the
// detail replaced the list with no relation to the row tapped, and on the
// desktop the pane popped into the layout while the list snapped to its new
// width. Both left the user without the one piece of information the
// transition exists to carry — WHICH task they just opened.
//
// What these tests protect:
//   • compact — the surface starts at the tapped ROW's rect, is measurably
//     between that rect and the screen mid-flight, and ends full-screen (the
//     failure they catch is the default hard cut: full-screen on frame one);
//   • compact back — the surface shrinks back towards the same row, including
//     when an Android predictive back drags it there by hand;
//   • an open that came from NO row (a search jump, a restored URL) is not
//     given an invented container — it arrives full-size and only fades;
//   • prev/next steps along the view's ordering, leading edge first;
//   • expanded — the list's width eases across FRAMES rather than snapping,
//     and the #221 row highlight is invisible until the pane has landed;
//   • a drag on the pane divider is not eased at all — width follows the
//     pointer, exactly as before;
//   • reduced motion puts the detail simply there, and simply gone.
//
// Determinism: every animation here is driven by pumped durations against the
// test's fake clock. Nothing waits on a real timer, and no test pumps to
// settle with a focused field.

import 'package:axiotask/src/ui/detail_motion.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

const _phone = Size(400, 800);
const _desktop = Size(1200, 800);

const _destinations = [
  ShellDestination(
    icon: Icons.bolt_outlined,
    selectedIcon: Icons.bolt,
    label: 'Focus',
  ),
  ShellDestination(
    icon: Icons.checklist_outlined,
    selectedIcon: Icons.checklist,
    label: 'All Tasks',
  ),
];

/// The scaffold under test with a stand-in list: one tappable box per task,
/// each recording its own rect on open exactly as a real row does (the real
/// row's half of that wiring is pinned by the last test in this file).
class _Host extends StatefulWidget {
  const _Host({required this.controller, this.openRowHighlight = false});

  final DetailOriginController controller;

  /// Render the list as a real [TaskRow] marked open-in-detail, so the #221
  /// highlight can be measured as the user sees it.
  final bool openRowHighlight;

  /// The stand-in tasks and their places in the view's ordering.
  static const slots = {'A': 0, 'B': 1};

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? open;

  /// Open [id] the way the router does — a plain selection change, with no row
  /// tap and so no recorded origin. This is what the detail's own prev/next
  /// does, and what a search jump does.
  void select(String? id) => setState(() => open = id);

  @override
  Widget build(BuildContext context) {
    final openId = open;
    final rows = Column(
      key: const Key('list-pane'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in _Host.slots.keys)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Builder(
              builder: (rowContext) => GestureDetector(
                onTap: () {
                  widget.controller.report(id, rowContext);
                  setState(() => open = id);
                },
                child: SizedBox(
                  key: Key('row-$id'),
                  height: 56,
                  child: Center(child: Text('ROW-$id')),
                ),
              ),
            ),
          ),
        // An open that came from somewhere OTHER than a row: search, a restored
        // URL, the quick-add follow. Nothing is recorded.
        TextButton(
          key: const Key('open-rowless'),
          onPressed: () => setState(() => open = 'B'),
          child: const Text('JUMP'),
        ),
      ],
    );
    return DetailOriginScope(
      controller: widget.controller,
      child: ListDetailScaffold(
        sidebar: const Text('SIDEBAR-PANE'),
        destinations: _destinations,
        selectedIndex: 0,
        onDestinationSelected: (_) {},
        list: widget.openRowHighlight
            ? TaskRow(
                title: 'apples',
                completed: false,
                openInDetail: true,
                onOpen: () {},
                onToggle: () {},
                onRename: (_) {},
              )
            : rows,
        detail: openId == null
            ? null
            : Center(key: ValueKey(openId), child: Text('DETAIL-$openId')),
        detailTaskId: openId,
        detailSlot: openId == null ? null : _Host.slots[openId],
        onCloseDetail: () => setState(() => open = null),
      ),
    );
  }
}

Future<DetailOriginController> pumpHost(
  WidgetTester tester, {
  Size size = _phone,
  bool disableAnimations = false,
  bool openRowHighlight = false,
}) async {
  final controller = DetailOriginController();
  addTearDown(controller.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: _Host(controller: controller, openRowHighlight: openRowHighlight),
    ),
  );
  return controller;
}

/// The animating detail surface's rect.
Rect _surface(WidgetTester tester) =>
    tester.getRect(find.byKey(DetailContainerTransform.surfaceKey));

/// How opaque the detail's CONTENTS are inside that surface.
double _contents(WidgetTester tester) => tester
    .widget<Opacity>(find.byKey(DetailContainerTransform.contentsKey))
    .opacity;

/// The width the list pane currently occupies in the expanded layout.
double _listWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('list-pane'))).width;

/// Send one Android predictive-back channel message.
Future<void> _backGesture(
  WidgetTester tester,
  String method, [
  Map<String, dynamic>? args,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

void main() {
  group('compact — the row becomes the detail', () {
    testWidgets('the surface starts at the tapped row and ends full-screen', (
      tester,
    ) async {
      await pumpHost(tester);
      final rowRect = tester.getRect(find.byKey(const Key('row-B')));

      await tester.tap(find.text('ROW-B'));
      await tester.pump();

      // The failure this catches is the pre-#253 hard cut: a detail that is
      // already the whole screen on the first frame after the tap.
      expect(
        _surface(tester),
        rowRect,
        reason: 'the detail begins as the row it came from',
      );

      await tester.pump(const Duration(milliseconds: 200));
      final mid = _surface(tester);
      expect(mid.height, greaterThan(rowRect.height));
      expect(mid.height, lessThan(_phone.height));
      expect(mid.width, greaterThan(rowRect.width));
      expect(mid.width, lessThan(_phone.width));

      await tester.pump(MotionDurations.emphasized);
      expect(_surface(tester), Offset.zero & _phone);
      expect(find.text('DETAIL-B'), findsOneWidget);
    });

    testWidgets('the chrome it covers is only hidden once it has landed', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.tap(find.text('ROW-B'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Mid-flight the growing surface is over the screen the user was on —
      // that is what makes it a container transform rather than a cross-fade.
      expect(find.text('ROW-A'), findsOneWidget);
      expect(find.byType(ShellNavBar), findsOneWidget);

      await tester.pump(MotionDurations.emphasized);
      expect(find.text('ROW-A'), findsNothing);
      expect(find.byType(ShellNavBar), findsNothing);
    });

    testWidgets('nothing under a travelling surface answers a tap', (
      tester,
    ) async {
      // Mid-transform the app is between two states. A second tap landing on
      // the list beneath — easy on a phone, where the first tap was a finger —
      // must not open a different task behind the one that is arriving.
      await pumpHost(tester);
      await tester.tap(find.text('ROW-B'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tapAt(tester.getCenter(find.byKey(const Key('row-A'))));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL-B'), findsOneWidget);
      expect(find.text('DETAIL-A'), findsNothing);
    });

    testWidgets('back shrinks the surface towards the same row', (
      tester,
    ) async {
      await pumpHost(tester);
      final rowRect = tester.getRect(find.byKey(const Key('row-B')));
      await tester.tap(find.text('ROW-B'));
      await tester.pumpAndSettle();
      expect(_surface(tester), Offset.zero & _phone);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final mid = _surface(tester);
      expect(mid.height, lessThan(_phone.height));
      expect(mid.height, greaterThan(rowRect.height));

      await tester.pump(const Duration(milliseconds: 120));
      final later = _surface(tester);
      expect(
        later.height,
        lessThan(mid.height),
        reason: 'it keeps closing on the row',
      );

      await tester.pumpAndSettle();
      expect(
        find.byKey(DetailContainerTransform.surfaceKey),
        findsNothing,
        reason: 'and then it is gone, not parked at zero',
      );
      expect(find.text('ROW-B'), findsOneWidget);
    });

    testWidgets('an open that came from no row is given no container', (
      tester,
    ) async {
      // The non-happy path: a search jump, a restored URL, a quick-add follow.
      // Inventing a container for those would grow the detail out of whatever
      // row was tapped last — a lie about where it came from.
      await pumpHost(tester);
      await tester.tap(find.byKey(const Key('open-rowless')));
      await tester.pump();

      expect(_surface(tester), Offset.zero & _phone);
      expect(
        _contents(tester),
        0.0,
        reason: 'it still arrives rather than cutting in',
      );

      await tester.pump(MotionDurations.emphasized);
      expect(_contents(tester), 1.0);
    });

    testWidgets(
      'reduced motion puts the detail simply there, and simply gone',
      (tester) async {
        await pumpHost(tester, disableAnimations: true);
        await tester.tap(find.text('ROW-B'));
        await tester.pump();

        expect(_surface(tester), Offset.zero & _phone);
        expect(_contents(tester), 1.0);

        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pump();
        expect(find.byKey(DetailContainerTransform.surfaceKey), findsNothing);
      },
    );
  });

  group('compact — predictive back', () {
    testWidgets('a back drag scrubs the surface back towards the row', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.tap(find.text('ROW-B'));
      await tester.pumpAndSettle();

      await _backGesture(tester, 'startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await _backGesture(tester, 'updateBackGestureProgress', {
        'x': 100.0,
        'y': 300.0,
        'progress': 0.6,
        'swipeEdge': 0,
      });
      await tester.pump();

      // No time has passed: the surface is where the FINGER put it.
      final dragged = _surface(tester);
      expect(dragged.height, lessThan(_phone.height));

      // Letting go part-way puts it back rather than closing anything.
      await _backGesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(_surface(tester), Offset.zero & _phone);
      expect(find.text('DETAIL-B'), findsOneWidget);
    });

    testWidgets('committing the drag closes the detail from where it was', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.tap(find.text('ROW-B'));
      await tester.pumpAndSettle();

      await _backGesture(tester, 'startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await _backGesture(tester, 'updateBackGestureProgress', {
        'x': 300.0,
        'y': 300.0,
        'progress': 0.8,
        'swipeEdge': 0,
      });
      await tester.pump();
      final dragged = _surface(tester).height;

      await _backGesture(tester, 'commitBackGesture');
      await tester.pump();
      expect(
        _surface(tester).height,
        lessThanOrEqualTo(dragged),
        reason: 'the close carries on from the finger, it does not restart',
      );

      await tester.pumpAndSettle();
      expect(find.text('DETAIL-B'), findsNothing);
      expect(find.text('ROW-B'), findsOneWidget);
    });

    testWidgets('reduced motion declines the gesture (the OS pops instead)', (
      tester,
    ) async {
      await pumpHost(tester, disableAnimations: true);
      await tester.tap(find.text('ROW-B'));
      await tester.pump();

      await _backGesture(tester, 'startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await _backGesture(tester, 'updateBackGestureProgress', {
        'x': 100.0,
        'y': 300.0,
        'progress': 0.6,
        'swipeEdge': 0,
      });
      await tester.pump();

      // Unclaimed: nothing scrubs, and the detail is still whole.
      expect(_surface(tester), Offset.zero & _phone);
      expect(find.text('DETAIL-B'), findsOneWidget);
    });
  });

  group('compact — prev/next is a step, not a transform', () {
    testWidgets('the arriving panel comes from the leading edge going back', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.tap(find.text('ROW-B')); // slot 1
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(find.text('DETAIL-B')).dx;

      // Previous: a step towards the START of the ordering.
      final host = tester.state<_HostState>(find.byType(_Host));
      host.select('A');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('DETAIL-A'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('DETAIL-A')).dx,
        lessThan(settled),
        reason: 'it comes in from the side it is stepping from',
      );
      expect(
        find.text('DETAIL-B'),
        findsOneWidget,
        reason: 'and the one it displaces leaves rather than blinking out',
      );

      await tester.pumpAndSettle();
      expect(find.text('DETAIL-B'), findsNothing);
      expect(tester.getTopLeft(find.text('DETAIL-A')).dx, settled);
      expect(
        _surface(tester),
        Offset.zero & _phone,
        reason: 'a step is never a container transform',
      );
    });

    testWidgets('the arriving panel comes from the trailing edge going on', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.tap(find.text('ROW-A')); // slot 0
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(find.text('DETAIL-A')).dx;

      final host = tester.state<_HostState>(find.byType(_Host));
      host.select('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(tester.getTopLeft(find.text('DETAIL-B')).dx, greaterThan(settled));
    });
  });

  group('expanded — the pane slides in, the list eases', () {
    testWidgets('the list width changes across FRAMES, not in one', (
      tester,
    ) async {
      await pumpHost(tester, size: _desktop);
      final closed = _listWidth(tester);

      await tester.tap(find.text('ROW-B'));
      await tester.pump();
      expect(_listWidth(tester), closed, reason: 'nothing jumps on frame one');

      await tester.pump(const Duration(milliseconds: 150));
      final mid = _listWidth(tester);
      expect(mid, lessThan(closed));

      await tester.pump(const Duration(milliseconds: 100));
      final later = _listWidth(tester);
      expect(later, lessThan(mid), reason: 'still easing');

      await tester.pumpAndSettle();
      expect(_listWidth(tester), lessThan(later));
      expect(find.text('DETAIL-B'), findsOneWidget);
    });

    testWidgets('the pane slides in from the end edge, never squeezed', (
      tester,
    ) async {
      await pumpHost(tester, size: _desktop);
      await tester.tap(find.text('ROW-B'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final pane = tester.getRect(find.byKey(const Key('expanded-detail')));
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byKey(const Key('expanded-detail')));

      expect(
        pane.width,
        settled.width,
        reason: 'the pane is laid out at its final width the whole way in',
      );
      expect(
        pane.left,
        greaterThan(settled.left),
        reason: 'it travels in from the end edge',
      );
    });

    testWidgets('the #221 highlight is invisible until the pane has landed', (
      tester,
    ) async {
      await pumpHost(tester, size: _desktop, openRowHighlight: true);
      final host = tester.state<_HostState>(find.byType(_Host));
      final scheme = Theme.of(tester.element(find.byType(TaskRow))).colorScheme;

      host.select('B');
      await tester.pump();
      expect(_washAlpha(tester), 0.0);

      // Still nothing while the pane is travelling.
      await tester.pump(const Duration(milliseconds: 250));
      expect(_washAlpha(tester), 0.0);

      await tester.pumpAndSettle();
      expect(_washAlpha(tester), openDetailWash(scheme).a);
    });

    testWidgets(
      'a drag on the divider is not eased — width follows the pointer',
      (tester) async {
        await pumpHost(tester, size: _desktop);
        await tester.tap(find.text('ROW-B'));
        await tester.pumpAndSettle();
        final before = tester.getSize(find.byKey(const Key('expanded-detail')));

        await tester.drag(
          find.byKey(const Key('detail-resize-handle')),
          const Offset(-80, 0),
        );
        await tester.pump();
        final dragged = tester.getSize(
          find.byKey(const Key('expanded-detail')),
        );
        expect(dragged.width, greaterThan(before.width));

        // Nothing is still moving a frame later: the pane went where the pointer
        // put it, in the frame the pointer put it there.
        await tester.pump(MotionDurations.detailPane);
        expect(
          tester.getSize(find.byKey(const Key('expanded-detail'))).width,
          dragged.width,
        );
        await tester.pump(kDoubleTapTimeout);
      },
    );
  });

  testWidgets('a real row records where it was before it navigates away', (
    tester,
  ) async {
    // The list's half of the wiring: without this the scaffold above would
    // always be given a null origin and every open would fade instead.
    final origin = DetailOriginController();
    addTearDown(origin.dispose);
    final opened = <String>[];
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: [list('L1', 'My Tasks')],
      opened: opened,
      originScope: origin,
    );

    final rowRect = tester.getRect(
      find.ancestor(of: find.text('bread'), matching: find.byType(TaskRow)),
    );
    await tester.tap(find.text('bread'));
    await settleList(tester);

    expect(opened, ['B']);
    expect(origin.rectFor('B'), rowRect);
    expect(
      origin.rectFor('A'),
      isNull,
      reason: 'a rect is only ever replayed under the task that recorded it',
    );
  });
}

/// The alpha of the open-in-detail wash the row is currently painting.
double _washAlpha(WidgetTester tester) {
  final decorations = tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(TaskRow),
          matching: find.byType(DecoratedBox),
        ),
      )
      .map((b) => b.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color != null && d.border == null);
  return decorations.isEmpty ? 0 : decorations.first.color!.a;
}
