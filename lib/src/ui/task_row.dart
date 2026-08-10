// A single top-level task row — the T7.2 "complete" fresh TaskRow: the main
// line (checkbox, title/inline-rename, pending-sync dot) plus a metadata line
// (notes badge, link badge, due/no-date/inherited-date segment, subtask
// progress, optional list tag), a completion fade/shrink animation, and the
// desktop hover-revealed quick-date strip that reschedules WITHOUT reflowing the
// row (#168 — the strip lives out of layout flow so the row's height is
// identical hovered or not).
//
// Subtasks are never rows (invariant #1) — the caller only ever hands this
// widget a top-level task; there is no indent, connector, or expand toggle.
//
// The coarse-pointer path (T8.1) is grafted on here: a touch swipe right
// completes the task, a swipe left reveals the quick-date strip (following the
// finger while peeking, latched open at rest), and a long-press toggles
// selection. Those gestures are gated to a touch pointer so the mouse keeps the
// hover strip + right-click menu; the gesture arena disambiguates a horizontal
// swipe from the list's vertical scroll and a stationary long-press from either.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/dates.dart';
import 'date_format.dart';
import 'list_detail_scaffold.dart';
import 'url_detect.dart';

/// One tappable task row. Stateful to host the inline-rename editor and the
/// desktop hover state that reveals the quick-date strip.
class TaskRow extends StatefulWidget {
  const TaskRow({
    required this.title,
    required this.completed,
    required this.onOpen,
    required this.onToggle,
    required this.onRename,
    this.notes,
    this.due,
    this.inheritedDue,
    this.pendingSync = false,
    this.subtaskDone = 0,
    this.subtaskTotal = 0,
    this.listTag,
    this.onSetDue,
    this.onPickDate,
    this.onOpenUrl,
    this.selected = false,
    this.onSelectToggle,
    this.onContextMenu,
    this.onShowActions,
    this.editRequested = false,
    this.onEditDone,
    super.key,
  });

  /// The task's display title (blank titles render as "Untitled").
  final String title;

  /// The task's notes — scanned for URLs and drives the "has notes" badge.
  final String? notes;

  /// Whether the task is completed (drives the checkbox, strikethrough, and the
  /// completion fade/shrink).
  final bool completed;

  /// The task's OWN due date (raw `YYYY-MM-DD…`, `null`/empty when unset).
  /// Formatted for display here — never pass a pre-formatted label.
  final String? due;

  /// The effective date inherited from the earliest unfinished subtask (raw),
  /// shown as a read-only "↳" marker ONLY when the task has no [due] of its own.
  final String? inheritedDue;

  /// A local edit not yet pushed to Google — shows the pending-sync dot.
  final bool pendingSync;

  /// Completed / total direct subtasks; a progress bar shows when [subtaskTotal]
  /// is > 0. Subtasks themselves never render as rows (invariant #1).
  final int subtaskDone;
  final int subtaskTotal;

  /// A list name to tag the row with in cross-list views (e.g. smart views);
  /// `null` hides the tag.
  final String? listTag;

  /// Open the detail panel for this task (a body tap).
  final VoidCallback onOpen;

  /// Toggle the task's completion (a checkbox tap).
  final VoidCallback onToggle;

  /// Commit an inline rename to [value]; an empty [value] is ignored here (the
  /// empty-⇒-delete path lands with the delete command in T2.4).
  final ValueChanged<String> onRename;

  /// Apply a one-gesture date move (Today/Tomorrow/Next week/Next month/Clear)
  /// from the hover-revealed quick-date strip; `null` hides the strip.
  final ValueChanged<DateMove>? onSetDue;

  /// Open the date picker for this task (a tap on the due / "no date" segment);
  /// `null` renders that segment as plain, non-interactive text.
  final VoidCallback? onPickDate;

  /// Open a detected URL (a tap on the link badge); `null` hides the badge.
  final ValueChanged<String>? onOpenUrl;

  /// Whether this row is part of the current multi-select — draws the left
  /// accent bar and a tinted background (BulkOps).
  final bool selected;

