// The ONE completion motion sequence (#241). Ticking a task used to give almost
// no confirmation: the row dimmed a little and — with the show-completed filter
// off — simply vanished from the list. On a phone the finger covers the
// checkbox, so "done" happened off-screen.
//
// The sequence, played by EVERY completion path (checkbox tick, swipe-right,
// bulk Complete) because it is driven by the row's rendered state rather than by
// the call site — the sweep runs from the start of the text, so it reads the
// same way in an RTL locale:
//
//   0 …140ms  the settle — the title takes its strikethrough as a left-to-right
//             sweep while the row fades and shrinks a hair;
// 140…320ms  the collapse — ONLY when the row is leaving the filtered list: its
//             height animates to zero and the rows below slide up.
//
// Un-completing (the 30-second Undo toast, or the checkbox again) plays the same
// controller backwards: the row re-expands into place, then the strike lifts —
// it never pops in. [MediaQuery.disableAnimations] (Android "remove animations",
// desktop reduced motion) jumps straight to the end state instead.
//
// The motion is PRESENTATION ONLY. The store write happens on the tick; nothing
// here delays, gates, or retries it, and a row that is mid-collapse is already
// completed in the database.

import 'package:flutter/material.dart';

const int _settleMs = 140;
const int _collapseMs = 180;

/// How long the strike sweep / fade / shrink takes.
const Duration completionSettleDuration = Duration(milliseconds: _settleMs);

/// How long a departing row takes to fold its height away, after the settle.
const Duration completionCollapseDuration = Duration(milliseconds: _collapseMs);

/// Settle + collapse — the whole sequence, end to end.
const Duration completionSequenceDuration = Duration(
  milliseconds: _settleMs + _collapseMs,
);

/// Where the settle ends inside [completionSequenceDuration] — the point a
/// completed row that STAYS on screen rests at.
const double completionSettleFraction = _settleMs / (_settleMs + _collapseMs);

const Interval _settleInterval = Interval(
  0,
  completionSettleFraction,
  curve: Curves.easeOut,
);
const Interval _collapseInterval = Interval(
  completionSettleFraction,
  1,
  curve: Curves.easeIn,
);

/// Plays the completion sequence for one list row.
///
/// [builder] receives the settle animation (0 = open, 1 = fully completed) to
/// drive the row's own strike/fade/shrink; the height collapse is applied here,
/// around whatever the builder returns, so the ENTIRE list item folds away —
/// drag handle and bucket spacing included — and not just the row's inner body.
///
/// [departing] means the task has left the filtered list (it was completed while
/// completed tasks are hidden) and this row is being kept alive purely to fold
/// away; [onDeparted] fires when the fold is done and the row can be dropped.
/// [returning] means the row is coming BACK after such a fold (an Undo), so it
/// starts collapsed and expands into place.
class CompletionMotion extends StatefulWidget {
  const CompletionMotion({
    required this.completed,
    required this.departing,
    required this.returning,
    required this.onDeparted,
    required this.onReturned,
    required this.builder,
    super.key,
  });

  /// Whether the task this row shows is completed.
  final bool completed;

  /// Whether the row is on screen only to play its collapse.
  final bool departing;

  /// Whether the row is re-entering after a collapse (start folded).
  final bool returning;

  /// Called once the collapse has finished and the row renders nothing.
  final VoidCallback onDeparted;

  /// Called once a re-entering row has finished expanding.
  final VoidCallback onReturned;

  /// Builds the list item, given the settle animation to drive the row look.
  final Widget Function(BuildContext context, Animation<double> settle) builder;

  @override
  State<CompletionMotion> createState() => _CompletionMotionState();
}

