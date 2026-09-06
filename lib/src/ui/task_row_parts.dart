// The task row's SUPPORTING PARTS (#274, split out of task_row.dart): the
// edge-aware drag recognizer that lets the drawer / system back gesture win the
// screen edge, the detected-link badge, and the subtask progress pill.
//
// Each is used by exactly one widget — [TaskRow] — but none of them is about a
// row's own state, which is what the row file is: they are three self-contained
// pieces of chrome with rules of their own.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'state_layer.dart';
import 'theme.dart' show coarsePointerPlatform;

/// The vertical space the meta line occupies on a COARSE pointer.
///
/// The desktop meta line is exactly as tall as its text (20dp). A finger needs
/// more than that to hit the date button, and 48dp — the target the row carried
/// before #276 — cannot coexist with the 72dp pitch (12 + 24 + 4 + 48 + 12 =
/// 100dp, a row half again as tall as the M3 two-line item). So the touch meta
/// line takes every dp the pitch has left: it runs from the 4dp gap to the
/// row's bottom edge, absorbing the bottom padding as HIT AREA while its text
/// stays top-aligned 4dp under the title. 32dp tall and ~110dp wide, with the
/// whole 72dp row as the forgiving target behind it (a miss opens the detail,
/// which carries the same Due field) and swipe-left as the shortcut that needs
/// no aim at all.
const double kTouchMetaBand = 32;

/// The height of ONE meta item's content — the meta text line. Every badge in
/// the meta [Wrap] occupies exactly this, so the notes icon, the link badge and
/// the date all sit on one optical line whether or not the band around them is
/// taller (the touch date target).
const double kMetaLineHeight = 20;

/// The size of a meta-line icon: paired with the 14sp meta text, so the glyph
/// reads at the text's weight rather than as a speck beside it.
const double kMetaIconSize = 16;

/// A [HorizontalDragGestureRecognizer] that refuses pointers whose down-event
/// lands in the drawer-edge / system-gesture gutter (F15 #193). Rejecting the
/// pointer here means the recognizer never enters the gesture arena for it, so
/// the Scaffold's drawer edge-drag / the OS back gesture claims it unopposed —
/// as opposed to swallowing the drag and no-op'ing, which would deaden the edge.
class EdgeAwareHorizontalDragRecognizer
    extends HorizontalDragGestureRecognizer {
  EdgeAwareHorizontalDragRecognizer({
    required this.startsInEdgeGutter,
    super.debugOwner,
    super.supportedDevices,
  });

  /// Returns true when a pointer-down at the given GLOBAL position falls inside
  /// the gutter the row must cede to the drawer / system back gesture.
  final bool Function(Offset globalPosition) startsInEdgeGutter;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (startsInEdgeGutter(event.position)) return false;
    return super.isPointerAllowed(event);
  }
}

/// A tappable link badge for the first detected URL, with a "+N" count when the
/// task has more than one.
class LinkBadge extends StatelessWidget {
  const LinkBadge({
    super.key,
    required this.url,
    required this.extra,
    required this.onOpen,
    required this.theme,
  });

  final String url;
  final int extra;
  final ValueChanged<String> onOpen;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: url,
      // A BUTTON, and it says so (#289): [StateLayer] is an [InkWell], which
      // gives the node a tap action but never the button role, so the badge
      // announced as a bare "Open link" with no hint that it was a control.
      // The icon's own `semanticLabel` stays the name.
      child: Semantics(
        button: true,
        child: StateLayer(
          key: const Key('link-badge'),
          onTap: () => onOpen(url),
          borderRadius: BorderRadius.circular(4),
          // A finger gets the whole meta band as a target; the mouse keeps it
          // compact (F19 #198's 48dp audit — see [metaTouchTarget]). No padding
          // of its own: every meta item is exactly one [kMetaLineHeight] text
          // line, flush with the line's leading edge (#276).
          child: metaTouchTarget(
            theme.platform,
            SizedBox(
              height: kMetaLineHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.open_in_new,
                    size: kMetaIconSize,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'Open link',
                  ),
                  if (extra > 0) ...[
                    const SizedBox(width: 2),
                    Text(
                      '+$extra',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The subtask progress indicator: a filled bar plus a "done/total" label. The
/// subtasks themselves live in the detail panel (invariant #1); tapping the row
/// opens it.
///
/// It speaks to a screen reader as ONE sentence — "1 of 3 subtasks complete" —
/// and nothing inside it speaks at all (#287). Both halves of that matter:
///
///   • A determinate [LinearProgressIndicator] publishes a semantic VALUE
///     ("33") and the `progressBar` ROLE. The row is a single merged semantics
///     node, so those became the ROW's, and Android's accessibility bridge
///     reads a node's value before its label — a task with two unfinished
///     subtasks announced as "0, ext two (copy)", a bare number ahead of the
///     title on a node the AT believed was a progress bar. The bar is a
///     picture of a fraction that is written beside it in full, so it is
///     [ExcludeSemantics]-silent: no information is lost.
///   • "1/3" is not a sentence. A screen reader is free to read a slash as a
///     date separator or to say the glyph; the words are unambiguous.
class SubtaskProgress extends StatelessWidget {
  const SubtaskProgress({
    super.key,
    required this.done,
    required this.total,
    required this.theme,
  });

  final int done;
  final int total;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Tooltip(
      message: '$done/$total subtasks',
      child: Semantics(
        label: '$done of $total subtasks complete',
        excludeSemantics: true,
        child: SizedBox(
          height: kMetaLineHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // The count ellipsizes so the bar+count never overflows a narrow
              // meta column (G9 #208); the bar keeps its fixed width.
              Flexible(
                child: Text(
                  '$done/$total',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Enlarge [child] to a ≥48dp hit area on a coarse (touch) pointer, leaving it
/// compact on a mouse. The glyph is unchanged — only the tappable region grows
/// (F19 #198's 48dp audit). Used by the sidebar's list drag handle; the task
/// row's own meta badges use [metaTouchTarget], whose height is the row's
/// pitch to keep.
///
/// The box is exactly 48dp tall and at least 48dp wide, but shrink-wraps its
/// width to the content (`widthFactor: 1`) so it does NOT expand to fill its
/// row and shove what follows aside — it sits inline, vertically centered.
Widget touchTarget(TargetPlatform platform, Widget child) {
  if (!coarsePointerPlatform(platform)) return child;
  return SizedBox(
    height: 48,
    child: Center(
      widthFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48),
        child: child,
      ),
    ),
  );
}

/// The task row's meta-line hit target: [touchTarget]'s rule, sized to the
/// row's 72dp pitch instead of to 48dp.
///
/// A finger cannot reliably land on a 20dp line of text, and the row's meta
/// badges (the date button above all) are the one thing there the user acts on.
/// But a 48dp target cannot coexist with the two-line pitch — see
/// [kTouchMetaBand] — so the badge takes the whole band the pitch leaves it:
/// 32dp, its bottom half being the row's own bottom padding.
///
/// Content is TOP-START aligned inside it (#276), for two reasons: the visible
/// badge has to stay 4dp under the title (centring it in the band would push it
/// down into the row's whitespace), and its leading glyph has to line up with
/// the title's first glyph (centring it horizontally would inset a narrow badge
/// by a few dp). The extra height below is pure hit area.
Widget metaTouchTarget(TargetPlatform platform, Widget child) {
  if (!coarsePointerPlatform(platform)) return child;
  return SizedBox(
    height: kTouchMetaBand,
    child: Align(
      alignment: AlignmentDirectional.topStart,
      widthFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48),
        child: child,
      ),
    ),
  );
}
