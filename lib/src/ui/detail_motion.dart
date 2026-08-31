// How a task detail ARRIVES and how it LEAVES (#253).
//
// Opening a task used to be a hard cut on both layouts. On the phone the detail
// simply replaced the list; on the desktop the pane popped into the layout and
// the list snapped to its new width. Either way the user lost the thread of
// WHICH task they had just opened — the one question the transition exists to
// answer.
//
// This file holds the three pieces that answer it, and nothing else:
//
//   • [DetailOriginScope] / [DetailOriginController] — where a compact
//     transform grows FROM. A row records its own rect the moment its tap
//     opens the detail, tagged with the task id, so an open that did NOT come
//     from a row (a search jump onto a subtask, a restored URL, the detail's
//     own prev/next) is recognised as having no container and simply fades.
//
//   • [DetailContainerTransform] — the Material 3 container transform itself:
//     the tapped row's rect becoming the whole screen, contents fading in
//     behind the growing surface, and the exact reverse on the way out.
//
//   • [DetailRevealScope] — how far the EXPANDED layout's pane has arrived, so
//     the #221 open-row highlight can fade in as the pane lands instead of
//     jumping ahead of it.
//
// Every span and curve comes from motion.dart (#250), including the
// reduced-motion rule: with "remove animations" on, each controller's duration
// is zero and the end state arrives in the same frame — the detail is simply
// open, or simply gone.
//
// One shape rule runs through all of it, the same one [RowFold] follows: the
// widget tree is the SAME at every progress value, including at rest. A wrapper
// that appears and disappears around the detail panel would tear it down and
// rebuild it at the exact moment its motion finished — killing the field
// controllers and the scroll offset it had just been given. At rest every
// wrapper here is a pass-through (clip [Clip.none], opacity 1, an identity
// offset), so a settled layout paints exactly as one with no motion at all.

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';

import 'motion.dart';

/// The row a compact container transform grows out of: the task it belongs to
/// and the rect it occupied on screen when it was tapped.
@immutable
class DetailOrigin {
  const DetailOrigin({required this.taskId, required this.rect});

  /// The task whose row this is. The transform uses the rect ONLY for this
  /// task, so a stale origin can never be replayed under a different one.
  final String taskId;

  /// The row's rect in GLOBAL (screen) coordinates — the reader converts into
  /// its own space, because only the reader knows where it sits.
  final Rect rect;
}

/// Holds the most recent [DetailOrigin]. One per app, published through
/// [DetailOriginScope]; a list row writes it, the compact detail reads it.
class DetailOriginController extends ValueNotifier<DetailOrigin?> {
  DetailOriginController() : super(null);

  /// Record the rect [rowContext] paints into as the origin for [taskId].
  ///
  /// Called from the row's own open handler, BEFORE the navigation, while the
  /// row is still on screen and laid out. A context with no render object yet
  /// (or one detached mid-frame) records nothing rather than a wrong rect.
  void report(String taskId, BuildContext rowContext) {
    final box = rowContext.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    value = DetailOrigin(
      taskId: taskId,
      rect: box.localToGlobal(Offset.zero) & box.size,
    );
  }

  /// The global rect to grow from for [taskId], or `null` when the open did not
  /// come from that task's row.
  Rect? rectFor(String? taskId) {
    final origin = value;
    if (taskId == null || origin == null || origin.taskId != taskId) {
      return null;
    }
    return origin.rect;
  }
}

/// Publishes the app's one [DetailOriginController] to the list rows that write
/// it and the compact detail that reads it.
///
/// Deliberately an [InheritedWidget] and not a provider: the scaffold that
/// reads it is mounted with no `ProviderScope` in goldens and layout tests, and
/// an absent scope is a meaningful answer — no origin, so no container to come
/// out of, so the detail simply fades in.
class DetailOriginScope extends InheritedWidget {
  const DetailOriginScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final DetailOriginController controller;

