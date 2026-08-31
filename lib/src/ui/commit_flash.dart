// The commit flash (#252) — the ONE way the app says "that landed".
//
// An edit that LANDS used to be invisible. Pick "Tomorrow" from the quick-date
// menu and a small grey label quietly reads something else; move a task to
// another list from the detail and nothing on the row acknowledges it; apply a
// bulk action to a selection and N rows change with no sign of WHICH ones. On a
// desktop, where there is no swipe and no sheet to dismiss, that silence is the
// whole feedback story for most actions.
//
// So a confirmed write washes the element it changed:
//
//   what   [ColorScheme.secondaryContainer] at [commitFlashPeak], decaying to
//          fully transparent
//   how long  [Motion.emphasized], ease-out ([MotionCurves.enter]) — it drops
//          away quickly and does not ask to be watched
//   where  the CHANGED element — the date badge, the list tag, the title. The
//          whole row only when the changed element is unknown or several: a
//          bulk action, or a field the sync pulled in.
//
// Two rules the design is not allowed to drift from:
//
//   • It is triggered by the COMMIT, not the tap. The wash starts when the
//     store confirms the write, so an undoable mistake reads as "that
//     happened", and Undo's reversal is itself a commit that flashes again.
//   • It never stacks. A second commit inside the flash RESTARTS it at full
//     strength; two washes never add up into a brighter one.
//
// Under reduced motion there is no flash at all. Unlike a fold or a slide, a
// flash has no end state to arrive at — it IS the travel — and a user who
// turned animations off asked not to see exactly this. The state change itself
// is then the feedback.

import 'package:flutter/material.dart';

import 'motion.dart';

/// The element of a row a confirmed write is about.
enum CommitTarget {
  /// The row's title — a rename, from the row's own inline editor, the detail
  /// panel's Title field, or anywhere else that commits one.
  title,

  /// The due / "no date" segment — a quick-date move, a picked day, a clear.
  due,

  /// The list tag a cross-list view draws.
  ///
  /// NOT the user-facing "Move to list": Google has no cross-list move, so that
  /// is a delete-from-old + create-in-new under a fresh local id, and the row
  /// leaves the list while a different one arrives (#251's own motion says so).
  /// This is a row whose list changes IN PLACE — the store re-homing an
  /// unpushed task when the list holding it is deleted.
  listTag,

  /// The whole row: the changed element is unknown or several (a bulk action, a
  /// sync-pulled change, more than one field at once).
  row,
}

/// A write the store has CONFIRMED for one task: WHICH element it changed, and
/// a [seq] that is unique across the app's lifetime.
///
/// The sequence number is what makes a repeat legible. Two identical commits in
/// a row ("Tomorrow", then "Tomorrow" again on a row already dated tomorrow)
/// are different [TaskCommit]s, so the second restarts the wash instead of
/// being swallowed as "no change".
@immutable
class TaskCommit {
  const TaskCommit(this.target, this.seq);

  /// The element the store just changed.
  final CommitTarget target;

  /// Monotonic id of this commit — see the class docs.
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is TaskCommit && other.target == target && other.seq == seq;

  @override
  int get hashCode => Object.hash(target, seq);
}

/// The wash's opacity at the instant the write lands, before it decays to zero.
///
/// Enough to be unmistakable on a glanced-at row, low enough that the text it
/// covers stays readable for the fraction of a second it is there.
const double commitFlashPeak = 0.4;

/// The tonal wash itself — the rectangle of [color] a [CommitFlash] paints over
/// the element that changed.
///
/// A widget of its own (rather than an inline [DecoratedBox]) so the colour
/// actually being painted, over exactly this element, is a thing a test can find
/// and read.
class CommitWash extends StatelessWidget {
  const CommitWash({required this.color, required this.radius, super.key});

  /// The wash colour at this instant — fully transparent when nothing is
  /// flashing, in which case it paints nothing at all.
  final Color color;

  /// Corner rounding, matched to the element underneath (the badges and the
  /// list tag are rounded; a whole-row wash is square).
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// Washes [child] when [commit] names [target] with a commit this widget has
/// not played yet.
///
/// The wrapper is ALWAYS the same shape, flashing or not — the #251 contract:
/// a wrapper that appears and disappears is a subtree Flutter tears down and
/// rebuilds, which would kill an open inline-rename editor mid-keystroke and
/// reset a row's completion animation. At rest the wash is fully transparent
/// (it paints nothing, so the at-rest goldens are untouched) and the [Stack]
/// passes its constraints straight through, so the element's geometry is
/// identical washed or not.
class CommitFlash extends StatefulWidget {
  const CommitFlash({
    required this.commit,
    required this.target,
    required this.child,
    this.radius = 4,
    super.key,
  });

  /// The row's most recent confirmed write, or `null` if it has had none.
  final TaskCommit? commit;

  /// The element this wrapper covers. A [commit] naming any other element is
  /// not this widget's to play.
  final CommitTarget target;

  /// Corner rounding for the wash — see [CommitWash.radius].
  final double radius;

  final Widget child;

  @override
  State<CommitFlash> createState() => _CommitFlashState();
}

class _CommitFlashState extends State<CommitFlash>
    with SingleTickerProviderStateMixin {
  // Runs 0 → 1 over the flash; the wash's opacity is the eased REMAINDER, so a
  // controller at rest (1) paints nothing and never ticks.
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 1,
  );

  late final Animation<double> _fade = _c.drive(
    CurveTween(curve: MotionCurves.enter),
  );

  /// The commit this widget has already played, so the same one is never
  /// replayed — a row scrolled out of view and back mounts carrying its last
  /// commit, and that write was confirmed while it was off screen.
  int? _played;

  TaskCommit? get _mine {
    final commit = widget.commit;
    return commit != null && commit.target == widget.target ? commit : null;
  }

  @override
  void initState() {
    super.initState();
    _played = _mine?.seq;
  }

  @override
  void didUpdateWidget(covariant CommitFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    final mine = _mine;
    if (mine == null || mine.seq == _played) return;
    _played = mine.seq;
    final span = Motion.of(context).emphasized;
    if (span == Duration.zero) {
      // Reduced motion: no flash. See the file header — a wash is pure travel,
      // so removing the travel removes the whole thing.
      _c.value = 1;
      return;
    }
    _c
      ..duration = span
      // Restart, never stack: `from: 0` throws away whatever the previous
      // commit had left running instead of layering a second wash on it.
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          // The wash is paint, never a target: it covers the very affordance
          // that was just used, and a tap landing on it a tenth of a second
          // later must still reach the badge underneath.
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _fade,
              builder: (context, _) => CommitWash(
                key: Key('commit-flash-${widget.target.name}'),
                color: scheme.secondaryContainer.withValues(
                  alpha: commitFlashPeak * (1 - _fade.value),
                ),
                radius: widget.radius,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
