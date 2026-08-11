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

import 'package:axiotask/src/ui/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Pump a real [ToastOverlay] over a trivial scaffold, returning the
  /// controller the test drives. Disposed on tear-down so no auto-dismiss timer
  /// is left pending.
  Future<ToastController> pumpOverlay(
    WidgetTester tester, {
    Widget? body,
  }) async {
    final controller = ToastController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        // Mount the overlay ABOVE the Navigator (as the real app does via
        // MaterialApp.router's builder) so a toast out-stacks modal routes.
        builder: (context, child) => ToastOverlay(
          controller: controller,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: body ?? const SizedBox.expand()),
      ),
    );
    return controller;
  }

  /// Flush any still-running auto-dismiss timers so the test ends clean.
  Future<void> flush(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 31));

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
      // …and after 5s it is gone on its own.
      await tester.pump(const Duration(seconds: 1));
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
      // Acting on it dismisses the toast.
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
}
