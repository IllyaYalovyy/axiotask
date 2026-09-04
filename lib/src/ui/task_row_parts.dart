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
      child: StateLayer(
        key: const Key('link-badge'),
        onTap: () => onOpen(url),
        borderRadius: BorderRadius.circular(4),
        // A finger gets the full 48dp target; the mouse keeps it compact
        // (F19 #198's 48dp audit — see [touchTarget]).
        child: touchTarget(
          theme.platform,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: theme.colorScheme.primary,
                  semanticLabel: 'Open link',
                ),
                if (extra > 0) ...[
                  const SizedBox(width: 2),
                  Text(
                    '+$extra',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
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
          // The count ellipsizes so the bar+count never overflows a narrow meta
          // column (G9 #208); the bar keeps its fixed width.
          Flexible(
            child: Text(
              '$done/$total',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Enlarge [child] to a ≥48dp hit area on a coarse (touch) pointer, leaving it
/// compact on a mouse. The glyph is unchanged — only the tappable region grows
/// (F19 #198's 48dp audit). Shared by the metadata badges (the due segment and
/// the link badge) that would otherwise be sub-48dp touch targets.
///
/// The box is exactly 48dp tall and at least 48dp wide, but shrink-wraps its
/// width to the content (`widthFactor: 1`) so it does NOT expand to fill the
/// metadata [Wrap] and shove the following badges onto a second run — it sits
/// inline, vertically centered, beside the subtask progress and list tag.
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
