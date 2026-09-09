// The TOUCH creation surface (#216, at the TOP since #304): a bar pinned
// directly under the shell's app bar, above the first row, over the same
// controller, focus node and submit path as the desktop bar — so drafts,
// NL-date preview, landing toasts (#190) and the background flush (#183) are
// identical on both pointer classes.
//
// It used to be a modal bottom sheet, and that was the wrong half of the
// screen: every task it created landed at the TOP of the list, out of sight
// behind the sheet, so adding three things in a row meant closing the composer
// and scrolling up to check what you had written (user ruling, #304). At the
// top it opens WHERE ITS ROWS LAND — each add inserts a row immediately under
// it — and the list is PUSHED down rather than covered, so nothing the composer
// is standing on is unreachable. The keyboard cannot reach it either: a bar
// under the app bar is structurally out of the IME's half of the screen, where
// the sheet had to spend a whole contract (#166) keeping itself clear.
//
// Submitting clears the field and KEEPS the panel open for rapid consecutive
// adds; the handle on its bottom edge (a tap, or a drag back up) and system
// back fold it away, and an unsubmitted draft survives in the controller to
// reappear on the next open.
//
// It is still not a surface that HAPPENS to be opened by the FAB — it is the
// FAB (#234). The shell drops the FAB the moment this opens and gets it back
// when it folds; the panel unfolds DOWNWARD out of the app bar's own edge
// rather than up out of the corner, because that is the edge it now belongs to.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../store/stored.dart';
import 'composer_controller.dart';
import 'motion.dart';
import 'quick_add_bar.dart';

/// The phone's composer: the quick-add row and its close handle, unfolding
/// downward out of the app bar's bottom edge.
///
/// [unfold] is the host's own controller — 0 folded away, 1 fully open — so
/// open and close are the same motion played in both directions. The surface is
/// laid out at its FULL height throughout and revealed from the top (an [Align]
/// with a height factor, clipped): the composer's row never reflows mid-flight,
/// so nothing pops, jumps or overflows while the panel is short.
class TopComposerPanel extends ConsumerWidget {
  const TopComposerPanel({
    required this.controller,
    required this.unfold,
    required this.onClose,
    super.key,
  });

  /// The app's one composer.
  final ComposerController controller;

  /// How far the panel is unfolded: 0 folded into the bar, 1 fully open.
  final Animation<double> unfold;

  /// Fold the panel away (the handle's tap / drag / semantics action).
  final VoidCallback onClose;

  /// The radius the panel's bottom corners carry — the Material 3 sheet corner,
  /// on the two edges that are not against the app bar.
  static const double cornerRadius = 28;

  /// Hand the caret back to the composer after an action that stole it (a
  /// target pick, a submit, a paste offer) — but never onto a panel that is on
  /// its way out, whose IME would then have nothing left to retract it (#233).
  void _refocus(BuildContext context, WidgetRef ref) {
    if (!context.mounted || !ref.read(composerOpenProvider)) return;
    ref.read(quickAddFocusProvider).requestFocus();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    // The panel watches the LIVE list set (#274): it is built once and outlives
    // every submit, so a list value captured when it opened goes stale the
    // moment a sync pull moves it — and the destination picker then offers
    // lists that no longer exist while hiding one that does.
    final lists =
        ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    final focusNode = ref.watch(quickAddFocusProvider);
    // BOTH composer surfaces render from the ONE draft (#264): observing it
    // here means the panel re-renders whenever the aim moves, from whichever
    // surface moved it.
    final surface = ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Material(
        // Its own surface tone, a step off the list behind it: the panel is a
        // thing standing ON the list, not a row of it.
        color: colors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(cornerRadius),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QuickAddBar(
              controller: controller.text,
              focusNode: focusNode,
              dateIgnoredFor: controller.draft.dateIgnoredFor,
              pickedDue: controller.draft.pickedDue,
              lists: lists,
              targetListId: controller.targetListIn(lists),
              onTargetChanged: (id) {
                controller.aimAtList(id);
                _refocus(context, ref);
              },
              onSubmit: () {
                controller.submit();
                // Rapid entry: the field cleared; keep composing.
                _refocus(context, ref);
              },
              onAddPastedLines: (raw) {
                controller.addPastedLines(raw);
                _refocus(context, ref);
              },
              onDismissPreview: () {
                controller.dismissPreview();
                _refocus(context, ref);
              },
              onSetDue: (move) {
                controller.setDue(move);
                _refocus(context, ref);
              },
              onPickDue: () async {
                await controller.pickDue(context);
                // Only while the panel survived the calendar the user was
                // just in.
                if (context.mounted) _refocus(context, ref);
              },
            ),
            _CloseHandle(onClose: onClose),
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: unfold,
      // Built once per rebuild: the row inside must not be re-laid-out on every
      // frame of the unfold, and it is not — only the clip over it moves.
      child: surface,
      builder: (context, surface) => ClipRect(
        // The key names the VISIBLE extent of the composer — the clip, not the
        // surface inside it — so a test that asks where the composer is gets
        // the band the user can actually see, mid-unfold as well as at rest.
        key: const Key('composer-surface'),
        child: Align(
          // Anchored to the edge it grows out of: the panel's top stays on the
          // app bar's bottom and its own bottom edge travels down the list.
          alignment: Alignment.topCenter,
          heightFactor: MotionCurves.standard
              .transform(unfold.value.clamp(0.0, 1.0))
              .clamp(0.0, 1.0),
          child: surface,
        ),
      ),
    );
  }
}

/// The panel's bottom edge: a Material drag handle that actually closes the
/// thing it is drawn on. A tap folds the panel away; so does dragging it back
/// up towards the bar it came out of — the gesture the shape invites.
///
/// Metrics, colour and target size are the Material sheet handle's (a 48dp
/// target around a 32×4 bar), so it reads as "this surface is temporary"
/// without a second glyph on the composer's single, already-crowded row.
class _CloseHandle extends StatefulWidget {
  const _CloseHandle({required this.onClose});

  final VoidCallback onClose;

  /// How far the handle must travel UP before a release closes the panel —
  /// far enough that a jittery tap is still a tap.
  static const double dragThreshold = 24;

  /// The upward fling speed that closes it whatever the distance.
  static const double flingVelocity = 100;

  @override
  State<_CloseHandle> createState() => _CloseHandleState();
}

class _CloseHandleState extends State<_CloseHandle> {
  /// Distance travelled in the current drag; negative is upward.
  double _travelled = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = theme.bottomSheetTheme.dragHandleSize ?? const Size(32, 4);
    return Semantics(
      label: 'Close the composer',
      container: true,
      button: true,
      onTap: widget.onClose,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        onVerticalDragStart: (_) => _travelled = 0,
        onVerticalDragUpdate: (d) => _travelled += d.primaryDelta ?? 0,
        onVerticalDragEnd: (d) {
          final velocity = d.primaryVelocity ?? 0;
          if (velocity < -_CloseHandle.flingVelocity ||
              _travelled < -_CloseHandle.dragThreshold) {
            widget.onClose();
          }
        },
        child: SizedBox(
          key: const Key('composer-close-handle'),
          height: kMinInteractiveDimension,
          width: double.infinity,
          child: Center(
            child: Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size.height / 2),
                color:
                    theme.bottomSheetTheme.dragHandleColor ??
                    theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
