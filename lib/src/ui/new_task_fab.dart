// The touch creation affordance (#234) — ONE entity in two halves: the FAB the
// thumb reaches for, and the composer it TURNS INTO.
//
// The defect this replaces was structural, not cosmetic. The composer was a
// modal sheet on the shell's NESTED navigator (go_router's ShellRoute) while
// the FAB belonged to the outer compact Scaffold, so the "modal" rendered under
// the FAB and the FAB covered the composer's own submit button — creating a
// task on a phone was impossible. Fixing the z-order alone would leave the same
// class of bug one refactor away, so the two surfaces became one:
//
//   • [NewTaskFab] is present only while there is nothing to obstruct. It
//     retreats while the list scrolls down, while a keyboard is up (a raised
//     keyboard means something has focus — a "new task" button is noise then,
//     and a stale inset used to leave it floating mid-screen, #233), and while
//     the composer is open. It is truly ABSENT then, not merely transparent:
//     nothing to overlap, nothing to tap by accident.
//   • the composer it opens is a [TopComposerPanel] pinned under the app bar
//     (#304), not a sheet over the thumb: it unfolds downward out of the bar's
//     own edge, pushes the list down instead of covering it, and lands where
//     the rows it creates land. Nothing of the shell is left on top of it,
//     because it is part of the pane rather than a route over it.
//
// Nothing here is desktop-facing: the fine-pointer creation affordance is the
// always-visible quick-add bar (#216), and the shell never builds a FAB there.

import 'package:flutter/material.dart';

import 'motion.dart';

/// The "new task" floating action button — the phone's one creation affordance.
///
/// [visible] is the whole contract: false and it scales away and leaves the
/// tree, true and it springs back. The caller decides WHY (scroll, keyboard,
/// open composer); this widget only owns the motion and the fact that a hidden
/// FAB is a FAB that no longer exists.
class NewTaskFab extends StatefulWidget {
  const NewTaskFab({required this.visible, required this.onPressed, super.key});

  /// Whether the FAB belongs on screen right now.
  final bool visible;

  /// Open the composer (the shell bumps the new-task request).
  final VoidCallback onPressed;

  /// The diameter of a Material 3 FAB.
  static const double size = 56;

  /// Its margin from the screen edges — the [Scaffold] uses the same value.
  static const double margin = 16;

  /// The bottom padding a scrollable owes the FAB so the LAST row is never
  /// stuck under it — neither read nor tappable. The FAB
  /// occupies [size] plus its margin above the bottom nav; the second margin is
  /// the breathing room between the row and the FAB.
  static const double clearance = size + margin * 2;

  /// How long the FAB takes to leave or return — and, because the shell's app
  /// bar leaves at the same pace, the span the whole compact chrome shares.
  /// (Why it is shorter than the composer's own unfold:
  /// [MotionDurations.fabTransition].)
  static const Duration transition = MotionDurations.fabTransition;

  @override
  State<NewTaskFab> createState() => _NewTaskFabState();
}

class _NewTaskFabState extends State<NewTaskFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NewTaskFab.transition,
    value: widget.visible ? 1 : 0,
  );

  /// A slight overshoot on the way in (the FAB "lands"), a plain ease out on
  /// the way back — leaving should never draw attention to itself.
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: MotionCurves.fabLanding,
    reverseCurve: MotionCurves.exit,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" (Android) / reduced motion: the FAB still leaves and
    // returns, it just stops travelling to get there — the same rule the app
    // bar beside it already follows.
    _controller.duration = Motion.of(context).resolve(NewTaskFab.transition);
  }

  @override
  void didUpdateWidget(covariant NewTaskFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    widget.visible ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      // Built once: the FAB itself never changes, only the transform over it.
      child: FloatingActionButton(
        tooltip: 'New task',
        onPressed: widget.onPressed,
        child: const Icon(Icons.add),
      ),
      builder: (context, fab) {
        // Gone means GONE. A scaled-to-nothing FAB is still a widget sitting
        // over the composer — still hit-testable, still in the semantics tree,
        // still the bug this exists to prevent.
        if (_controller.isDismissed) return const SizedBox.shrink();
        // At rest it is a BARE [FloatingActionButton] — no transform, no
        // opacity layer, nothing between the theme and the pixels (the motion
        // wrappers alter antialiasing enough to move a pixel in a golden). They
        // exist only while it is actually moving.
        if (_controller.isCompleted) return fab!;
        // Scale AND fade: a FAB shrunk to a tenth is still a small opaque
        // lozenge sitting over the composer growing underneath it.
        return Opacity(
          opacity: _controller.value,
          child: Transform.scale(scale: _scale.value, child: fab),
        );
      },
    );
  }
}
