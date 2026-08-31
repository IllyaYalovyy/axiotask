// Quiet visible sync (#255) — the two marks that tell a user sync is alive
// without ever interrupting them.
//
// Background syncs (the 3–5s post-edit cadence, the 60s remote pickup) were
// entirely invisible: the only sync feedback in the app was the
// pull-to-refresh spinner the user pulled themselves. That silence is why
// "Pending changes: 1" was so hard to reason about (#232) — nothing on screen
// ever said the app had just talked to Google.
//
// So two marks, and deliberately no third:
//
//   • [SyncProgressLine] — a 2dp line at the bottom edge of the app bar for as
//     long as a run is in flight: indeterminate while it runs, filling to the
//     end when it finishes, then fading away. It is OVERLAID, never stacked
//     into the layout, so a sync starting can never move a row.
//   • [SyncCheckMark] — a check drawn over the footer's status dot, and ONLY
//     for a run that actually moved data. The once-a-minute poll that finds
//     nothing stays completely silent; a footer that congratulated itself
//     sixty times an hour would be noise, not feedback.
//
// Never a spinner, never a dialog, never a success toast. A failed run keeps
// its existing toast/status path: the line just goes, it never turns red — a
// red line at the top of the window is an alarm, and a transient blip that the
// next cadence tick fixes is not one.
//
// Rows changed by a pull get the commit flash (#252); that IS the "what
// changed" feedback, so nothing here repeats it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'motion.dart';

/// The line's thickness. 2dp: the Material linear indicator's own weight —
/// legible at a glance, thin enough to read as the bar's edge rather than as a
/// band that appeared.
const double kSyncLineHeight = 2;

/// The quiet sync line: present while [running], then a fill and a fade.
///
/// Pure — it takes a bool, not a provider — so the shell can mount it without
/// a [ProviderScope] and a golden can pin it mid-run. [LiveSyncLine] is the
/// wired one.
///
/// Under reduced motion the fill and the fade are both [Duration.zero], so the
/// line is simply there and then simply gone. It still APPEARS: it is status,
/// not decoration, and a user who turned animations off did not ask to stop
/// being told what the app is doing. The indeterminate sweep is the framework's
/// own and keeps running for the same reason every other Material progress
/// indicator does — a bar that says "working" cannot say it while holding
/// still.
class SyncProgressLine extends StatefulWidget {
  const SyncProgressLine({required this.running, super.key});

  /// Whether a sync run is in flight right now.
  final bool running;

  @override
  State<SyncProgressLine> createState() => _SyncProgressLineState();
}

class _SyncProgressLineState extends State<SyncProgressLine>
    with SingleTickerProviderStateMixin {
  /// The completion: fill, then fade. Starts AT its end, so an idle line
  /// paints nothing on the frame it is mounted.
  late final AnimationController _finish = AnimationController(
    vsync: this,
    duration: MotionDurations.syncLineFinish,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _finish.duration = Motion.of(
      context,
    ).resolve(MotionDurations.syncLineFinish);
  }

  @override
  void didUpdateWidget(SyncProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.running == oldWidget.running) return;
    if (widget.running) {
      // A run starting inside the previous one's fade takes the line back to
      // full strength instead of finishing the fade first — two runs never
      // leave two lines, and the second is never dimmer than the first.
      _finish
        ..stop()
        ..value = 0;
    } else {
      _finish.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: kSyncLineHeight,
      child: AnimatedBuilder(
        animation: _finish,
        builder: (context, _) => _line(colors),
      ),
    );
  }

  Widget _line(ColorScheme colors) {
    if (widget.running) return _bar(colors, null, 1);
    final t = _finish.value;
    // The finish is over — the line is not merely invisible, it is GONE: out
    // of the tree, out of the hit test, and (while running) out of the
    // semantics a screen reader walks.
    if (t >= 1) return const SizedBox.shrink();
    const fillEnd = MotionDurations.syncLineFillFraction;
    if (t < fillEnd) return _bar(colors, t / fillEnd, 1);
    return _bar(colors, 1, 1 - (t - fillEnd) / (1 - fillEnd));
  }

  Widget _bar(ColorScheme colors, double? value, double opacity) => Opacity(
    opacity: opacity,
    child: LinearProgressIndicator(
      key: const Key('sync-progress-line'),
      // Null while the run is in flight (an indeterminate sweep: we cannot
      // know how far through a sync is), a real fraction once it has landed.
      value: value,
      minHeight: kSyncLineHeight,
      color: colors.primary,
      // No track. Over an app bar a full-width band would read as a piece of
      // chrome that had appeared; only the moving part should be new.
      backgroundColor: Colors.transparent,
      // Announced only while the run is actually happening — the fill and the
      // fade are the tail of a fact already stated.
      semanticsLabel: value == null ? 'Syncing' : null,
    ),
  );
}

