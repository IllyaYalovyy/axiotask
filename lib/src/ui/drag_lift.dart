// The weight a dragged row carries (#256) — the ONE lift in this app.
//
// Before this, a reorder used the bare reorderable's default: the row under the
// finger was swapped for a flat canvas rectangle with a shadow that appeared
// from nowhere. It looked exactly like the rows it was travelling over, so
// nothing said the row had DETACHED, and nothing said it had LANDED — "it feels
// like moving a spreadsheet cell".
//
// A lifted row is a surface that came off the list, so it says so the way
// Material 3 says it — all three at once, because any one of them alone reads
// as a rendering glitch rather than as depth:
//
//   elevation  0 → [dragLiftElevation], M3's level 3: the elevation the spec
//              gives a card in its DRAGGED state;
//   scale      1 → [dragLiftScale], barely two percent. Enough that the row
//              overlaps its neighbours' edges, small enough that the text
//              inside it does not visibly resize under the finger;
//   surface    the tonal tint that elevation implies, so the lifted row is a
//              different SURFACE and not merely the same one with a shadow.
//
// The spans are deliberately asymmetric. The lift is [Motion.short]: the row
// has to be off the list by the time the eye gets to it, or the gesture reads
// as laggy. The settle is [Motion.medium], slow enough to be seen — it is the
// only thing on screen that says the drop is over, and the row it belongs to is
// standing still by then. Neither span is the reorderable's own 250ms proxy
// animation, which we do not own and which also carries the row's travel back
// to its slot.
//
// Reduced motion resolves both to zero. The weight itself STAYS: it is the
// affordance ("this row is the one you are holding"), not the decoration. Only
// the travel to it goes away.
//
// One decorator, both drags — the task list and the sidebar's lists — so a row
// lifts exactly one way in this app.

import 'package:flutter/material.dart';

import 'motion.dart';

/// The elevation a fully lifted row rests at: Material 3's level 3, the
/// elevation the spec gives a card in its dragged state.
const double dragLiftElevation = 6;

/// How much larger a fully lifted row is than the slot it left.
const double dragLiftScale = 1.02;

/// The lifted surface — where the elevation and the tonal tint are painted.
const Key dragLiftSurfaceKey = Key('drag-lift-surface');

/// The transform that scales the lifted surface.
const Key dragLiftScaleKey = Key('drag-lift-scale');

/// The proxy decorator every reorderable in axiotask passes for
/// `proxyDecorator` — [SliverReorderableList] supplies none at all, and
/// [ReorderableListView]'s default is the flat rectangle described above.
Widget dragLiftProxyDecorator(
  Widget child,
  int index,
  Animation<double> drag,
) => DragLift(drag: drag, child: child);

/// Gives [child] the weight of a row that has been picked up, for as long as
/// [drag] says it is off the list.
///
/// [drag] is the reorderable's own proxy animation: it runs forward while the
/// row is held and reverses the moment the finger lifts. Only its DIRECTION is
/// read — the lift and the settle run on this widget's own controller, at this
/// app's own spans, so the two ends of the gesture can differ (see the file
/// header) and so reduced motion is honoured here rather than inside a
/// framework animation we do not own.
class DragLift extends StatefulWidget {
  const DragLift({required this.drag, required this.child, super.key});

  /// The reorderable's proxy animation — forward while held, reverse on drop.
  final Animation<double> drag;

  final Widget child;

  @override
  State<DragLift> createState() => _DragLiftState();
}

class _DragLiftState extends State<DragLift>
    with SingleTickerProviderStateMixin {
  // 0 = resting in the list, 1 = fully lifted. Starts at 0 even though the row
  // is already off the list by the time this builds: the lift is a motion the
  // user watches begin, not a state the proxy appears in.
  late final AnimationController _lift = AnimationController(vsync: this);

  bool _dropping = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.drag.addStatusListener(_onDrag);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than in initState: the spans depend on the reduced-motion
    // MediaQuery, which cannot be read before dependencies are available.
    if (_started) return;
    _started = true;
    _run();
  }

  @override
  void dispose() {
    // The reorderable disposes its proxy animation before the overlay entry it
    // lives in is removed, so this may be a no-op by now; removing a listener
    // from a disposed animation is harmless and this must not depend on that
    // ordering.
    widget.drag.removeStatusListener(_onDrag);
    _lift.dispose();
    super.dispose();
  }

  void _onDrag(AnimationStatus status) {
    // The reverse IS the drop: the framework starts it the instant the finger
    // lifts, whether the row landed somewhere new or came back to where it
    // started. Both settle the same way — a cancelled drag is still a drag that
    // ended.
    final dropping = !status.isForwardOrCompleted;
    if (dropping == _dropping) return;
    _dropping = dropping;
    _run();
  }

  void _run() {
    final motion = Motion.of(context);
    final target = _dropping ? 0.0 : 1.0;
    // The settle may never outlive the surface it is painted on: the framework
    // tears the proxy down when its OWN drop animation reaches zero, and that is
    // a fraction — [Animation.value] — of its full span away, not always the
    // whole of it. A flick released before the row had finished lifting must
    // still land flat rather than blink out of the air mid-settle, so the settle
    // is shortened by the same fraction. A drag held for any normal length of
    // time releases from 1 and takes [Motion.medium] exactly.
    final span = _dropping ? motion.medium * widget.drag.value : motion.short;
    if (span <= Duration.zero) {
      _lift.value = target;
      return;
    }
    _lift.animateTo(
      target,
      duration: span,
      // Arriving under the finger, then leaving without asking to be watched.
      curve: _dropping ? MotionCurves.exit : MotionCurves.enter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lifted = ElevationOverlay.applySurfaceTint(
      scheme.surface,
      scheme.surfaceTint,
      dragLiftElevation,
    );
    return AnimatedBuilder(
      animation: _lift,
      // The row is built once and carried through every frame of the lift: a
      // rebuilt child would reset any state it holds while the finger is still
      // down.
      child: widget.child,
      builder: (context, child) {
        final t = _lift.value;
        return Transform.scale(
          key: dragLiftScaleKey,
          scale: 1 + (dragLiftScale - 1) * t,
          child: Material(
            key: dragLiftSurfaceKey,
            elevation: dragLiftElevation * t,
            color: Color.lerp(scheme.surface, lifted, t),
            child: child,
          ),
        );
      },
    );
  }
}
