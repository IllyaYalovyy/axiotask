// The list choreography (#251) — what a row DOES when it joins the list and
// when it leaves it.
//
// Before this, every change to the list was a reflow rather than feedback: a
// created task popped in, a deleted one was gone between two frames, a task
// rescheduled out of the current smart view simply was not there any more, Undo
// re-inserted with no trace, and a sync pull rewrote the list silently. The user
// made an edit and the layout changed; nothing said which row was theirs.
//
// Ratified with the explicit instruction "do not overdo it. It should not be too
// much", so this is deliberately a very short vocabulary — ONE motion per event,
// nothing decorative:
//
//   enter   fade-in + height-grow, [Motion.long], decelerating
//   leave   height-collapse + fade, [Motion.long], accelerating
//
// No scale, no bounce, no cross-fade, no shimmer. Two limits keep a large change
// from turning into a performance: at most [listMotionRowCap] rows move on any
// single change (a sync that rewrites two hundred rows must not ripple for
// seconds — the rest simply snap), and consecutive rows are offset by
// [MotionDurations.rowStagger], so the whole thing is over within
// [listMotionWindow].
//
// The fold itself is SHARED with the completion sequence (#241): a completion is
// the one departure this file does not own — it plays its own settle-then-
// collapse — and both reach for the same [RowFold] so a row folds exactly one
// way in this app.
//
// Reduced motion ("remove animations" on Android, reduced motion on desktop)
// resolves every span to zero, so the end state arrives in the same frame: a row
// is simply there, or simply gone.

import 'package:flutter/material.dart';

import 'motion.dart';

/// At most this many rows play a motion on one change. Everything else that
/// arrived or left in the same change snaps into its final place.
const int listMotionRowCap = 8;

/// The longest a single list change can take, end to end: the row motion itself
/// plus the stagger the last row the cap allows waits through. Nothing in the
/// list may still be moving after this.
final Duration listMotionWindow =
    MotionDurations.long + MotionDurations.rowStagger * listMotionRowCap;

/// The ONE way a list row's height opens or folds away (#241, #251): the item is
/// clipped to [factor] of its height, anchored at the top, so its neighbours
/// slide rather than jump.
///
/// At [factor] 0 the child is not built at all — a zero-height row that still
/// answered finds and hit tests would be a ghost in every sense.
///
/// Above zero the widget tree is the SAME shape at every factor, including 1.
/// That matters more than the two render objects it costs: a row whose wrapper
/// appears and disappears is a row Flutter tears down and rebuilds, so its
/// [State] — the inline-edit controller, the pressed/hover state, the completion
/// animation — would die the instant its arrival finished (the #249 contract).
/// At rest both objects are pure pass-throughs: the clip is [Clip.none] and the
/// height factor is exactly 1, so nothing about the settled layout or its
/// goldens changes.
class RowFold extends StatelessWidget {
  const RowFold({required this.factor, required this.child, super.key});

  /// How much of the row's height is showing, 0…1.
  final double factor;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (factor <= 0) return const SizedBox.shrink();
    return ClipRect(
      clipBehavior: factor >= 1 ? Clip.none : Clip.hardEdge,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: factor,
        child: child,
      ),
    );
  }
}

/// What a [RowMotion] is playing right now.
enum _Play {
  /// Nothing: the row is simply part of the list.
  rest,

  /// The row is growing and fading into place.
  entering,

  /// The row is folding and fading away.
  leaving,
}

/// Plays one row's arrival or departure (#251).
///
/// At rest it draws nothing of its own: the clip is [Clip.none], the height
/// factor is 1 and the opacity is 1, all of which paint the child straight
/// through — so a settled list looks (and measures) exactly like one with no
/// choreography at all.
///
/// [delay] is this row's place in the stagger; it is part of the animation, not
/// a timer, so nothing here can outlive the widget or leak into a test.
class RowMotion extends StatefulWidget {
  const RowMotion({
    required this.entering,
    required this.leaving,
    required this.delay,
    required this.onEntered,
    required this.onLeft,
    required this.child,
    super.key,
  });

  /// The row has just joined the list and should grow into place.
  final bool entering;

  /// The row has left the list and is on screen only to fold away.
  final bool leaving;

  /// How long this row waits before its motion starts.
  final Duration delay;

