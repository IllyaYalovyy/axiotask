// How the app moves from one VIEW to another (#254).
//
// Switching views used to be a hard cut: the frame after a tap on the bottom
// bar the old list was gone and a different one was in its place. That is the
// same picture a sync pull paints when it rewrites the list, so the one thing
// the transition exists to say — the USER moved, and this is which way they
// went — was never said at all.
//
// Two transitions, chosen by whether the step has a direction to honour:
//
//   • [ViewSwitch] with a SLOT on both sides — the bottom bar's five smart
//     views are an ordered set, so a step along it is movement along an axis:
//     the outgoing list leaves towards the destination being selected and the
//     arriving one comes in from the opposite edge (Material's shared axis X).
//     Index 0 → 1 leaves LEFT; 1 → 0 leaves RIGHT. [MotionDurations.long].
//
//   • [ViewSwitch] with no slot on one side, or no bar at all — a list picked
//     out of the drawer is not one of the bar's destinations, and the expanded
//     layout's sidebar has no bar behind it. Neither has a spatial order to
//     honour, so the views fade THROUGH each other: the outgoing one is gone
//     before the arriving one begins, with a moment of neither in between.
//     [MotionDurations.medium], and nothing moves a pixel.
//
// "Is there a bar" is answered by the presence of [CompactChromeScope] — the
// signal the compact shell already publishes to say "I own the app bar this
// list's actions go into" (compact_chrome.dart). It is exactly the shell that
// has a bottom bar, so there is no second breakpoint to keep in step with the
// scaffold's own.
//
// [ViewTitle] carries the app bar's label across the same change, so the title
// arrives with its content instead of snapping a frame ahead of it.
//
// The shape rule from #251/#253 holds here too: the tree is the SAME at every
// point of the transition, including at rest, where the translation is zero and
// the opacity is one. A wrapper that came and went would tear the list pane
// down and rebuild it at the exact moment its motion finished — losing the
// scroll offset, the inline editors and the row state it had just been given —
// and would move a settled pixel, which the at-rest goldens would (rightly)
// refuse.

import 'package:flutter/widgets.dart';

import 'compact_chrome.dart';
import 'motion.dart';

/// The list pane of the active view, transitioning when the view changes.
///
/// [slot] is the view's index in the bottom bar's destinations, or `null` for a
/// view the bar does not carry (a list). The direction of travel is the
/// difference between the outgoing and incoming slots; with no pair of slots
/// there is no direction, and the views fade through instead.
class ViewSwitch extends StatefulWidget {
  const ViewSwitch({required this.slot, required this.child, super.key});

  /// The bottom-bar index of the view now showing; `null` when the active view
  /// is not one of the bar's destinations.
  final int? slot;

  /// The view's pane. Its KEY is what identifies the view: a rebuild carrying
  /// the same key is the same view redrawing (a task selected, a sync landing),
  /// and only a different key is a switch.
  final Widget child;

  /// How far a pane travels along the shared axis. Short on purpose: the step
  /// says "one destination over", not "somewhere else entirely" — and a whole
  /// screen of rows sliding a long way is a performance, which the motion
  /// ruling explicitly ruled out.
  static const double travel = 32;

  /// Where the outgoing view has finished fading, as a fraction of the span:
  /// past it the arriving one starts. The gap between the two is what makes a
  /// fade-through read as one view replacing another rather than as two views
  /// briefly superimposed.
  static const double fadeThrough = 0.35;

  @override
  State<ViewSwitch> createState() => _ViewSwitchState();
}

class _ViewSwitchState extends State<ViewSwitch> {
  /// +1 = a step towards a later destination, -1 = towards an earlier one,
  /// 0 = a step with no direction, which fades through.
  double _direction = 0;

  Motion _motion = Motion.full;

  /// Whether a bar with an ordered set of destinations is hosting this pane at
  /// all — the expanded layout has none, so nothing there can have a direction.
  bool _spatial = false;

  Duration _span = MotionDurations.medium;

  Duration get _resolved => _motion.resolve(
    _direction == 0 ? MotionDurations.medium : MotionDurations.long,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = Motion.of(context);
    _spatial = CompactChromeScope.maybeOf(context) != null;
    _span = _resolved;
  }

