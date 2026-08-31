// The toast / undo stack (T7.8): the in-app feedback surface for a failed
// command (a red, auto-dismissing error toast) and a reversible action (an
// undo toast whose button reverts it). Port of the reference's Toast +
// toast-stack, ErrorToast, ToastStack and ToastZIndex (#172) suites.
//
// These assert what the USER sees and can act on: the message renders, the
// error toast auto-dismisses, its dismiss button removes it, an undo button
// fires its callback, an error and an undo toast coexist in one stack, and —
// load-bearing (#172) — a toast raised while a modal dialog is open is still
// reachable (it out-stacks the modal barrier). Timing is driven by
// `tester.pump(duration)`, never a real clock.
//
// #258 adds the motion the surface had none of: a card that ARRIVES and LEAVES
// rather than blinking, an Undo toast that shows how long it has left and holds
// that time while the user is on it, a swipe that throws it away on a phone,
// and a stack that stops growing past two cards.

import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Pump a real [ToastOverlay] over a trivial scaffold, returning the
  /// controller the test drives. Disposed on tear-down so no auto-dismiss timer
  /// is left pending.
  Future<ToastController> pumpOverlay(
    WidgetTester tester, {
    Widget? body,
    TargetPlatform platform = TargetPlatform.linux,
    bool reducedMotion = false,
  }) async {
    final controller = ToastController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        // Mount the overlay ABOVE the Navigator (as the real app does via
        // MaterialApp.router's builder) so a toast out-stacks modal routes.
        builder: (context, child) => MediaQuery(
          // The reduced-motion switch has to sit ABOVE the overlay: the stack
          // reads it through [Motion.of], exactly as it does in the app.
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: ToastOverlay(
            controller: controller,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: Scaffold(body: body ?? const SizedBox.expand()),
      ),
    );
    return controller;
  }

  /// The opacity a toast's fade layer is currently painting at.
  double fadeOf(WidgetTester tester, int id) =>
      tester.widget<Opacity>(find.byKey(toastFadeKey(id))).opacity;

  /// The countdown bar's current width, in logical pixels.
  double barWidth(WidgetTester tester, int id) =>
      tester.getSize(find.byKey(toastCountdownKey(id))).width;

  /// Let a card finish arriving (or leaving).
  Future<void> settleMotion(WidgetTester tester) =>
      tester.pump(MotionDurations.medium);

  /// Flush any still-running auto-dismiss timers so the test ends clean — and
  /// then the exit motion they start, so no card is left mid-leave.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(MotionDurations.medium);
  }

  group('ErrorToast', () {
    testWidgets('a failed command shows a red error toast with its message', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      c.showError('Sync failed — the details are in the log.');
      await tester.pump();

      expect(
        find.text('Sync failed — the details are in the log.'),
        findsOneWidget,
      );
      // The error variant is visually distinct (an error glyph the user reads
      // as "this went wrong"), not a neutral info toast.
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await flush(tester);
    });

    testWidgets('an error toast auto-dismisses after its 5s life', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      c.showError('Transient blip');
      await tester.pump();
      expect(find.text('Transient blip'), findsOneWidget);

      // Just before its life ends it is still up…
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Transient blip'), findsOneWidget);
      // …and after 5s it leaves on its own — the card plays its exit (#258)
      // and is gone once that has run.
      await tester.pump(const Duration(seconds: 1));
      await settleMotion(tester);
      expect(find.text('Transient blip'), findsNothing);
    });

    testWidgets('the dismiss button removes the toast immediately', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      c.showError('Dismiss me');
      await tester.pump();
      expect(find.text('Dismiss me'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      await settleMotion(tester);
      expect(find.text('Dismiss me'), findsNothing);
      await flush(tester);
    });

    testWidgets('an identical persistent error is not repeated', (
      tester,
    ) async {
      // A background failure that reports the same error every cadence tick
      // must not stack a wall of duplicate toasts.
      final c = await pumpOverlay(tester);
      c.showError('network: timeout');
      c.showError('network: timeout');
      await tester.pump();
      expect(find.text('network: timeout'), findsOneWidget);
      await flush(tester);
    });
  });

  group('undo toast', () {
    testWidgets('an undo toast shows an Undo button that fires its action', (
      tester,
    ) async {
      var undone = 0;
      final c = await pumpOverlay(tester);
      c.showUndo('Deleted "Buy milk"', () => undone++);
      await tester.pump();

      expect(find.text('Deleted "Buy milk"'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1, reason: 'the Undo button reverts the action');
      // Acting on it dismisses the toast (once its exit has played, #258).
      await settleMotion(tester);
      expect(find.text('Deleted "Buy milk"'), findsNothing);
      await flush(tester);
    });
  });

  group('action toast (F19 #198)', () {
    testWidgets(
      'showAction renders a CUSTOM-labelled button that fires and dismisses',
      (tester) async {
        // The landing toast (#190) routes through the one feedback surface with
        // a "View" jump — not "Undo". The button carries the custom label and
        // dismissing the toast on tap works the same as an undo.
        var viewed = 0;
        final c = await pumpOverlay(tester);
        c.showAction(
          'Added "buy milk" to Focus',
          actionLabel: 'View',
          onAction: () => viewed++,
        );
        await tester.pump();

        expect(find.text('Added "buy milk" to Focus'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'View'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, 'Undo'),
          findsNothing,
          reason: 'the action label is "View", not the default "Undo"',
        );

        await tester.tap(find.text('View'));
        await tester.pump();
        expect(viewed, 1);
        await settleMotion(tester);
        expect(find.text('Added "buy milk" to Focus'), findsNothing);
        await flush(tester);
      },
    );

    testWidgets(
      'disposing the controller cancels a pending auto-dismiss timer',
      (tester) async {
        // Regression guard for the migration: undo toasts live 30s. If their
        // timer were an uncancellable Future.delayed, a widget test that raised
        // one and ended would leave a pending timer (a teardown failure).
        // dispose() must cancel it — proven by ending the test WITHOUT pumping
        // past the 30s life: a leaked timer fails with "A Timer is still
        // pending", so this test passing IS the guarantee.
        final c = ToastController();
        c.showUndo('Deleted "x"', () {}); // schedules the 30s timer
        c.dispose(); // must cancel it
      },
    );
  });

  group('ToastStack', () {
    testWidgets(
      'an error toast and an undo toast coexist so Undo stays reachable',
      (tester) async {
        // Regression: a sync-error toast raised while an undo toast is up must
        // not evict the undo toast — the user must still be able to undo.
        final c = await pumpOverlay(tester);
        c.showUndo('Deleted "Stack me"', () {});
        c.showError('Sync failed: network error');
        await tester.pump();

        expect(find.byType(ToastCard), findsNWidgets(2));
        expect(find.text('Deleted "Stack me"'), findsOneWidget);
        expect(find.text('Sync failed: network error'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
        await flush(tester);
      },
    );
  });

  group('ToastZIndex (#172)', () {
    testWidgets(
      'a toast raised while a modal dialog is open is still reachable',
      (tester) async {
        // The toast stack must out-stack every modal overlay: the feedback
        // telling the user their save failed is worthless if the dialog they
        // are in paints over it. Prove it by tapping the toast's dismiss button
        // WITH the modal barrier present — if the barrier out-stacked the toast
        // it would swallow the tap (and, worse, the barrier tap would close the
        // dialog).
        late BuildContext dialogContext;
        final c = await pumpOverlay(
          tester,
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) {
                    dialogContext = ctx;
                    return const AlertDialog(content: Text('A modal dialog'));
                  },
                ),
                child: const Text('Open dialog'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open dialog'));
        await tester.pumpAndSettle();
        expect(find.text('A modal dialog'), findsOneWidget);

        // Raise an error toast from behind the open modal.
        c.showError('Save failed while the dialog was open');
        await tester.pump();
        expect(
          find.text('Save failed while the dialog was open'),
          findsOneWidget,
        );

        // The dismiss button receives the tap despite the modal barrier…
        await tester.tap(find.byTooltip('Dismiss'));
        await tester.pump();
        await settleMotion(tester);
        expect(
          find.text('Save failed while the dialog was open'),
          findsNothing,
        );
        // …and the dialog stayed open (the barrier did NOT get the tap).
        expect(find.text('A modal dialog'), findsOneWidget);
        expect(dialogContext, isNotNull);
        await flush(tester);
      },
    );
  });

  // ── #258 motion ───────────────────────────────────────────────────────────

  group('toast motion (#258)', () {
    testWidgets('a toast ARRIVES: it slides up into place while fading in', (
      tester,
    ) async {
      // The failure this prevents: a card that simply exists on one frame and
      // not the previous one. The user's eye has nothing to follow to it, so
      // feedback raised at the far corner of a large window is missed outright.
      final c = await pumpOverlay(tester);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump(); // the arriving frame

      final start = tester.getTopLeft(find.byType(ToastCard));
      final startFade = fadeOf(tester, id);
      expect(
        startFade,
        lessThan(1.0),
        reason: 'the card begins transparent, not fully painted',
      );

      await tester.pump(MotionDurations.medium ~/ 2);
      final mid = tester.getTopLeft(find.byType(ToastCard));
      expect(mid.dy, lessThan(start.dy), reason: 'it has travelled UPWARD');
      expect(fadeOf(tester, id), greaterThan(startFade));

      await tester.pump(MotionDurations.medium);
      final rest = tester.getTopLeft(find.byType(ToastCard));
      expect(mid.dy, greaterThan(rest.dy), reason: 'it was still below at mid');
      expect(fadeOf(tester, id), 1.0);
      expect(
        start.dy - rest.dy,
        closeTo(kToastSlide, 0.01),
        reason: 'the travel is exactly the documented 16dp',
      );
      await flush(tester);
    });

    testWidgets('a lapsing toast LEAVES: it fades and slides back down', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      final id = c.showInfo('Saved');
      await tester.pump();
      await settleMotion(tester);
      final rest = tester.getTopLeft(find.byType(ToastCard));

      // Its 4s life ends: it is still on screen, and on its way out.
      await tester.pump(kInfoToastDuration);
      expect(find.text('Saved'), findsOneWidget);

      await tester.pump(MotionDurations.medium ~/ 2);
      expect(fadeOf(tester, id), lessThan(1.0));
      expect(
        tester.getTopLeft(find.byType(ToastCard)).dy,
        greaterThan(rest.dy),
        reason: 'the exit is the reverse of the entrance — downward',
      );

      await tester.pump(MotionDurations.medium);
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('a card on its way out takes no input', (tester) async {
      // Non-happy path: the Undo button is still PAINTED during the 200ms
      // exit, and a tap landing on a toast the controller has already dropped
      // would run its action a second time.
      var undone = 0;
      final c = await pumpOverlay(tester);
      c.showUndo('Deleted "Buy milk"', () => undone++);
      await tester.pump();
      await settleMotion(tester);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);

      // Mid-exit the button is still there to be found…
      await tester.pump(MotionDurations.medium ~/ 2);
      expect(find.text('Undo'), findsOneWidget);
      // …but it is not reachable: the tap falls through.
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await tester.pump();
      expect(undone, 1, reason: 'a leaving card cannot fire its action again');
      await flush(tester);
    });

    testWidgets('one toast replacing another CROSS-fades', (tester) async {
      // Both spans run over the same frames — the outgoing card is still
      // fading out while the incoming one is fading in, which is the crossing.
      final c = await pumpOverlay(tester);
      final leaving = c.showInfo('Saved');
      await tester.pump();
      await settleMotion(tester);

      c.dismiss(leaving);
      final arriving = c.showInfo('Saved again');
      await tester.pump();
      await tester.pump(MotionDurations.medium ~/ 2);

      expect(fadeOf(tester, leaving), lessThan(1.0));
      expect(fadeOf(tester, arriving), lessThan(1.0));
      expect(
        fadeOf(tester, leaving),
        lessThan(fadeOf(tester, arriving)),
        reason: 'the outgoing card is already dimmer than the incoming one',
      );
      await flush(tester);
    });

    testWidgets('reduced motion places the toast with no travel at all', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, reducedMotion: true);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();

      final at = tester.getTopLeft(find.byType(ToastCard));
      expect(fadeOf(tester, id), 1.0);
      await tester.pump(MotionDurations.medium);
      expect(
        tester.getTopLeft(find.byType(ToastCard)),
        at,
        reason: 'the card was simply THERE on the frame it was raised',
      );
      await flush(tester);
    });
  });

  group('undo countdown (#258)', () {
    testWidgets('the Undo toast shows how much of its life is left', (
      tester,
    ) async {
      // The failure this prevents: the 30s undo window is invisible, so the
      // toast's disappearance is a surprise and the user learns not to rely
      // on it.
      final c = await pumpOverlay(tester);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();
      await settleMotion(tester);

      final full = barWidth(tester, id);
      expect(full, greaterThan(0));

      await tester.pump(kUndoToastDuration ~/ 2);
      final half = barWidth(tester, id);
      expect(half, lessThan(full * 0.6));
      expect(half, greaterThan(full * 0.4));

      await tester.pump(kUndoToastDuration ~/ 4);
      expect(barWidth(tester, id), lessThan(half));
      await flush(tester);
    });

    testWidgets('an error toast carries NO countdown bar', (tester) async {
      // The bar says "act before this goes"; a toast with nothing to act on
      // must not grow a progress line it does not need.
      final c = await pumpOverlay(tester);
      final id = c.showError('Sync failed');
      await tester.pump();
      await settleMotion(tester);
      expect(find.byKey(toastCountdownKey(id)), findsNothing);
      await flush(tester);
    });

    testWidgets('hovering HOLDS the countdown and the toast with it', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();
      await settleMotion(tester);
      final full = barWidth(tester, id);

      await tester.pump(kUndoToastDuration ~/ 3);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(ToastCard)));
      await tester.pump();
      final held = barWidth(tester, id);
      expect(held, lessThan(full));

      // Well past the 30s life, with the pointer still on the card.
      await tester.pump(kUndoToastDuration);
      expect(barWidth(tester, id), held, reason: 'the drain is held');
      expect(
        find.text('Deleted "Buy milk"'),
        findsOneWidget,
        reason: 'and so is the toast — it cannot lapse under the pointer',
      );

      // Releasing gives it its FULL life back (the RestartableTimer restarts),
      // and the bar says so by refilling.
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(barWidth(tester, id), greaterThanOrEqualTo(full));
      await flush(tester);
      expect(find.text('Deleted "Buy milk"'), findsNothing);
    });

    testWidgets('a finger held on the toast holds it too', (tester) async {
      // Touch has no hover: the same hold has to be reachable by keeping a
      // finger on the card.
      final c = await pumpOverlay(tester, platform: TargetPlatform.android);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();
      await settleMotion(tester);
      await tester.pump(kUndoToastDuration ~/ 3);

      final finger = await tester.startGesture(
        tester.getCenter(find.text('Deleted "Buy milk"')),
      );
      await tester.pump();
      final held = barWidth(tester, id);

      await tester.pump(kUndoToastDuration);
      expect(barWidth(tester, id), held);
      expect(find.text('Deleted "Buy milk"'), findsOneWidget);

      await finger.up();
      await tester.pump();
      await flush(tester);
      expect(find.text('Deleted "Buy milk"'), findsNothing);
    });

    testWidgets('reduced motion STEPS the bar once a second', (tester) async {
      // The countdown is information, not decoration: "remove animations" must
      // not delete it. It stops sweeping and starts ticking instead.
      final c = await pumpOverlay(tester, reducedMotion: true);
      final id = c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();

      final full = barWidth(tester, id);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        barWidth(tester, id),
        full,
        reason: 'half a second in, the bar has not moved',
      );
      await tester.pump(const Duration(milliseconds: 600));
      final afterOne = barWidth(tester, id);
      expect(afterOne, lessThan(full), reason: 'past 1s it has stepped once');
      expect(
        afterOne,
        closeTo(full * 29 / 30, 1.0),
        reason: 'exactly one of the 30 steps',
      );
      await flush(tester);
    });
  });

  group('swipe to dismiss (#258)', () {
    testWidgets('a coarse pointer throws the toast away without taking Undo', (
      tester,
    ) async {
      var undone = 0;
      final c = await pumpOverlay(tester, platform: TargetPlatform.android);
      c.showUndo('Deleted "Buy milk"', () => undone++);
      await tester.pump();
      await settleMotion(tester);

      await tester.drag(find.byType(ToastCard), const Offset(0, 240));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Deleted "Buy milk"'), findsNothing);
      expect(
        undone,
        0,
        reason: 'throwing the toast away is not the same as undoing',
      );
      await flush(tester);
    });

    testWidgets('the same drag on a desktop pointer leaves the toast alone', (
      tester,
    ) async {
      // Non-happy path: the swipe is a coarse-pointer affordance. On the
      // desktop the × is the way out, and a stray drag must not eat feedback.
      final c = await pumpOverlay(tester);
      c.showUndo('Deleted "Buy milk"', () {});
      await tester.pump();
      await settleMotion(tester);

      await tester.drag(find.byType(ToastCard), const Offset(0, 240));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Deleted "Buy milk"'), findsOneWidget);
      await flush(tester);
    });
  });

  group('stack collapse (#258)', () {
    testWidgets('a third toast collapses the stack to the newest, with +2', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      c.showInfo('first');
      c.showInfo('second');
      c.showInfo('third');
      await tester.pump();
      await settleMotion(tester);
      await settleMotion(tester);

      expect(find.byType(ToastCard), findsOneWidget);
      expect(find.text('third'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      await flush(tester);
    });

    testWidgets('two toasts are still two cards', (tester) async {
      // The limit is the point: a second toast must NOT collapse anything.
      final c = await pumpOverlay(tester);
      c.showInfo('first');
      c.showInfo('second');
      await tester.pump();
      await settleMotion(tester);

      expect(find.byType(ToastCard), findsNWidgets(2));
      expect(find.textContaining('+'), findsNothing);
      await flush(tester);
    });

    testWidgets('the pill moves to the card ARRIVING behind a dismissed one', (
      tester,
    ) async {
      // The failure this prevents: the "+N" riding the card that is leaving.
      // Dismissing the collapsed card uncovers the next one, and the count has
      // to be on the card that is now standing in for the rest — not painted
      // over a surface that is fading out while the arriving one says nothing.
      final c = await pumpOverlay(tester);
      c.showInfo('one');
      c.showInfo('two');
      c.showInfo('three');
      final newest = c.showInfo('four');
      await tester.pump();
      await settleMotion(tester);
      await settleMotion(tester);
      expect(find.text('four'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);

      c.dismiss(newest);
      await tester.pump();
      // Mid-exit, while both cards are on screen: the count is already on the
      // arriving card, and the leaving one carries none.
      await tester.pump(MotionDurations.medium ~/ 2);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('three'),
            matching: find.byType(ToastCard),
          ),
          matching: find.text('+2'),
        ),
        findsOneWidget,
      );
      expect(find.text('+3'), findsNothing);
      await flush(tester);
    });

    testWidgets('a collapsed card holds up at 2.0x text scale on a phone', (
      tester,
    ) async {
      // Non-happy path (#247's question, asked of the new pill): the pill is
      // one more fixed-width thing in a row that already carries an action and
      // a dismiss. At the far end of Android's font scaling it must reflow, not
      // paint an overflow hatch over the message it is standing in front of.
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = ToastController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: ToastOverlay(
              controller: controller,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      // The undo is raised LAST so it is the card the stack collapses onto:
      // the widest thing this surface can build is one card carrying a pill, a
      // long message, an Undo and a dismiss all at once.
      controller.showError('one');
      controller.showError('two');
      controller.showUndo('Deleted "Book the dentist"', () {});
      await tester.pump();
      await settleMotion(tester);
      await settleMotion(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Deleted "Book the dentist"'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      await flush(tester);
    });

    testWidgets('a collapsed Undo is HIDDEN, not lost: it comes back', (
      tester,
    ) async {
      // The #172/F19 invariant under the new rule — an undo out-stacked by two
      // errors is not destroyed. The errors lapse after 5s and the undo, which
      // has 30, is on screen again with its button.
      final c = await pumpOverlay(tester);
      c.showUndo('Deleted "Buy milk"', () {});
      c.showError('one');
      c.showError('two');
      await tester.pump();
      await settleMotion(tester);
      await settleMotion(tester);

      expect(find.byType(ToastCard), findsOneWidget);
      expect(find.text('two'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Deleted "Buy milk"'), findsNothing);

      await tester.pump(kErrorToastDuration);
      await settleMotion(tester);
      await settleMotion(tester);
      expect(find.byType(ToastCard), findsOneWidget);
      expect(find.text('Deleted "Buy milk"'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      expect(find.text('+2'), findsNothing);
      await flush(tester);
    });
  });
}
