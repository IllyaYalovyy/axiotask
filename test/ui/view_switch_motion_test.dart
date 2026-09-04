// How the app moves from one VIEW to another (#254).
//
// Before this, switching views was a hard cut: the frame after a tap on the
// bottom bar the old list was simply gone and a different one was in its place,
// indistinguishable from a sync that had rewritten the list under the user's
// hands. Nothing said WHICH WAY the app had moved, or even that the user was
// the one who moved it.
//
// What these tests protect:
//   • the bottom bar is an ORDERED set, so a step along it travels: to a later
//     destination the outgoing list leaves to the left and the next arrives
//     from the right, and a step back does the exact opposite (the failure they
//     catch is the hard cut — an outgoing list that is not on screen at all —
//     and a direction that ignores the tab index);
//   • a switch with NO spatial order — a list picked out of the drawer, or any
//     sidebar pick on the desktop, where there is no bar and no index — fades
//     THROUGH instead: the outgoing view is gone before the incoming one
//     begins, and neither of them moves a pixel;
//   • a rapid double switch settles on the LAST view, with no intermediate
//     pane left stuck on screen;
//   • the app bar's title cross-fades with the content rather than snapping a
//     frame ahead of it;
//   • reduced motion puts the new view simply there.
//
// Everything runs against the REAL app (the real router, the real shell, the
// real list) so the transition is exercised through the same rebuild a tap
// produces in production — including the one thing a synthetic host could not
// prove: that a go_router view change reaches the switch at all.
//
// Determinism: no clock is read (the seeded tasks carry no due dates), every
// frame is pumped explicitly against the fake clock, and the compact form
// factor has no quick-add field to keep a cursor blinking.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/shell_nav_bar.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeTitle implements WindowTitleController {
  @override
  Future<void> setTitle(String title) async {}
}

const _phone = Size(400, 800);
const _desktop = Size(1200, 900);