  /// Toggle this row's selection. Wired to a Ctrl/Cmd-click on the body; `null`
  /// disables selection entry for this row.
  final VoidCallback? onSelectToggle;

  /// Open the desktop right-click context menu at the given GLOBAL pointer
  /// position; `null` disables the right-click surface.
  final void Function(Offset globalPosition)? onContextMenu;

  /// Open the touch action sheet (the coarse-pointer "⋯" overflow); `null`
  /// hides the overflow button. Rendered persistently on compact/touch layouts.
  final VoidCallback? onShowActions;

  /// When true, the row enters inline-rename mode (the context menu's
  /// "Edit title"); the row calls [onEditDone] when it leaves edit mode.
  final bool editRequested;
  final VoidCallback? onEditDone;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  TextEditingController? _editor;
  FocusNode? _focus;
  bool _hovering = false;

  // ── T8.1 touch gestures ────────────────────────────────────────────────
  // Reference (TaskRow.svelte): a mostly-horizontal swipe ≥80px right completes
  // the task; ≥80px left opens the quick-date strip, which follows the finger
  // (dampened, capped) while peeking and latches open at rest. The gesture arena
  // resolves a swipe against the list's vertical scroll, and a stationary
  // long-press (select) against either — any motion before it fires cancels it.
  static const double _swipeThreshold = 80;
  static const double _swipeRevealMax = 96;
  // Touch gestures only — the mouse keeps the hover strip + right-click menu.
  static const Set<PointerDeviceKind> _touchOnly = {PointerDeviceKind.touch};

  // Cumulative horizontal travel of the in-flight swipe (for the end decision).
  double _swipeDx = 0;
  // The content's live horizontal offset (0 closed, negative while peeking/open).
  double _swipeOffset = 0;
  // A left peek is tracking the finger (strip shown, not yet latched).
  bool _peeking = false;
  // The strip is latched open by a completed left swipe (opens at rest).
  bool _actionsOpen = false;

  /// The quick-date strip is on-screen because of a touch swipe (peek or open) —
  /// as opposed to a desktop hover — so it gets the larger 48dp touch targets.
  bool get _stripRevealedByTouch => _peeking || _actionsOpen;

  bool get _editing => _editor != null;