class _CompletionMotionState extends State<CompletionMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sequence = AnimationController(
    vsync: this,
    duration: completionSequenceDuration,
    // A row that is ALREADY completed when it first renders is drawn at its
    // resting look with no motion — the app does not replay every completion on
    // launch, and the at-rest goldens are untouched.
    value: widget.returning ? 1 : _target,
  );

  late final Animation<double> _settle = _sequence.drive(
    CurveTween(curve: _settleInterval),
  );
  late final Animation<double> _collapse = _sequence.drive(
    CurveTween(curve: _collapseInterval),
  );

  bool _started = false;

  /// Where the sequence rests for the current props.
  double get _target =>
      widget.departing ? 1 : (widget.completed ? completionSettleFraction : 0);

  @override
  void initState() {
    super.initState();
    _sequence.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A returning row starts folded (see the controller's initial value) and
    // unfolds on its first frame. Kicked off here, not in initState, because
    // the reduced-motion check reads an inherited widget.
    if (!_started) {
      _started = true;
      if (widget.returning) _run();
    }
  }

  @override
  void didUpdateWidget(covariant CompletionMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sequence.value != _target) _run();
  }

  @override
  void dispose() {
    _sequence.dispose();
    super.dispose();
  }

  void _run() {
    final target = _target;
    if (MediaQuery.disableAnimationsOf(context)) {
      // Reduced motion: the same end state, reached in this frame.
      _sequence.value = target;
      return;
    }
    // Both directions scale to the distance left, so an un-complete that starts
    // from the settled look takes the settle's length, not the whole sequence's.
    if (target > _sequence.value) {
      _sequence.animateTo(target);
    } else {
      _sequence.animateBack(target);
    }
  }

  void _onStatus(AnimationStatus status) {
    // Reported after the frame: the listener can fire during a build (the
    // reduced-motion jump above), and both callbacks make the list rebuild.
    if (status == AnimationStatus.completed) {
      _afterFrame(() {
        if (widget.departing) widget.onDeparted();
      });
    } else if (status == AnimationStatus.dismissed) {
      _afterFrame(widget.onReturned);
    }
  }

  void _afterFrame(VoidCallback action) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });

  @override
  Widget build(BuildContext context) {
    final item = widget.builder(context, _settle);
    return AnimatedBuilder(
      animation: _collapse,
      child: item,
      builder: (context, child) {
        final factor = 1 - _collapse.value;
        // A fully folded row is not built at all: it occupies no space, catches
        // no taps, and is genuinely gone from the tree the frame it reaches
        // zero — a zero-height row that still answered finds and hit-tests
        // would be a ghost in every sense.
        if (factor <= 0) return const SizedBox.shrink();
        // A row on its way out takes no input. It is a shrinking target sliding
        // under the finger, and everything it still offers (un-complete, open,
        // reschedule) would be aimed at a task that is leaving — the Undo toast
        // is the one affordance for second thoughts.
        final item = IgnorePointer(ignoring: widget.departing, child: child);
        if (factor >= 1) return item;
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: factor,
            child: item,
          ),
        );
      },
    );
  }
}

/// A task title whose completion strikethrough is drawn as a left-to-right
/// SWEEP rather than an instant restyle.
///
/// At either rest ([progress] 0 or 1) it is a single [Text] — byte-identical to
/// the plain styled title it replaces, so nothing about the at-rest look (or the
/// goldens of it) changes. Only mid-sweep does it stack the completed copy over
/// the open one, clipped to the swept fraction of the title's width, so the
/// strike appears to be drawn on.
class StrikeSweep extends StatelessWidget {
  const StrikeSweep({
    required this.title,
    required this.progress,
    required this.completedColor,
    super.key,
  });

  /// The text to render (already resolved — "Untitled" for a blank task).
  final String title;

  /// 0 = open, 1 = struck through.
  final Animation<double> progress;

  /// The dimmed colour a completed title wears.
  final Color completedColor;

  Widget _line({required bool struck}) => Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      decoration: struck ? TextDecoration.lineThrough : null,
      color: struck ? completedColor : null,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    builder: (context, _) {
      final t = progress.value.clamp(0.0, 1.0);
      if (t <= 0) return _line(struck: false);
      if (t >= 1) return _line(struck: true);
      // The stack keeps the title's own box (its parent still constrains it
      // exactly as at rest, so nothing in the row moves), while BOTH copies are
      // laid out loose — at the width of the text itself. The sweep therefore
      // crosses the words, not the empty space after them.
      return Stack(
        children: [
          _line(struck: false),
          // Filled and then loosened again by the outer [Align], so the struck
          // copy meets exactly the constraints the open one did: same width,
          // same ellipsis, same glyph positions. (A bare `Positioned(left: 0)`
          // leaves the child UNBOUNDED — a long title would shed its ellipsis
          // and run past the row for the length of the sweep.)
          Positioned.fill(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ClipRect(
                key: const Key('title-strike'),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: t,
                  child: _line(struck: true),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
