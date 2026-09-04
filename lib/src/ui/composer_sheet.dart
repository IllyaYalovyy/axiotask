// The TOUCH creation surface (#216, split out of the orchestrator by #274): a
// modal bottom-sheet composer over the same controller, focus node and submit
// path as the desktop bar, so drafts, NL-date preview, landing toasts (#190)
// and the background flush (#183) are identical on both pointer classes.
//
// Submitting clears the field and KEEPS the sheet open for rapid consecutive
// adds; back / swipe-down / a scrim tap dismisses it (an unsubmitted draft
// survives in the controller and reappears on the next open). Landing toasts
// render through ToastOverlay, which sits above modals (F19).
//
// It is not a sheet that HAPPENS to be opened by the FAB — it is the FAB
// (#234). The shell drops the FAB the moment this starts opening and gets it
// back the moment the sheet starts folding, and [ComposerMorph] unfolds the
// surface out of the corner the FAB just left. The route goes on the ROOT
// navigator: on the shell's nested one it rendered UNDER the shell's own
// chrome, which is how the FAB came to cover this composer's submit button.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../store/stored.dart';
import 'composer_controller.dart';
import 'new_task_fab.dart' show ComposerMorph;
import 'quick_add_bar.dart';

/// Open the touch composer over [controller] and keep the shell's composer flag
/// in step with it.
Future<void> showComposerSheet(
  BuildContext context,
  WidgetRef ref,
  ComposerController controller,
) async {
  final quickAddFocus = ref.read(quickAddFocusProvider);
  // Read the notifier, not through `ref`, so the release below still works if
  // the host is unmounted while the sheet (a root-navigator route) is up.
  final composer = ref.read(composerOpenProvider.notifier);
  composer.set(true);
  // Raise the keyboard with the sheet — the composer is ready to type into the
  // moment it appears, with no extra tap.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) quickAddFocus.requestFocus();
  });
  try {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      // The morph draws the sheet surface AND its drag handle itself, so both
      // unfold as one thing; the route's own background and handle would pop in
      // at full width behind them.
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (sheetContext) => ComposerMorph(
        animation: ModalRoute.of(sheetContext)!.animation!,
        onDismiss: () => Navigator.of(sheetContext).maybePop(),
        onFoldStart: () => composer.set(false),
        child: _SheetComposer(controller: controller, focusNode: quickAddFocus),
      ),
    );
  } finally {
    // Whatever ended the sheet — a fold, a hot route swap, a torn-down host —
    // the shell must never be left believing a composer is still up.
    composer.set(false);
    // The composer session is over: the aim goes back to the view's defaults
    // (#264). A date the user set for THIS burst of adds must not be waiting,
    // unannounced, on a composer they open again an hour later.
    controller.draft.release();
  }
}

/// The sheet's own body. A [ConsumerWidget], so it watches the LIVE list set
/// (#274): the route is built once and outlives every submit, so a list value
/// captured when it was built went stale the moment a sync pull moved it — and
/// the destination picker then offered lists that no longer existed while
/// hiding one that did.
class _SheetComposer extends ConsumerWidget {
  const _SheetComposer({required this.controller, required this.focusNode});

  final ComposerController controller;
  final FocusNode focusNode;

  /// Hand the caret back to the composer after an action that stole it (a
  /// target pick, a submit, a paste offer) — but NEVER onto a route that is
  /// already on its way out (#233).
  ///
  /// The composer's [FocusNode] is app-wide and outlives the sheet, so a
  /// request that lands once the route has popped focuses a field the user can
  /// no longer see: the IME connection reopens for a dying route, and the
  /// bottom view inset it raises has nothing left to retract it — the shell is
  /// left reserving half the screen for a keyboard that is gone. The shell's
  /// `ImeInsetGuard` recovers from that state; this keeps the composer from
  /// causing it.
  void _refocus(BuildContext sheetContext) {
    if (!sheetContext.mounted) return;
    final route = ModalRoute.of(sheetContext);
    // `isActive` goes false the instant the route is popped — before its exit
    // animation has drawn a single frame — which is exactly the #233 state to
    // refuse. It stays TRUE while another modal (the quick-date sheet, the
    // calendar) is layered on top and closing again, which is when the caret
    // must come back rather than be abandoned.
    if (route == null || !route.isActive) return;
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists =
        ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    // BOTH composer surfaces render from the ONE draft (#264): observing it
    // here means the sheet re-renders whenever the aim moves, from whichever
    // surface moved it.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Padding(
        // Keep the composer above the keyboard (#166 IME contract), and off the
        // gesture pill when there is no keyboard to clear it (the route's safe
        // area covers the top edge only).
        padding: EdgeInsets.only(bottom: composerSheetInset(context)),
        child: QuickAddBar(
          controller: controller.text,
          focusNode: focusNode,
          dateIgnoredFor: controller.draft.dateIgnoredFor,
          pickedDue: controller.draft.pickedDue,
          lists: lists,
          targetListId: controller.targetListIn(lists),
          onTargetChanged: (id) {
            controller.aimAtList(id);
            _refocus(context);
          },
          onSubmit: () {
            controller.submit();
            // Rapid entry: the field cleared; keep composing.
            _refocus(context);
          },
          onAddPastedLines: (raw) {
            controller.addPastedLines(raw);
            _refocus(context);
          },
          onDismissPreview: () {
            controller.dismissPreview();
            _refocus(context);
          },
          onSetDue: (move) {
            controller.setDue(move);
            _refocus(context);
          },
          onPickDue: () async {
            await controller.pickDue(context);
            // Only while that route survived the calendar the user was just in.
            if (context.mounted) _refocus(context);
          },
        ),
      ),
    );
  }
}
