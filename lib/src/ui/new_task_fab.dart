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
//   • [ComposerMorph] is the composer's own surface, and it UNFOLDS out of the
//     corner the FAB just left — one continuous motion, not two surfaces
//     trading places. Its route goes on the ROOT navigator, above every piece
//     of shell furniture (the FAB, the NavigationBar); the toast overlay, which
//     is mounted above the whole Navigator, still out-stacks it (F19).
//
// Nothing here is desktop-facing: the fine-pointer creation affordance is the
// always-visible quick-add bar (#216), and the shell never builds a FAB there.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

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
  /// (Why it is shorter than the composer's own route transition:
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

/// The composer's surface: the sheet the FAB turns into.
///
/// [animation] is the sheet route's own animation, so open and close are the
/// same motion played in both directions. The surface starts as a
/// [NewTaskFab.size] rounded blob at the bottom END corner — where the FAB was
/// standing — and unfolds across the screen while the route slides it up.
///
/// The unfolding is a WIDTH change over a child that is always laid out at full
/// width (an [Align] with a width factor, clipped): the composer's row never
/// reflows mid-flight, so nothing pops, jumps, or overflows while the surface
/// is narrow.
class ComposerMorph extends StatefulWidget {
  const ComposerMorph({
    required this.animation,
    required this.onDismiss,
    required this.onFoldStart,
    required this.child,
    super.key,
  });

  /// The sheet route's transition animation.
  final Animation<double> animation;

  /// The user asked to close the composer (the drag handle's tap / its
  /// semantics action) — pop the sheet.
  final VoidCallback onDismiss;

  /// The sheet has BEGUN folding away. Fired once, on the frame the route
  /// starts reversing: the pop future does not complete until the fold has
  /// finished, which would leave the corner empty for the whole exit before the
  /// FAB returned to it.
  final VoidCallback onFoldStart;

  /// The composer itself.
  final Widget child;

  /// The Material 3 modal-sheet corner radius.
  static const double sheetRadius = 28;

  @override
  State<ComposerMorph> createState() => _ComposerMorphState();
}

class _ComposerMorphState extends State<ComposerMorph> {
  /// Guards [ComposerMorph.onFoldStart] against a second fire (a fold the user
  /// drags back open and lets go of again).
  bool _announcedFold = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse || _announcedFold) return;
    _announcedFold = true;
    widget.onFoldStart();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The width the composer unfolds TO. Finite in every real layout (the
        // sheet is laid out against the screen); the fallback keeps a
        // pathological unbounded constraint from producing a NaN factor.
        final full = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : NewTaskFab.size;
        return AnimatedBuilder(
          animation: widget.animation,
          child: Material(
            // The M3 modal-sheet surface, drawn here rather than by the route:
            // the route's own background would pop in full-width behind the
            // morph instead of being part of it.
            color: colors.surfaceContainerLow,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DragHandle(onDismiss: widget.onDismiss),
                widget.child,
              ],
            ),
          ),
          builder: (context, surface) {
            final t = MotionCurves.enter.transform(
              widget.animation.value.clamp(0.0, 1.0),
            );
            final width = lerpDouble(NewTaskFab.size, full, t)!;
            // The blob sits exactly where the FAB stood — inset by the FAB's
            // margin — and that inset melts away as it becomes the sheet. The
            // inset is also what the surface is laid out inside, so the width
            // factor is measured against THAT, not against the screen: at rest
            // the visible surface is one FAB wide, to the pixel.
            final inset = lerpDouble(NewTaskFab.margin, 0, t)!;
            final laidOut = math.max(full - inset, 1.0);
            final radius = Radius.circular(
              lerpDouble(NewTaskFab.size / 2, ComposerMorph.sheetRadius, t)!,
            );
            // The OUTER align keeps the sheet full-width (a shrink-wrapped
            // sheet would be centred by the route's own constraints, and the
            // composer would unfold out of thin air in the middle of the
            // screen); the inner one is the unfold itself.
            return Align(
              alignment: AlignmentDirectional.bottomEnd,
              heightFactor: 1,
              child: Padding(
                padding: EdgeInsetsDirectional.only(end: inset),
                child: ClipRRect(
                  key: const Key('composer-surface'),
                  borderRadius: BorderRadius.only(
                    topLeft: radius,
                    topRight: radius,
                    // Square at rest: the sheet's bottom edge is the screen's.
                    bottomLeft: Radius.circular(radius.x * (1 - t)),
                    bottomRight: Radius.circular(radius.x * (1 - t)),
                  ),
                  child: Align(
                    // Anchored to the corner it grew out of; the child keeps
                    // its full width and is simply not all visible yet.
                    alignment: AlignmentDirectional.bottomEnd,
                    widthFactor: (width / laidOut).clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: surface,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The sheet's drag handle — ours rather than the route's, so it is part of the
/// morphing surface instead of a second thing appearing above it. Same metrics,
/// colour and semantics as the Material default (a 48dp target around a 32×4
/// bar, labelled with the platform's dismiss label).
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = theme.bottomSheetTheme.dragHandleSize ?? const Size(32, 4);
    return Semantics(
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      container: true,
      button: true,
      onTap: onDismiss,
      child: SizedBox(
        width: math.max(size.width, kMinInteractiveDimension),
        height: math.max(size.height, kMinInteractiveDimension),
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
    );
  }
}