  @override
  void initState() {
    super.initState();
    // A row asked to open in edit mode from the start (context-menu "Edit
    // title" on a freshly-built row).
    if (widget.editRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_editing) _startEdit();
      });
    }
  }

  @override
  void didUpdateWidget(TaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent flipped editRequested on (context-menu "Edit title") — enter
    // inline rename now.
    if (widget.editRequested && !oldWidget.editRequested && !_editing) {
      _startEdit();
    }
  }

  void _startEdit() {
    setState(() {
      _editor = TextEditingController(text: widget.title);
      _focus = FocusNode();
    });
    // Focus after the field mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus?.requestFocus());
  }

  void _commit() {
    final value = _editor?.text.trim() ?? '';
    // Only rename when the title actually changed and is non-empty; the caller
    // owns whether an empty title deletes (T2.4).
    if (value.isNotEmpty && value != widget.title) widget.onRename(value);
    _stopEdit();
  }

  void _stopEdit() {
    _editor?.dispose();
    _focus?.dispose();
    setState(() {
      _editor = null;
      _focus = null;
    });
    // Let the parent clear its edit request so a later "Edit title" fires again.
    widget.onEditDone?.call();
  }

  /// A body tap: a revealed swipe strip closes first (touch); otherwise a
  /// Ctrl/Cmd-modified tap toggles selection (BulkOps) and a plain tap opens the
  /// detail panel.
  void _onBodyTap() {
    // A tap anywhere on a row with the swipe strip open closes it and does
    // nothing else (reference: a revealed strip is dismissed by tapping away).
    if (_actionsOpen) {
      _closeStrip();
      return;
    }
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final modified =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    if (modified && widget.onSelectToggle != null) {
      widget.onSelectToggle!();
    } else {
      widget.onOpen();
    }
  }

  /// Snap the swipe strip fully closed.
  void _closeStrip() {
    setState(() {
      _actionsOpen = false;
      _peeking = false;
      _swipeOffset = 0;
    });
  }

  void _onSwipeStart(DragStartDetails _) {
    _swipeDx = 0;
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    _swipeDx += d.primaryDelta ?? 0;
    setState(() {
      if (_swipeDx < -10 && widget.onSetDue != null) {
        // A leftward drag peeks the strip and drags the content with the finger,
        // dampened and capped so a long fling never rips the row off-screen.
        _peeking = true;
        _swipeOffset = (_swipeDx * 0.35).clamp(-_swipeRevealMax, 0.0);
      } else if (!_actionsOpen) {
        _peeking = false;
        _swipeOffset = 0;
      }
    });
  }

  void _onSwipeEnd(DragEndDetails _) {
    final dx = _swipeDx;
    var complete = false;
    setState(() {
      // The finger-following nudge only lives during the peek; at rest the row
      // sits square and the strip floats over its right edge (reference: only
      // `.swipe-actions-peeking` translates the content, `-open` does not).
      _peeking = false;
      _swipeOffset = 0;
      if (dx >= _swipeThreshold && !_actionsOpen) {
        // Swipe right → complete (fire after the frame settles).
        _actionsOpen = false;
        complete = true;
      } else if (dx <= -_swipeThreshold && widget.onSetDue != null) {
        // Swipe left → latch the quick-date strip open at rest.
        _actionsOpen = true;
      }
      // Otherwise: not far enough — the resting state (open or closed) stands.
    });
    if (complete) widget.onToggle();
  }

  void _onSwipeCancel() {
    setState(() {
      _peeking = false;
      _swipeOffset = 0;
    });
  }

  /// Wrap [child] with the touch-only gesture layer: a horizontal swipe
  /// (complete / reveal) and a long-press (select). Gated to a touch pointer so
  /// the mouse keeps hover + right-click; a translucent behavior keeps the inner
  /// tap/checkbox targets hittable, and the arena resolves a swipe against the
  /// list's vertical scroll and a stationary long-press against either.
  Widget _wrapTouchGestures(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: _touchOnly,
      onLongPress: widget.onSelectToggle,
      onHorizontalDragStart: _onSwipeStart,
      onHorizontalDragUpdate: _onSwipeUpdate,
      onHorizontalDragEnd: _onSwipeEnd,
      onHorizontalDragCancel: _onSwipeCancel,
      child: child,
    );
  }

  @override
  void dispose() {
    _editor?.dispose();
    _focus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // On a compact/touch layout (no hover, no right-click) the "⋯" overflow is
    // the coarse-pointer path to every context action — it must be a persistent
    // affordance. On the expanded desktop layout the right-click menu carries
    // them instead, so the row stays clean.
    final compact =
        MediaQuery.sizeOf(context).width < ListDetailScaffold.breakpoint;
    final showOverflow = compact && widget.onShowActions != null;
    // The quick-date strip is revealed by hover (a non-touch affordance); the
    // coarse-pointer swipe path is T8.1.
    final content = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedOpacity(
        // Completion fades the whole row (the reference's `.completed`/
        // `.completing` opacity), so a checked task reads as "done, on its way
        // out" before the show-completed filter removes it.
        opacity: widget.completed ? 0.5 : 1.0,
        duration: const Duration(milliseconds: 250),
        child: AnimatedScale(
          scale: widget.completed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 250),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Stack(
              children: [
                // The foreground content follows the finger during a left peek
                // (T8.1). Transform.translate is paint-only, so the row's size —
                // and the #168 no-reflow geometry — is unchanged whatever the
                // offset.
                Transform.translate(
                  key: const Key('swipe-content'),
                  offset: Offset(_swipeOffset, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 48dp hit target for the checkbox (#167,
                      // CheckboxTapTarget) — tapping it toggles and never bubbles
                      // to the body tap.
                      SizedBox(
                        key: const Key('row-checkbox-target'),
                        width: 48,
                        height: 48,
                        child: Checkbox(
                          value: widget.completed,
                          onChanged: (_) => widget.onToggle(),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _mainLine(theme),
                            const SizedBox(height: 2),
                            _metaLine(theme),
                          ],
                        ),
                      ),
                      if (showOverflow)
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: IconButton(
                            key: const Key('row-overflow'),
                            padding: EdgeInsets.zero,
                            tooltip: 'Task actions',
                            icon: const Icon(Icons.more_vert),
                            onPressed: widget.onShowActions,
                          ),
                        ),
                    ],
                  ),
                ),
                // The quick-date strip — lifted OUT of layout flow (#168): a
                // Positioned child never contributes to the Stack's size, so the
                // row height is byte-for-byte identical whether it shows or not.
                // Revealed by a desktop hover OR a touch swipe-left (T8.1); the
                // touch reveal gets the larger 48dp button targets.
                if (widget.onSetDue != null)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Visibility(
                        visible:
                            (_hovering || _stripRevealedByTouch) && !_editing,
                        child: _QuickDateStrip(
                          hasDue: (widget.due ?? '').isNotEmpty,
                          onSetDue: widget.onSetDue!,
                          dense: !_stripRevealedByTouch,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // A selected row gets a left accent bar and a tinted wash so a multi-select
    // reads at a glance (BulkOps). The right-click surface wraps the whole row
    // so a secondary tap anywhere opens the context menu (desktop). Both are
    // out of the row's default render, so the clean-state golden is unchanged.
    final decorated = widget.selected
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              border: Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 3),
              ),
            ),
            child: content,
          )
        : content;

    // Secondary-tap (right-click) opens the desktop context menu anywhere on the
    // row; touch selection is the long-press bound by _wrapTouchGestures below.
    final withContext = widget.onContextMenu == null
        ? decorated
        : GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (d) => widget.onContextMenu!(d.globalPosition),
            child: decorated,
          );
    // The coarse-pointer swipe/long-press layer wraps everything so a gesture
    // anywhere on the row is caught (T8.1).
    return _wrapTouchGestures(withContext);
  }

  /// The main line: title (or inline editor) and the pending-sync dot.
  Widget _mainLine(ThemeData theme) {
    if (_editing) {
      return TextField(
        controller: _editor,
        focusNode: _focus,
        autofocus: true,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
        ),
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) => _commit(),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onBodyTap,
      onDoubleTap: _startEdit,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.title.isEmpty ? 'Untitled' : widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: widget.completed
                      ? TextDecoration.lineThrough
                      : null,
                  color: widget.completed ? theme.disabledColor : null,
                ),
              ),
            ),
            if (widget.pendingSync)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  key: const Key('pending-dot'),
                  message: 'Not synced to Google yet',
                  child: Icon(
                    Icons.circle,
                    size: 8,
                    color: theme.colorScheme.tertiary,
                    semanticLabel: 'Pending sync',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The metadata line: notes/link badges, the due segment, subtask progress,
  /// and the optional list tag.
  Widget _metaLine(ThemeData theme) {
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final urls = urlsForTask(title: widget.title, notes: widget.notes);
    final hasNotes = (widget.notes ?? '').isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 4,
        children: [
          if (hasNotes)
            Tooltip(
              key: const Key('notes-badge'),
              message: 'Has notes',
              child: Icon(
                Icons.notes,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
                semanticLabel: 'Has notes',
              ),
            ),
          if (urls.isNotEmpty && widget.onOpenUrl != null)
            _LinkBadge(
              url: urls.first,
              extra: urls.length - 1,
              onOpen: widget.onOpenUrl!,
              theme: theme,
            ),
          _dueSegment(theme, muted),
          if (widget.subtaskTotal > 0)
            _SubtaskProgress(
              done: widget.subtaskDone,
              total: widget.subtaskTotal,
              theme: theme,
            ),
          if ((widget.listTag ?? '').isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(widget.listTag!, style: muted),
            ),
        ],
      ),
    );
  }

  /// The due badge (own date), the read-only inherited "↳" date, or "no date".
  /// Each is a pick-a-date affordance ONLY when [TaskRow.onPickDate] is wired;
  /// otherwise it renders as plain text (no dead button — T7.3 wires the picker).
  Widget _dueSegment(ThemeData theme, TextStyle? muted) {
    final own = (widget.due ?? '').isNotEmpty ? widget.due : null;
    final inherited = (widget.inheritedDue ?? '').isNotEmpty
        ? widget.inheritedDue
        : null;

    Widget child;
    if (own != null) {
      final urgency = dueUrgency(own);
      final color = switch (urgency) {
        DueUrgency.overdue => theme.colorScheme.error,
        DueUrgency.today => theme.colorScheme.tertiary,
        DueUrgency.none => theme.colorScheme.onSurfaceVariant,
      };
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            formatDue(own),
            style: muted?.copyWith(
              color: color,
              fontWeight: urgency == DueUrgency.overdue
                  ? FontWeight.w600
                  : null,
            ),
          ),
        ],
      );
    } else if (inherited != null) {
      // Borrowed from a subtask: read-only marker, dimmer + italic.
      child = Text(
        '↳ ${formatDue(inherited)}',
        style: muted?.copyWith(fontStyle: FontStyle.italic),
      );
    } else {
      child = Text('no date', style: muted);
    }

    if (widget.onPickDate == null) return child;
    return InkWell(
      onTap: widget.onPickDate,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: child,
      ),
    );
  }
}