  /// Called once an arrival has finished (the row is fully placed).
  final VoidCallback onEntered;

  /// Called once a departure has finished and the slot can be dropped.
  final VoidCallback onLeft;

  final Widget child;

  @override
  State<RowMotion> createState() => _RowMotionState();
}

class _RowMotionState extends State<RowMotion>
    with SingleTickerProviderStateMixin {
  // Runs 0 → 1 over delay + span; [_progress] carries the eased, staggered
  // fraction of the motion itself. A row that is simply part of the list rests
  // at 1 and never ticks.
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 1,
  );

  Animation<double> _progress = kAlwaysCompleteAnimation;

  _Play _play = _Play.rest;

  // Whether the fold is currently running BACKWARDS (an Undo caught it in
  // flight). Tracked explicitly rather than inferred from a `dismissed` status,
  // which a plain `forward(from: 0)` also reports on its way past zero.
  bool _reversing = false;

  bool _started = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Started here rather than in initState because the reduced-motion rule
    // reads an inherited widget.
    if (!_started) {
      _started = true;
      _sync();
    }
  }

  @override
  void didUpdateWidget(covariant RowMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entering != oldWidget.entering ||
        widget.leaving != oldWidget.leaving) {
      _sync();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _sync() {
    final wants = widget.leaving
        ? _Play.leaving
        : widget.entering
        ? _Play.entering
        : _Play.rest;
    if (wants == _Play.rest) {
      _play = _Play.rest;
      _c.stop();
      _progress = kAlwaysCompleteAnimation;
      _c.value = 1;
      return;
    }
    // Back while the fold was still running — an Undo inside the toast. The row
    // reverses the collapse it had begun and re-expands from exactly where it
    // had got to; it never blinks out and grows again from nothing.
    if (wants == _Play.entering && _play == _Play.leaving && _c.value > 0) {
      _reversing = true;
      _c.animateBack(0);
      return;
    }
    _play = wants;
    _reversing = false;
    final motion = Motion.of(context);
    final span = motion.long;
    final delay = motion.resolve(widget.delay);
    final total = span + delay;
    if (total == Duration.zero) {
      // Reduced motion: the end state, in this frame. An arriving row is simply
      // there; a leaving one is simply gone, and says so at once so the list can
      // drop its slot.
      _c.stop();
      _progress = kAlwaysCompleteAnimation;
      _c.value = 1;
      _report();
      return;
    }
    _c
      ..stop()
      ..duration = total;
    _progress = _c.drive(
      CurveTween(
        curve: Interval(
          delay.inMicroseconds / total.inMicroseconds,
          1,
          curve: wants == _Play.leaving
              ? MotionCurves.exit
              : MotionCurves.enter,
        ),
      ),
    );
    _c.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _report();
    } else if (status == AnimationStatus.dismissed && _reversing) {
      // The reversed fold finished: the row is back, whole, and part of the
      // list again.
      setState(() {
        _reversing = false;
        _play = _Play.rest;
        _progress = kAlwaysCompleteAnimation;
      });
      _afterFrame(widget.onEntered);
    }
  }

  /// Reported after the frame: both callbacks make the list rebuild, and the
  /// reduced-motion path above reaches this during a build.
  void _report() => _afterFrame(() {
    if (_play == _Play.leaving) {
      widget.onLeft();
    } else if (_play == _Play.entering) {
      widget.onEntered();
    }
  });

  void _afterFrame(VoidCallback action) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });

  @override
  Widget build(BuildContext context) {
    // The PLAYED mode, not the requested one: a reversed fold is still drawn as
    // a fold running backwards.
    final leaving = _play == _Play.leaving;
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value.clamp(0.0, 1.0);
        final factor = leaving ? 1 - t : t;
        return RowFold(
          factor: factor,
          // A row on its way out takes no input. It is a shrinking target
          // sliding under the finger, and everything it still offers is aimed
          // at a task that is leaving — Undo is the one affordance for second
          // thoughts.
          child: IgnorePointer(
            ignoring: leaving,
            // Opacity at 1 paints its child directly, so a settled row carries
            // no layer — and the wrapper never has to appear or disappear.
            child: Opacity(opacity: factor, child: child),
          ),
        );
      },
    );
  }
}