StoredTask _task(String id, String title) => StoredTask(
  task: Task(
    id: id,
    position: id,
    title: title,
    status: TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

const _work = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Work', etag: 'e', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

void main() {
  late Directory tmp;
  setUp(() {
    // NOT an addTearDown: flutter_test asserts every foundation debug var is
    // unset at the END OF THE BODY, so a test that pins a platform clears it
    // itself and this catches a leak from a body that failed early.
    debugDefaultTargetPlatformOverride = null;
    tmp = Directory.systemTemp.createTempSync('axiotask_view_switch');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The real app at [size], opened on [view], with one list and two tasks.
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = _phone,
    String view = 'focus',
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    if (disableAnimations) {
      // The platform accessibility flag itself (Android "remove animations" /
      // desktop reduced motion), not a MediaQuery a test invented: MaterialApp
      // builds its own MediaQuery from the view, so this is the only place the
      // real app can hear it from.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
    }
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(Prefs(view: view, onboardingSeen: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          windowTitleControllerProvider.overrideWithValue(_FakeTitle()),
          allTasksProvider.overrideWith(
            (ref) => Stream.value([_task('T1', 'alpha'), _task('T2', 'beta')]),
          ),
          listsProvider.overrideWith((ref) => Stream.value([_work])),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder pane(String viewId) => find.byKey(ValueKey('view-$viewId'));

  /// Where a view's list pane currently paints — the value that MOVES when a
  /// pane travels along the shared axis.
  double paneX(WidgetTester tester, String viewId) =>
      tester.getTopLeft(pane(viewId)).dx;

  /// How opaque that pane is — the value that moves when views fade through.
  double paneOpacity(WidgetTester tester, String viewId) => tester
      .widget<Opacity>(
        find.ancestor(of: pane(viewId), matching: find.byType(Opacity)).first,
      )
      .opacity;

  /// Tap a bottom-bar destination by its label.
  Future<void> tapDestination(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(ShellNavBar), matching: find.text(label)),
    );
  }

  group('the bottom bar is an ordered set — a shared axis along it', () {
    testWidgets('a step to a LATER destination sends the outgoing view left', (
      tester,
    ) async {
      await pumpApp(tester);
      final home = paneX(tester, 'focus');

      await tapDestination(tester, 'Upcoming');
      await tester.pump();

      // Frame one: the outgoing list is still where it was — the hard cut this
      // replaces had it gone already — and the arriving one is waiting off the
      // end edge, on the side the step is coming from.
      expect(paneX(tester, 'focus'), home);
      expect(paneX(tester, 'upcoming'), greaterThan(home));

      await tester.pump(const Duration(milliseconds: 100));
      final left = paneX(tester, 'focus');
      expect(left, lessThan(home), reason: 'it leaves towards the next tab');

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        paneX(tester, 'focus'),
        lessThan(left),
        reason: 'and keeps going that way',
      );
      expect(paneX(tester, 'upcoming'), greaterThan(home));

      await tester.pumpAndSettle();
      expect(pane('focus'), findsNothing);
      expect(paneX(tester, 'upcoming'), home);
    });

    testWidgets('a step BACK along the bar sends it the other way', (
      tester,
    ) async {
      await pumpApp(tester, view: 'upcoming');
      final home = paneX(tester, 'upcoming');

      await tapDestination(tester, 'Focus');
      await tester.pump();
      expect(paneX(tester, 'focus'), lessThan(home));

      await tester.pump(const Duration(milliseconds: 100));
      final right = paneX(tester, 'upcoming');
      expect(right, greaterThan(home), reason: 'the direction is the index');

      await tester.pump(const Duration(milliseconds: 100));
      expect(paneX(tester, 'upcoming'), greaterThan(right));

      await tester.pumpAndSettle();
      expect(pane('upcoming'), findsNothing);
      expect(paneX(tester, 'focus'), home);
    });
  });

  group('no order to honour — a fade-through', () {
    testWidgets('a list picked out of the drawer fades through, never slides', (
      tester,
    ) async {
      // The non-happy path for a spatial transition: a list is not one of the
      // bar's destinations, so there is no index and no direction. Sliding it
      // would claim a place in an order it has none in.
      await pumpApp(tester);
      final home = paneX(tester, 'focus');

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Work')),
      );
      await tester.pump();

      expect(paneX(tester, 'focus'), home, reason: 'nothing travels');
      expect(paneX(tester, 'L1'), home);
      expect(paneOpacity(tester, 'focus'), 1.0);
      expect(paneOpacity(tester, 'L1'), 0.0);

      // A third of the way in there is a moment of NEITHER view: that is what
      // makes it a fade-through rather than a cross-fade.
      await tester.pump(const Duration(milliseconds: 70));
      expect(paneOpacity(tester, 'focus'), lessThan(0.05));
      expect(paneOpacity(tester, 'L1'), lessThan(0.05));
      expect(paneX(tester, 'focus'), home);
      expect(paneX(tester, 'L1'), home);

      await tester.pump(const Duration(milliseconds: 80));
      expect(paneOpacity(tester, 'L1'), greaterThan(0.0));

      await tester.pumpAndSettle();
      expect(pane('focus'), findsNothing);
      expect(paneOpacity(tester, 'L1'), 1.0);
      expect(paneX(tester, 'L1'), home);
    });

    testWidgets('the desktop sidebar fades through even between two tabs', (
      tester,
    ) async {
      // The SAME two views that slide on the phone: the direction lives in the
      // bar, and the expanded layout has no bar.
      await pumpApp(tester, size: _desktop);
      final home = paneX(tester, 'focus');

      await tester.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text('Upcoming'),
        ),
      );
      await tester.pump();
      expect(paneX(tester, 'focus'), home);
      expect(paneX(tester, 'upcoming'), home);
      expect(paneOpacity(tester, 'focus'), 1.0);
      expect(paneOpacity(tester, 'upcoming'), 0.0);

      await tester.pump(const Duration(milliseconds: 70));
      expect(paneOpacity(tester, 'focus'), lessThan(0.05));
      expect(paneX(tester, 'focus'), home);
      expect(paneX(tester, 'upcoming'), home);

      await tester.pumpAndSettle();
      expect(pane('focus'), findsNothing);
      expect(paneX(tester, 'upcoming'), home);
    });
  });

  testWidgets('a rapid double switch settles on the LAST view', (tester) async {
    await pumpApp(tester);
    final home = paneX(tester, 'focus');

    await tapDestination(tester, 'Upcoming');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tapDestination(tester, 'Missed');
    await tester.pumpAndSettle();

    expect(pane('missed'), findsOneWidget);
    expect(pane('focus'), findsNothing);
    expect(pane('upcoming'), findsNothing);
    expect(paneX(tester, 'missed'), home);
    expect(paneOpacity(tester, 'missed'), 1.0);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Missed')),
      findsOneWidget,
    );
  });

  testWidgets('reduced motion puts the new view simply there', (tester) async {
    await pumpApp(tester, disableAnimations: true);
    final home = paneX(tester, 'focus');

    await tapDestination(tester, 'Upcoming');
    await tester.pump();

    expect(paneX(tester, 'upcoming'), home, reason: 'no travel at all');
    expect(paneOpacity(tester, 'upcoming'), 1.0);
    expect(pane('focus'), findsNothing);
  });

  testWidgets('the app bar title cross-fades with the content', (tester) async {
    Finder title(String label) =>
        find.descendant(of: find.byType(AppBar), matching: find.text(label));
    double titleOpacity(String label) => tester
        .widget<FadeTransition>(
          find
              .ancestor(of: title(label), matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;

    await pumpApp(tester);
    expect(title('Focus'), findsOneWidget);

    await tapDestination(tester, 'Upcoming');
    await tester.pump();
    // Both titles are up, one arriving over the other — the pre-#254 title
    // snapped to the new label a frame after the tap, ahead of its content.
    expect(title('Focus'), findsOneWidget);
    expect(title('Upcoming'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    expect(titleOpacity('Focus'), lessThan(1.0));
    expect(titleOpacity('Focus'), greaterThan(0.0));
    expect(titleOpacity('Upcoming'), greaterThan(0.0));

    await tester.pumpAndSettle();
    expect(title('Focus'), findsNothing);
    expect(title('Upcoming'), findsOneWidget);
  });

  testWidgets('the desktop quick-add still takes typing across a switch', (
    tester,
  ) async {
    // The non-happy path two panes on screen at once used to break: the
    // quick-add FocusNode is APP-WIDE (the desktop bar and the touch composer
    // are one input, #233), and while the panes cross-faded TWO fields held the
    // one node — the arriving field attaching it while the departing field
    // still had it. Get that order wrong and the bar the user is looking at is
    // left with a node detached under it, and the view they just opened cannot
    // be typed into at all.
    //
    // #274 removed the hazard rather than sequencing it: the composer lives
    // ABOVE the view switch, so there is exactly ONE bar however many panes are
    // mounted. That is what this now pins — one field throughout the switch,
    // holding its caret and its draft across it, and the arriving view typable
    // the moment it lands.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpApp(tester, size: _desktop);
    final field = find.descendant(
      of: find.byKey(const Key('quick-add-bar')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'before');
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Upcoming'),
      ),
    );
    // Straight through the fade-through, one frame at a time: no settle, because
    // a focused field keeps a caret blinking forever.
    await tester.pump();
    expect(
      find.byKey(const ValueKey('view-focus')),
      findsOneWidget,
      reason: 'the switch really is mid-flight — both panes are mounted',
    );
    expect(find.byKey(const ValueKey('view-upcoming')), findsOneWidget);
    expect(
      field,
      findsOneWidget,
      reason: 'and there is still exactly ONE composer over the two of them',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));

    expect(field, findsOneWidget, reason: 'one bar, in the view now open');
    // A tab tap is not a decision to throw away what you were writing (#274).
    expect(find.widgetWithText(TextField, 'before'), findsOneWidget);
    await tester.enterText(field, 'after');
    await tester.pump();
    expect(find.widgetWithText(TextField, 'after'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'before'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a row in the arriving view opens while it is still arriving', (
    tester,
  ) async {
    // Switching views must not cost the user a dead moment: the arriving list
    // is on screen and hit tests travel through the same translation the paint
    // does, so a row lands where it looks like it is. (The view being LEFT is
    // the one that stops answering — its far edge shows past the arriving pane
    // during a slide.)
    await pumpApp(tester, view: 'unscheduled');

    await tapDestination(tester, 'All Tasks');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final row = find.descendant(of: pane('all'), matching: find.text('alpha'));
    expect(row, findsOneWidget, reason: 'the arriving list is on screen');
    await tester.tap(row);
    await tester.pumpAndSettle();

    // The detail for the row that was tapped — not one from the view left
    // behind, and not nothing at all.
    expect(find.widgetWithText(TextField, 'alpha'), findsOneWidget);
  });
}