/// [SyncProgressLine] bound to the live runtime.
///
/// A widget rather than a flag threaded down the tree: the scaffold stays
/// provider-free (it renders in tests that mount it with no [ProviderScope]),
/// and a run starting or ending rebuilds THIS — never the shell or the list
/// under it.
class LiveSyncLine extends ConsumerWidget {
  const LiveSyncLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      SyncProgressLine(running: ref.watch(syncRunningProvider));
}

/// Draws a check over [child] each time [runs] increases.
///
/// [child] is the footer's status dot; the mark is painted OVER it, slightly
/// larger, from a [Stack] that the dot alone sizes — so the footer's geometry
/// is identical whether the mark is drawing or not, and no at-rest pixel moves.
///
/// Under reduced motion the span is zero and no mark is drawn at all. Like the
/// commit flash (#252), a stroke drawing itself in has no end state to arrive
/// at — it IS the travel — and the status phrase beside it ("Synced just now")
/// already carries the fact.
class SyncCheckMark extends StatefulWidget {
  const SyncCheckMark({required this.runs, required this.child, super.key});

  /// A monotonic count of the sync runs that CHANGED something. Every increase
  /// draws the mark; the initial value never does — mounting the footer after
  /// a hundred syncs must not congratulate the user for them.
  final int runs;

  /// The status dot the mark is drawn over.
  final Widget child;

  @override
  State<SyncCheckMark> createState() => _SyncCheckMarkState();
}

class _SyncCheckMarkState extends State<SyncCheckMark>
    with SingleTickerProviderStateMixin {
  /// How far past the dot's own box the mark is drawn, on every side. A check
  /// inside an 8dp dot would be a smudge; 3dp of overflow makes it a mark
  /// without costing a pixel of layout (the gap and padding around the dot are
  /// wider than this, so it never reaches the phrase beside it).
  static const double _overflow = 3;

  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: MotionDurations.syncCheck,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _draw.duration = Motion.of(context).resolve(MotionDurations.syncCheck);
  }

  @override
  void didUpdateWidget(SyncCheckMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A second confirmed run inside the mark RESTARTS the draw rather than
    // stacking a second one on it (the #252 rule).
    if (widget.runs != oldWidget.runs) _draw.forward(from: 0);
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _draw,
      // The dot is built once and handed in: it never changes as the mark
      // draws over it.
      child: widget.child,
      builder: (context, child) => _mark(colors, child!),
    );
  }

  Widget _mark(ColorScheme colors, Widget child) {
    final t = _draw.value;
    // At rest — and under reduced motion, where the span is zero and the
    // controller is at its end on the first frame — the dot alone, untouched.
    if (t >= 1) return child;

    const drawEnd = MotionDurations.syncCheckDrawFraction;
    const holdEnd = MotionDurations.syncCheckHoldFraction;
    // Three beats off ONE controller: the stroke draws while the dot fades
    // out under it, the finished mark holds, then it fades back to the dot.
    final double stroke;
    final double mark;
    if (t < drawEnd) {
      stroke = t / drawEnd;
      mark = 1;
    } else if (t < holdEnd) {
      stroke = 1;
      mark = 1;
    } else {
      stroke = 1;
      mark = 1 - (t - holdEnd) / (1 - holdEnd);
    }

    return Stack(
      // The dot is the only NON-positioned child, so it alone sizes this
      // stack: the mark overflows it on every side without costing a pixel of
      // layout, and the footer measures the same drawing or not.
      clipBehavior: Clip.none,
      children: [
        Opacity(opacity: 1 - (stroke * mark), child: child),
        Positioned(
          left: -_overflow,
          top: -_overflow,
          right: -_overflow,
          bottom: -_overflow,
          child: Opacity(
            opacity: mark,
            child: CustomPaint(
              key: const Key('sync-check-mark'),
              painter: _CheckPainter(progress: stroke, color: colors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

/// The check itself: two strokes of one polyline, drawn in as [progress] runs
/// 0 → 1 at a constant rate along their combined length (so the short leg and
/// the long leg are drawn at the same speed, and the mark reads as ONE stroke
/// of a pen rather than two segments appearing).
class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    // Inset from the box so the round cap of the stroke stays inside it.
    final start = Offset(size.width * 0.22, size.height * 0.52);
    final elbow = Offset(size.width * 0.42, size.height * 0.72);
    final end = Offset(size.width * 0.78, size.height * 0.28);
    final first = (elbow - start).distance;
    final second = (end - elbow).distance;
    final drawn = (first + second) * progress;

    final path = Path()..moveTo(start.dx, start.dy);
    if (drawn <= first) {
      final p = Offset.lerp(start, elbow, first == 0 ? 1 : drawn / first)!;
      path.lineTo(p.dx, p.dy);
    } else {
      path.lineTo(elbow.dx, elbow.dy);
      final p = Offset.lerp(
        elbow,
        end,
        ((drawn - first) / second).clamp(0, 1),
      )!;
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.16
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