  /// The controller in scope, or `null` outside one.
  ///
  /// Reads without registering a dependency: the controller instance never
  /// changes, so a dependency could only ever cost rebuilds and never deliver
  /// one that mattered.
  static DetailOriginController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DetailOriginScope>()?.controller;

  @override
  bool updateShouldNotify(DetailOriginScope oldWidget) =>
      oldWidget.controller != controller;
}

/// How far the expanded layout's detail pane has arrived, 0…1 — published over
/// the LIST so the #221 open-row highlight can wait for it.
///
/// Outside a scope the answer is 1: a row with no pane animating above it (the
/// compact layout, an isolated widget test) shows the highlight it was told to
/// show, immediately.
class DetailRevealScope extends InheritedNotifier<Animation<double>> {
  const DetailRevealScope({
    required Animation<double> reveal,
    required super.child,
    super.key,
  }) : super(notifier: reveal);

  /// The current reveal for [context]. Registers a dependency, so call it ONLY
  /// from the row that is actually open — every other row would then rebuild
  /// for a value it does not use.
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DetailRevealScope>()
          ?.notifier
          ?.value
          .clamp(0.0, 1.0) ??
      1.0;
}

/// The compact layout's container transform (#253): the tapped row's rect
/// becoming the full-screen detail, and the reverse on the way back.
///
/// The child is always LAID OUT at full size and clipped to the animating rect,
/// never resized into it: a detail panel re-laid-out sixty times a second would
/// reflow its text on every frame of the transition, which is both expensive and
/// visibly wrong. What moves is the clip and the fill behind it.
class DetailContainerTransform extends StatelessWidget {
  const DetailContainerTransform({
    required this.progress,
    required this.origin,
    required this.child,
    super.key,
  });

  /// How far the row has become the detail: 0 = the row's own rect, 1 = the
  /// whole screen. Already curved by the caller.
  final double progress;

  /// The row's rect IN THIS WIDGET'S OWN COORDINATE SPACE, or `null` when there
  /// is no row to come out of. With no origin the surface is full-size from the
  /// first frame and only its contents fade — an honest "this did not come from
  /// anywhere on screen" rather than a container invented for the occasion.
  final Rect? origin;

  final Widget child;

  /// The corner radius the surface carries at [progress] 0 — a card's corners,
  /// squaring off as it takes the screen.
  static const double startRadius = 12;

  /// The animating surface. A test measures its rect through this key.
  static const Key surfaceKey = Key('detail-container-surface');

  /// The surface's CONTENTS, which fade in behind it. A test reads how far in
  /// they are through this key.
  static const Key contentsKey = Key('detail-container-contents');

  /// Where the contents start fading in. The container has to read as a
  /// container for a moment before it fills with the detail, or the transform
  /// is a cross-fade that happens to move.
  static const double _contentFadeStart = 0.3;