  @override
  void didUpdateWidget(ViewSwitch old) {
    super.didUpdateWidget(old);
    // Same view, redrawing — a task selected, a sync landing, a rename. Only a
    // pane with a different key is a switch, and only a switch has a direction.
    if (Widget.canUpdate(old.child, widget.child)) return;
    final from = old.slot;
    final to = widget.slot;
    _direction = (!_spatial || from == null || to == null || from == to)
        ? 0
        : (to > from ? 1 : -1);
    _span = _resolved;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _span,
      reverseDuration: _span,
      // The switch curves are left LINEAR (the default): every curve this
      // transition uses is applied inside [_ViewPane], where the fade and the
      // travel are shaped separately — the fade has a gap in the middle of it,
      // the travel does not.
      layoutBuilder: (current, previous) => Stack(
        // The panes fill their host, transitioning or not — the framework's
        // default is a LOOSE, centred stack, which would let a list pane
        // shrink-wrap mid-switch and re-lay-out every row in it.
        fit: StackFit.expand,
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => _ViewPane(
        animation: animation,
        // Read at PAINT time: this builder runs when a pane ARRIVES, and the
        // pane that is leaving needs the direction of the step displacing it,
        // which is only known later.
        direction: () => _direction,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// One view's half of the transition: it arrives from [direction] and, when its
/// own animation runs backwards, leaves towards the opposite side.
///
/// At rest — the state every golden is taken in — this is a zero translation
/// over a fully opaque child: the same tree, painting the same pixels, as if
/// nothing here existed.
class _ViewPane extends StatelessWidget {
  const _ViewPane({
    required this.animation,
    required this.direction,
    required this.child,
  });

  final Animation<double> animation;

  /// +1, -1 or 0 (fade-through), read at paint time.
  final double Function() direction;

  final Widget child;

  /// The outgoing view's fade: it is gone by [ViewSwitch.fadeThrough] of the
  /// span, accelerating away.
  static const Curve _out = Interval(
    1 - ViewSwitch.fadeThrough,
    1,
    curve: MotionCurves.exit,
  );

  /// The arriving view's fade: it starts where the outgoing one finished.
  static const Curve _in = Interval(
    ViewSwitch.fadeThrough,
    1,
    curve: MotionCurves.enter,
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final leaving = animation.status == AnimationStatus.reverse;
        final t = animation.value.clamp(0.0, 1.0);
        final away = 1 - MotionCurves.standard.transform(t);
        final dx =
            (leaving ? -direction() : direction()) * away * ViewSwitch.travel;
        final opacity = leaving ? _out.transform(t) : _in.transform(t);
        return IgnorePointer(
          // A pane answers taps exactly when it is on screen for the user to
          // tap: the view being LEFT never does (during a slide its far edge
          // shows past the arriving pane, and a tap there would open a row out
          // of the view you just left), and neither does a pane that is not
          // painting yet. The arriving pane does, from the first pixel it
          // shows — a hit test travels through the same translation the paint
          // does, so a row lands where it looks like it is, and switching
          // views costs the user no dead moment before the list is usable.
          ignoring: leaving || opacity <= 0,
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Opacity(opacity: opacity, child: child),
          ),
        );
      },
    );
  }
}

/// The compact app bar's title, cross-fading as the view changes (#254).
///
/// A cross-fade rather than the pane's fade-through: two words in the same
/// place, one becoming the other, is a change of LABEL — a gap in the middle of
/// it would read as the title having gone missing. It starts on the frame the
/// pane transition and the nav-bar pill start on, because all three are driven
/// by the same rebuild.
class ViewTitle extends StatelessWidget {
  const ViewTitle(this.title, {super.key});

  /// The active view's name.
  final String title;

  @override
  Widget build(BuildContext context) {
    final span = Motion.of(context).medium;
    return AnimatedSwitcher(
      duration: span,
      reverseDuration: span,
      switchInCurve: MotionCurves.enter,
      switchOutCurve: MotionCurves.exit,
      // Start-aligned: an app bar title grows to the end, so the two labels
      // share their first letter's position rather than sliding past each
      // other as the wider one sizes the stack.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previous, ?current],
      ),
      child: Text(
        title,
        key: ValueKey<String>(title),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
