// The designed empty state (#260) — what a view says when it has nothing to
// show.
//
// Before this file an empty view was one grey line of body text floating in the
// middle of the pane, and a user could not tell "you are up to date" from "this
// app is broken" from "the list did not load". Three things fix that, and no
// more than three: a per-view ICON, the LINE that was already there, and — only
// where the user can act on it — a HINT.
//
//   • the icon says WHICH nothing this is. An empty Focus is an achievement
//     (`check_circle_outline`); an empty Missed is a relief
//     (`sentiment_satisfied_alt`); an empty list is an invitation (`inbox`).
//     Five views, five glyphs, so the state is recognisable before the line is
//     read;
//   • the hint is "Add a task", and ONLY on a concrete list, because that is
//     the only place where the composer sitting right there will put a task in
//     the view the user is looking at. On a smart view (Focus, Upcoming,
//     Missed, Unscheduled, All Tasks) it would point at a control that cannot
//     fill the emptiness it is offering to fill;
//   • the icon ENTERS — 0.9 → 1 and a fade over [Motion.medium] — once, when
//     the state is entered, and never again. A rebuild is not an entrance: the
//     60s poll that finds nothing, a keystroke in the pane's composer and a
//     window resize all rebuild this widget, and an icon that pulsed at each
//     of them would be a page that twitches while the user is reading it. The
//     entrance is started ONCE from the state, so there is no per-build
//     decision to get wrong.
//
// The whole block is [Center]ed and sized to its content; the pane it sits in
// makes it scrollable, so a 2.0× text scale grows it rather than clipping it.

import 'package:flutter/material.dart';

import 'motion.dart';
import 'views.dart';

/// The empty-state message for [viewId] — a per-view reassurance for a smart
/// view, the generic prompt for a list / All Tasks. Ports the reference's
/// per-view empty strings.
String emptyMessageFor(String viewId) => switch (viewId) {
  kAttentionViewId => 'Nothing needs attention',
  'focus' => 'All clear for this week',
  'upcoming' => 'Nothing upcoming',
  'missed' => 'Nothing overdue',
  'unscheduled' => 'Everything is scheduled',
  _ => 'No tasks yet',
};

/// The icon above [emptyMessageFor] — the same five-way split, in glyphs.
IconData emptyIconFor(String viewId) => switch (viewId) {
  kAttentionViewId => Icons.verified_outlined,
  'focus' => Icons.check_circle_outline,
  'upcoming' => Icons.event_available,
  'missed' => Icons.sentiment_satisfied_alt,
  'unscheduled' => Icons.schedule,
  _ => Icons.inbox,
};

/// The smaller line under the message, or `null` where there is nothing to
/// suggest.
///
/// A concrete list has a composer that fills THIS view, so it gets the hint.
/// Every smart view is computed — a task added from Upcoming lands wherever its
/// date puts it, which may well not be Upcoming — so none of them do.
String? emptyHintFor(String viewId) =>
    (SmartView.byId(viewId) == null && viewId != kAttentionViewId)
    ? 'Add a task'
    : null;

/// The empty state for [viewId]: icon, line, and (on a list) a hint.
///
/// Give it a [Key] that carries the view id when the same slot can show two
/// different empty states — switching views is entering a state, and the new
/// view's icon should arrive rather than blink into existence.
class EmptyStateView extends StatefulWidget {
  const EmptyStateView({required this.viewId, super.key});

  /// The active view id (a smart view or a list id).
  final String viewId;

  @override
  State<EmptyStateView> createState() => _EmptyStateViewState();
}

class _EmptyStateViewState extends State<EmptyStateView>
    with SingleTickerProviderStateMixin {
  /// The icon's entrance. Started exactly once, from [didChangeDependencies],
  /// so no rebuild can restart it.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: MotionDurations.medium,
  );
  late final CurvedAnimation _enter = CurvedAnimation(
    parent: _entrance,
    curve: MotionCurves.enter,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 0.9,
    end: 1,
  ).animate(_enter);

  bool _entered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion resolves the span to zero, and an [AnimationController]
    // given a zero duration jumps to its end without ever ticking — the icon is
    // simply THERE on the frame the state is entered, which is the point.
    _entrance.duration = Motion.of(context).medium;
    if (!_entered) {
      _entered = true;
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = emptyHintFor(widget.viewId);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The glyph says the same thing as the line, in a different
            // language — a screen reader that read both would be reading it
            // twice.
            ExcludeSemantics(
              child: FadeTransition(
                opacity: _enter,
                child: ScaleTransition(
                  scale: _scale,
                  child: Icon(
                    emptyIconFor(widget.viewId),
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              emptyMessageFor(widget.viewId),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
