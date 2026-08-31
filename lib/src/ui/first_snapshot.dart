// First-frame content (#260) — the pane between "mounted" and "the store has
// answered".
//
// The store is LOCAL, and the wait is measured, not assumed: a file-backed
// first snapshot costs 7–13ms at 50–1000 tasks and 32ms at 5000 on this
// developer machine (designs/cold-start.md §"First snapshot"). At that cost
// the honest first frame is CONTENT, and a spinner would be an animation
// started and stopped inside four frames — a stutter the app inflicts on
// itself. There is no spinner on this path, at any width, on any platform.
//
// What there is instead, in order:
//
//   • NOTHING, for [MotionDurations.firstSnapshotGrace]. A pane with a blank
//     list area for 10ms is a pane that never looked wrong. Crucially it is
//     also not the EMPTY STATE: "No tasks yet" is an answer, and flashing it
//     at a user with 200 tasks — which is what this pane did before #260 —
//     tells them, for one frame, that their data is gone;
//   • past the grace, three [SkeletonRow]s. A launch that slow is a
//     pathological one (a cold spinning disk, a phone thrashing), and the
//     failure to protect against there is a dead pane the user cannot tell
//     from a hung app. The placeholders take the shape of the rows they stand
//     in for, so nothing jumps when the real ones land;
//   • when the snapshot arrives, the skeleton CROSS-FADES into the content
//     over [Motion.medium] — but only if a skeleton was ever shown. In the
//     ordinary case the gate has drawn nothing at all, so there is nothing to
//     fade FROM and the content simply appears.
//
// Once the store has answered, the gate returns its child verbatim — no
// wrapper, no transition, nothing left in the tree to pay for a wait that is
// over.

import 'package:flutter/material.dart';

import 'motion.dart';

/// One placeholder row, shaped like a task row: the checkbox's block, then a
/// title-length bar. [widthFactor] varies the bar so three of them read as
/// three different titles rather than as a table.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({required this.widthFactor, super.key});

  /// The bar's share of the available title width.
  final double widthFactor;

  /// The height of a task row's tappable line — the skeleton stands in the
  /// same space the row will take.
  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    // `surfaceContainerHighest` is the M3 role for a filled block on the page:
    // visible on both brightnesses without ever competing with real content.
    final block = BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    );
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: block.copyWith(
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(height: 14, decoration: block),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three placeholder rows shown while a first snapshot is genuinely slow.
///
/// Fixed widths, not random ones: a placeholder that differs between two runs
/// is a golden that differs between two runs.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key});

  static const List<double> _widths = [0.72, 0.54, 0.83];

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    // A block standing in for a title has nothing to read out, and three of
    // them announced as list items would be three tasks the user does not have.
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final w in _widths) SkeletonRow(widthFactor: w)],
    ),
  );
}

/// Holds [child] back until the store's first snapshot has landed.
///
/// [hasData] is "the store has answered at least once" — never "the store has
/// rows". An empty account answers too, and its answer is the empty state.
class FirstSnapshotGate extends StatefulWidget {
  const FirstSnapshotGate({
    required this.hasData,
    required this.child,
    super.key,
  });

  /// Whether the store has produced its first snapshot.
  final bool hasData;

  /// The pane — rows, or the empty state.
  final Widget child;

  @override
  State<FirstSnapshotGate> createState() => _FirstSnapshotGateState();
}

class _FirstSnapshotGateState extends State<FirstSnapshotGate>
    with TickerProviderStateMixin {
  /// The grace. A controller rather than a timer because the frame clock is
  /// the clock the rest of this file runs on — and because a raw `Timer` is
  /// banned below `lib/` (TESTING.md).
  ///
  /// Its span is NOT resolved through [Motion]: the grace is a threshold, and
  /// a reduced-motion user is not asking to be shown placeholders 300ms sooner.
  late final AnimationController _grace = AnimationController(
    vsync: this,
    duration: MotionDurations.firstSnapshotGrace,
  );

  /// The skeleton → content cross-fade. Only ever runs when a skeleton was
  /// actually on screen.
  late final AnimationController _crossFade = AnimationController(
    vsync: this,
    duration: MotionDurations.medium,
  );

  /// The store has answered — from here on the gate is out of the way.
  late bool _answered = widget.hasData;

  /// The grace has elapsed with no answer, so this build shows placeholders.
  bool _graceElapsed = false;

  /// A skeleton actually reached the screen, so the content has something to
  /// fade FROM. Set from `build`, never from the grace's status listener: the
  /// grace can complete on the very frame the snapshot lands, and a cross-fade
  /// out of a placeholder the user never saw is a flash of a state that did
  /// not happen.
  bool _skeletonPainted = false;

  /// The cross-fade is running right now.
  bool _fading = false;

  Motion _motion = Motion.full;

  @override
  void initState() {
    super.initState();
    _grace.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_answered) {
        setState(() => _graceElapsed = true);
      }
    });
    _crossFade.addStatusListener((status) {
      if (status == AnimationStatus.completed && _fading) {
        setState(() => _fading = false);
      }
    });
    if (!_answered) _grace.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = Motion.of(context);
  }

  @override
  void didUpdateWidget(FirstSnapshotGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hasData || _answered) return;
    _answered = true;
    _grace.stop();
    final span = _motion.medium;
    if (_skeletonPainted && span > Duration.zero) {
      _fading = true;
      _crossFade
        ..duration = span
        ..forward(from: 0);
    }
    // No skeleton was ever drawn (the ordinary case), or motion is off: the
    // content is simply there on this frame. `build` follows this call, so
    // nothing needs to schedule it.
  }

  @override
  void dispose() {
    _grace.dispose();
    _crossFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_answered && !_fading) return widget.child;
    if (!_answered) {
      if (!_graceElapsed) return const SizedBox.expand();
      // Painting them is what makes them real — see [_skeletonPainted].
      _skeletonPainted = true;
      return const SkeletonRows();
    }
    // The overlap IS the cross-fade: the placeholder leaves along the same
    // frames the content arrives on, so nothing blinks.
    return Stack(
      fit: StackFit.expand,
      children: [
        FadeTransition(
          opacity: ReverseAnimation(_crossFade),
          child: const IgnorePointer(child: SkeletonRows()),
        ),
        FadeTransition(opacity: _crossFade, child: widget.child),
      ],
    );
  }
}