/// The hover-revealed one-gesture reschedule strip: Today / Tomorrow / Next week
/// / Next month, plus Clear when the task has a date. Floats over the row's
/// right edge with its own background so it reads cleanly.
class _QuickDateStrip extends StatelessWidget {
  const _QuickDateStrip({
    required this.hasDue,
    required this.onSetDue,
    this.dense = true,
  });

  final bool hasDue;
  final ValueChanged<DateMove> onSetDue;

  /// A hover reveal (desktop) is dense; a touch swipe reveal is not, so its
  /// buttons meet the 48dp target (T8.1 48dp audit).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(6),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _btn(
              theme,
              const Key('quick-date-today'),
              '→o',
              'Today',
              () => onSetDue(DateMove.today),
            ),
            _btn(
              theme,
              const Key('quick-date-tomorrow'),
              '→t',
              'Tomorrow',
              () => onSetDue(DateMove.tomorrow),
            ),
            _btn(
              theme,
              const Key('quick-date-week'),
              '→w',
              'Next week',
              () => onSetDue(DateMove.nextWeek),
            ),
            _btn(
              theme,
              const Key('quick-date-month'),
              '→m',
              'Next month',
              () => onSetDue(DateMove.nextMonth),
            ),
            if (hasDue)
              _btn(
                theme,
                const Key('quick-date-clear'),
                '✕',
                'Remove date',
                () => onSetDue(DateMove.clear),
              ),
          ],
        ),
      ),
    );
  }

  Widget _btn(
    ThemeData theme,
    Key key,
    String label,
    String tooltip,
    VoidCallback onTap,
  ) {
    final inner = Padding(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 12, vertical: 4),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        // A touch reveal gives every button a 48dp hit target (#167); the dense
        // desktop hover strip stays compact.
        child: dense
            ? inner
            : ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(child: inner),
              ),
      ),
    );
  }
}

/// A tappable link badge for the first detected URL, with a "+N" count when the
/// task has more than one.
class _LinkBadge extends StatelessWidget {
  const _LinkBadge({
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
      child: InkWell(
        key: const Key('link-badge'),
        onTap: () => onOpen(url),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
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
    );
  }
}

/// The subtask progress indicator: a filled bar plus a "done/total" label. The
/// subtasks themselves live in the detail panel (invariant #1); tapping the row
/// opens it.
class _SubtaskProgress extends StatelessWidget {
  const _SubtaskProgress({
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
          Text(
            '$done/$total',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