  /// Where the surface's own FILL finishes arriving. For that first instant the
  /// container is still the size of the row and the row is still underneath it,
  /// so an opaque fill from frame zero would blank the row out before it had
  /// begun to move. Fading the fill in over a sliver of the span lets the row
  /// become the card instead of being replaced by one.
  static const double _fillFadeEnd = 0.15;

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0);
    final settled = t >= 1;
    // The surface fill. At rest this paints the same colour the detail's own
    // Scaffold paints over it, so a settled screen is pixel-for-pixel what it
    // was before this widget existed; while the surface is small it is the ONLY
    // thing keeping the growing container opaque over the list behind it.
    final fill = Theme.of(context).scaffoldBackgroundColor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = Offset.zero & constraints.biggest;
        final rect = settled ? full : Rect.lerp(origin ?? full, full, t)!;
        final contents = ((t - _contentFadeStart) / (1 - _contentFadeStart))
            .clamp(0.0, 1.0);
        final fillIn = (t / _fillFadeEnd).clamp(0.0, 1.0);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(
                key: surfaceKey,
                // Clip.none at rest: a full-screen antialiased clip of the
                // screen's own bounds is a no-op that still costs a layer, and
                // its edge pixels are not worth betting a golden on.
                clipBehavior: settled ? Clip.none : Clip.antiAlias,
                borderRadius: BorderRadius.circular(startRadius * (1 - t)),
                child: ColoredBox(
                  color: fill.withValues(alpha: fill.a * fillIn),
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: full.width,
                    maxWidth: full.width,
                    minHeight: full.height,
                    maxHeight: full.height,
                    child: IgnorePointer(
                      // Mid-transform the app is between two states; a tap on
                      // a surface that is still travelling would land on
                      // whatever happened to be under the finger by the time
                      // it arrived.
                      ignoring: !settled,
                      child: Opacity(
                        key: contentsKey,
                        opacity: contents,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The detail's prev/next step, as a short shared-axis slide (#253).
///
/// Prev and Next are movement along ONE axis — the view's own ordering — so the
/// outgoing task leaves towards the side the incoming one came from, and the
/// pair reads as a step through a sequence rather than as two unrelated
/// screens. A step to a task with no place in that ordering (a subtask reached
/// from the panel's own links) has no direction to slide along and cross-fades
/// instead.
///
/// The outgoing panel keeps its element while it leaves — [AnimatedSwitcher]
/// holds it by its own key — so nothing is torn down and rebuilt just to
/// animate away. The pending-edit registry is identity-guarded for exactly this
/// (#183), so the arriving panel's registration is never dropped by the
/// departing one's.
class DetailSharedAxis extends StatefulWidget {
  const DetailSharedAxis({required this.slot, required this.child, super.key});

  /// The open task's position in the view's visible ordering — Next raises it,
  /// Previous lowers it. `null` for a task with no place in the ordering.
  final int? slot;

  final Widget child;

  /// How far a panel travels as it comes or goes. Short on purpose: a shared
  /// axis says "the same kind of thing, one step over", and a panel that
  /// crosses the screen says "somewhere else entirely".
  static const double travel = 32;

  @override
  State<DetailSharedAxis> createState() => _DetailSharedAxisState();
}

class _DetailSharedAxisState extends State<DetailSharedAxis> {
  /// +1 = a step towards the end of the ordering (Next), -1 = towards its start
  /// (Previous), 0 = a step with no direction, which cross-fades.
  double _direction = 0;

  Duration _span = MotionDurations.medium;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _span = Motion.of(context).medium;
  }

  @override
  void didUpdateWidget(DetailSharedAxis old) {
    super.didUpdateWidget(old);
    if (Widget.canUpdate(old.child, widget.child)) return;
    final from = old.slot;
    final to = widget.slot;
    _direction = (from == null || to == null || from == to)
        ? 0
        : (to > from ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _span,
      reverseDuration: _span,
      switchInCurve: MotionCurves.enter,
      switchOutCurve: MotionCurves.exit,
      // The framework's default layout builder stacks children LOOSELY, which
      // would let the detail panel shrink-wrap to its intrinsic height. The
      // panel fills its host, transitioning or not.
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => _SharedAxisSlide(
        animation: animation,
        // Read at PAINT time, not here: this builder runs once per panel, when
        // that panel arrives, and the panel that is leaving needs the direction
        // of the step that is displacing it — which is only known later.
        direction: () => _direction,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// One panel's half of the shared axis: it slides in from [direction] and, when
/// its own animation runs backwards, out to the opposite side.
class _SharedAxisSlide extends StatelessWidget {
  const _SharedAxisSlide({
    required this.animation,
    required this.direction,
    required this.child,
  });

  final Animation<double> animation;
  final double Function() direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final leaving = animation.status == AnimationStatus.reverse;
        final away = 1 - animation.value.clamp(0.0, 1.0);
        final dx =
            (leaving ? -direction() : direction()) *
            away *
            DetailSharedAxis.travel;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Opacity(
            opacity: animation.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
    );
  }
}
