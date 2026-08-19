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

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/pending_edits.dart';
import '../model/dates.dart';
import 'date_format.dart';
import 'url_detect.dart';

/// Whether [platform] is a touch-primary platform — a coarse pointer with no
/// hover and no secondary-tap (Android/iOS/Fuchsia). There the "⋯" overflow is
/// the ONLY route to a row's context actions, so [TaskRow] renders it at EVERY
/// width; a mouse platform (Linux/macOS/Windows) reaches the same actions by
/// right-click, so the overflow stays hidden. The action-surface choice is by
/// pointer capability, never window width — width only picks the layout
/// (F16 #194). Read from `Theme.of(context).platform` so it is overridable in
/// tests and follows the running platform in production.
bool coarsePointerPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => true,
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => false,
};

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
    this.selectionActive = false,
    this.onSelectToggle,
    this.onContextMenu,
    this.onShowActions,
    this.editRequested = false,
    this.onEditDone,
    this.pendingEdits,
    this.onInlineEditActive,
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

  /// Whether a multi-select is currently active anywhere in the list (at least
  /// one row selected). On a touch platform this flips a plain body tap from
  /// "open the detail" to "toggle this row's membership" — the standard mobile
  /// multi-select where a long-press enters the mode and taps then extend it.
  /// The mouse keeps its plain-tap-opens / Ctrl-click-selects behavior.
  final bool selectionActive;

  /// Toggle this row's selection. Wired to a Ctrl/Cmd-click on the body (desktop)
  /// and a long-press (touch); `null` disables selection entry for this row.
  final VoidCallback? onSelectToggle;

  /// Open the desktop right-click context menu at the given GLOBAL pointer
  /// position; `null` disables the right-click surface.
  final void Function(Offset globalPosition)? onContextMenu;

  /// Open the touch action sheet (the coarse-pointer "⋯" overflow); `null`
  /// hides the overflow button. Rendered persistently on a touch platform at
  /// every width (F16 #194 — see [coarsePointerPlatform]).
  final VoidCallback? onShowActions;

  /// When true, the row enters inline-rename mode (the context menu's
  /// "Edit title"); the row calls [onEditDone] when it leaves edit mode.
  final bool editRequested;
  final VoidCallback? onEditDone;

  /// The app-wide pending-edits registry (#183/G4). While the inline-rename
  /// editor is mounted the row registers a flush here, so the app backgrounding
  /// persists a mid-typing rename that no blur will reach — exactly like the
  /// detail panel's fields. `null` skips registration (a row mounted outside the
  /// app, e.g. an isolated widget test).
  final PendingEdits? pendingEdits;

  /// Publish (with the commit action) or retract (with `null`) the open
  /// inline-rename editor to the shell's back-precedence ladder (G4 #183): a
  /// system back at the root bubbles to the OS without firing any [PopScope], so
  /// the shell intercepts it and calls this commit to save-and-close the editor
  /// rather than exit the app mid-rename. `null` skips it (an isolated test).
  final void Function(VoidCallback? commit)? onInlineEditActive;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  TextEditingController? _editor;
  FocusNode? _focus;
  bool _hovering = false;

  // The rename flush held in a field so [PendingEdits.unregister]'s identity
  // check matches — a bare `_flushRename` tear-off is not identical across
  // calls, so unregistering with one would silently miss (#183/G4).
  VoidCallback? _renameFlush;

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

  // F15 (#193) swipe edge gating: a horizontal drag whose pointer-down lands in
  // the leading drawer-edge band or either system-gesture inset belongs to the
  // Scaffold drawer / OS back gesture, not to the row. The row's drag recognizer
  // refuses those pointers outright (never enters the arena) so the drawer/back
  // gesture wins them. Matches Scaffold's own `_kEdgeDragWidth` for the drawer.
  static const double _drawerEdgeWidth = 20;
  // Live edge limits in GLOBAL x (recomputed each build from the MediaQuery):
  // a pointer-down at x ≤ [_leftEdgeLimit] or x ≥ [_rightEdgeLimit] is ignored.
  double _leftEdgeLimit = _drawerEdgeWidth;
  double _rightEdgeLimit = double.infinity;

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
    // inline rename now. (The back-handle publish inside [_startEdit] is
    // deferred to after this build, since a provider must not be mutated
    // mid-build — see [_startEdit].)
    if (widget.editRequested && !oldWidget.editRequested && !_editing) {
      _startEdit();
    }
  }

  void _startEdit() {
    setState(() {
      _editor = TextEditingController(text: widget.title);
      _focus = FocusNode();
    });
    // Register the persist-now hook for the paths that skip the blur-commit: a
    // system-back or the app backgrounding while the editor holds a mid-typing
    // rename (#183/G4). Held in a field so the later unregister matches.
    final flush = _flushRename;
    _renameFlush = flush;
    // A plain Map mutation — safe even from didUpdateWidget's build phase.
    widget.pendingEdits?.register(PendingEdit.rename, flush);
    // Publish the commit action to the shell's back handle AFTER this frame so a
    // system back at the root commits-and-closes this editor instead of exiting
    // the app mid-rename (#183/G4). Deferred because [_startEdit] can run from
    // didUpdateWidget (the context-menu "Edit title") and a provider must not be
    // mutated mid-build; guarded so a rename cancelled before the callback runs
    // leaves the handle clear. Focus is requested here too, once the field is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) widget.onInlineEditActive?.call(_commit);
      _focus?.requestFocus();
    });
  }

  /// Persist the current inline-rename text immediately (diff-only, non-empty)
  /// WITHOUT leaving edit mode — the registry entry for the system-back and
  /// app-backgrounded paths, which must save a mid-typing rename that no blur
  /// will ever reach (#183/G4). Empty/unchanged is a no-op (the caller owns
  /// whether an empty title deletes — T2.4).
  void _flushRename() {
    if (!mounted) return;
    final value = _editor?.text.trim() ?? '';
    if (value.isNotEmpty && value != widget.title) widget.onRename(value);
  }

  void _commit() {
    // The back ladder may hold a stale commit for a row already gone (a row
    // filtered out mid double-tap edit before it committed) — a no-op then.
    if (!mounted) return;
    _flushRename();
    _stopEdit();
  }

  void _stopEdit() {
    final flush = _renameFlush;
    if (flush != null) {
      widget.pendingEdits?.unregister(PendingEdit.rename, flush);
      _renameFlush = null;
      widget.onInlineEditActive?.call(null);
    }
    _editor?.dispose();
    _focus?.dispose();
    setState(() {
      _editor = null;
      _focus = null;
    });
    // Let the parent clear its edit request so a later "Edit title" fires again.
    widget.onEditDone?.call();
  }

  /// A body tap: a revealed swipe strip closes first (touch); on a touch
  /// platform with a selection already active a plain tap toggles this row's
  /// membership (F18); otherwise a Ctrl/Cmd-modified tap toggles selection
  /// (BulkOps) and a plain tap opens the detail panel.
  void _onBodyTap() {
    // A tap anywhere on a row with the swipe strip open closes it and does
    // nothing else (reference: a revealed strip is dismissed by tapping away).
    if (_actionsOpen) {
      _closeStrip();
      return;
    }
    // Touch selection mode (F18): once a long-press has entered a selection, a
    // plain tap on a coarse pointer toggles membership rather than opening the
    // detail. Gated to a touch platform so the mouse keeps plain-tap-opens
    // (its selection entry is the Ctrl-click / context-menu "Select").
    if (widget.selectionActive &&
        widget.onSelectToggle != null &&
        coarsePointerPlatform(Theme.of(context).platform)) {
      widget.onSelectToggle!();
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
      if (dx >= _swipeThreshold && !_actionsOpen && !widget.completed) {
        // Swipe right → complete (fire after the frame settles). A row that is
        // already completed has nothing to complete: swipe-right is a no-op —
        // it must never toggle the task back open (F15 #193). Re-opening stays
        // an explicit affordance (the checkbox / detail panel), never a stray
        // right-swipe.
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

  /// Whether a pointer-down at [globalPosition] falls in the drawer-edge /
  /// system-gesture gutter, where the row must NOT claim the horizontal drag
  /// (F15 #193). The limits are refreshed from the MediaQuery each build.
  bool _startsInEdgeGutter(Offset globalPosition) {
    final x = globalPosition.dx;
    return x <= _leftEdgeLimit || x >= _rightEdgeLimit;
  }

  /// Wrap [child] with the touch-only gesture layer: a horizontal swipe
  /// (complete / reveal) and a long-press (select). Gated to a touch pointer so
  /// the mouse keeps hover + right-click; a translucent behavior keeps the inner
  /// tap/checkbox targets hittable, and the arena resolves a swipe against the
  /// list's vertical scroll and a stationary long-press against either. The
  /// horizontal drag uses an edge-aware recognizer that refuses pointers landing
  /// in the drawer-edge / system-gesture gutter so those forward to the drawer /
  /// OS back gesture untouched (F15 #193).
  Widget _wrapTouchGestures(Widget child) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _EdgeAwareHorizontalDragRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _EdgeAwareHorizontalDragRecognizer
            >(
              () => _EdgeAwareHorizontalDragRecognizer(
                debugOwner: this,
                supportedDevices: _touchOnly,
                startsInEdgeGutter: _startsInEdgeGutter,
              ),
              (recognizer) => recognizer
                ..onStart = _onSwipeStart
                ..onUpdate = _onSwipeUpdate
                ..onEnd = _onSwipeEnd
                ..onCancel = _onSwipeCancel
                // Replay the pre-acceptance movement once the arena resolves
                // (#214): the row-wide open-tap recognizer makes every swipe's
                // arena CONTESTED, and with the default DragStartBehavior.start
                // a contested win swallows the touch-slop travel plus the
                // accepting move — the peek visibly jumps instead of following
                // the finger from the first pixel. `.down` anchors the drag at
                // the pointer-down, losing nothing.
                ..dragStartBehavior = DragStartBehavior.down,
            ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                debugOwner: this,
                supportedDevices: _touchOnly,
              ),
              (recognizer) => recognizer.onLongPress = widget.onSelectToggle,
            ),
      },
      child: child,
    );
  }

  @override
  void dispose() {
    // The row can be unmounted mid-edit (a view switch, a filter dropping it) —
    // retract its background flush so a stale entry never lingers in the
    // registry (#183/G4). The shell back-handle is deliberately NOT touched here
    // (mutating its provider mid-teardown is unsafe); the next list mount resets
    // it, and [_commit]'s `mounted` guard makes any stale entry a safe no-op.
    final flush = _renameFlush;
    if (flush != null) {
      widget.pendingEdits?.unregister(PendingEdit.rename, flush);
    }
    _editor?.dispose();
    _focus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The "⋯" overflow is the coarse-pointer path to every context action, and
    // the choice to show it is by POINTER CAPABILITY, never window width
    // (F16 #194): a touch pointer has no hover and no right-click, so on a touch
    // platform the overflow must render at EVERY width — a tablet or landscape
    // phone past the 600dp LAYOUT breakpoint still needs it. A mouse platform
    // reaches the same actions by right-click, so the overflow stays hidden and
    // the row stays clean. Width picks the list/detail layout, not this surface.
    final width = MediaQuery.sizeOf(context).width;
    // Refresh the swipe edge-gutter limits (F15 #193): the leading gutter is the
    // wider of the drawer edge band and the left system-gesture inset; the
    // trailing gutter is the right system-gesture inset. Touch drags starting
    // inside either forward to the drawer / OS back gesture, not the row.
    final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
    _leftEdgeLimit = math.max(_drawerEdgeWidth, gestureInsets.left);
    _rightEdgeLimit = width - gestureInsets.right;
    final showOverflow =
        coarsePointerPlatform(theme.platform) && widget.onShowActions != null;
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
                  // The whole row body is one open-the-detail surface (#214):
                  // explicit controls (checkbox, badges, overflow, strip) win
                  // the gesture arena as deeper children; every other tap —
                  // including the space the old invisible checkbox box used to
                  // swallow and the former dead zones between the title band
                  // and the badge boxes — routes to the harmless default.
                  // Completion is ONLY the checkbox (and the deliberate
                  // swipe-right) — precision directive 2026-08-18.
                  offset: Offset(_swipeOffset, 0),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onBodyTap,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The completion target. On touch it is the full 48dp
                        // box (#167, CheckboxTapTarget). On a mouse it shrinks
                        // to a compact box around the glyph — same rule as the
                        // metadata badges ("compact on a mouse") — because the
                        // invisible 48×48 area spanned ~75% of the desktop
                        // row's height and completed tasks from clicks that
                        // read as "the row" (#214). The 48dp-wide column stays
                        // either way, so the title never shifts.
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: coarsePointerPlatform(theme.platform)
                              ? SizedBox(
                                  key: const Key('row-checkbox-target'),
                                  width: 48,
                                  height: 48,
                                  child: Checkbox(
                                    value: widget.completed,
                                    onChanged: (_) => widget.onToggle(),
                                  ),
                                )
                              : Center(
                                  child: SizedBox(
                                    key: const Key('row-checkbox-target'),
                                    width: 28,
                                    height: 28,
                                    child: Checkbox(
                                      value: widget.completed,
                                      onChanged: (_) => widget.onToggle(),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _mainLine(theme),
                              if (!coarsePointerPlatform(theme.platform))
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
                          // A latched (swiped-open) strip closes the instant a
                          // date is picked (F19 #198): the reschedule is done, so
                          // the strip must not sit open over the row waiting for a
                          // tap-away. A desktop hover strip is not latched, so
                          // closing is a no-op there (the mouse still governs it).
                          onSetDue: (move) {
                            widget.onSetDue!(move);
                            if (_stripRevealedByTouch) _closeStrip();
                          },
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
    // Double-tap-to-rename is a DESKTOP affordance only. On a touch platform an
    // onDoubleTap recognizer would make every open-tap wait out the ~300ms
    // double-tap window before firing — a sluggish tap-to-open on the primary
    // mobile gesture. Drop it there (rename on touch is the ⋯ / long-press
    // menu's "Edit title"); the mouse keeps double-click-to-rename (F19 #198).
    final doubleTapToRename = coarsePointerPlatform(theme.platform)
        ? null
        : _startEdit;
    // On touch the title's decorative padding shrinks: the 48dp metadata tap
    // boxes below already hold generous whitespace, and stacking the desktop
    // paddings on top of them made the mobile list sparse (density directive
    // 2026-08-18 — the 'touch row density' contract).
    final compact = coarsePointerPlatform(theme.platform);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onBodyTap,
      onDoubleTap: doubleTapToRename,
      child: Padding(
        padding: EdgeInsets.only(
          top: compact ? 4 : 12,
          bottom: compact ? 0 : 2,
        ),
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
      // Touch: the 48dp tap boxes in this line carry the whitespace; the
      // decorative bottom padding is desktop-only (see _mainLine's note).
      padding: EdgeInsets.only(
        bottom: coarsePointerPlatform(theme.platform) ? 0 : 8,
      ),
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
              // A long list name ellipsizes rather than pushing the tag past the
              // (narrow) meta column and overflowing it (G9 #208). Each Wrap
              // child is constrained to the column width, so an un-capped tag is
              // the one meta item that can exceed it.
              child: Text(
                widget.listTag!,
                style: muted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
          // The date label is the flexible element: it ellipsizes before the
          // due chip can overflow the (narrow) meta column; the icon is fixed
          // (G9 #208).
          Flexible(
            child: Text(
              formatDue(own),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted?.copyWith(
                color: color,
                fontWeight: urgency == DueUrgency.overdue
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
        ],
      );
    } else if (inherited != null) {
      // Borrowed from a subtask: read-only marker, dimmer + italic.
      child = Text(
        '↳ ${formatDue(inherited)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted?.copyWith(fontStyle: FontStyle.italic),
      );
    } else {
      child = Text(
        'no date',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      );
    }

    if (widget.onPickDate == null) return child;
    return InkWell(
      onTap: widget.onPickDate,
      borderRadius: BorderRadius.circular(4),
      // A touch pointer gets a full 48dp hit target on this small date segment
      // (F19 #198 — a finger can't reliably land on ~20dp of text); the mouse
      // keeps the compact desktop segment (it's precise, and the row stays
      // dense — the desktop UX standard).
      child: touchTarget(
        theme.platform,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: child,
        ),
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

/// A [HorizontalDragGestureRecognizer] that refuses pointers whose down-event
/// lands in the drawer-edge / system-gesture gutter (F15 #193). Rejecting the
/// pointer here means the recognizer never enters the gesture arena for it, so
/// the Scaffold's drawer edge-drag / the OS back gesture claims it unopposed —
/// as opposed to swallowing the drag and no-op'ing, which would deaden the edge.
class _EdgeAwareHorizontalDragRecognizer
    extends HorizontalDragGestureRecognizer {
  _EdgeAwareHorizontalDragRecognizer({
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
    // A Material-3 tonal surface, not a flat grey box: the strip must read as
    // this app's own control the moment it appears (it shipped once as
    // labelSmall glyph codes on surfaceContainerHigh and read as an alien
    // tooltip — user directive 2026-08-19). Actions are labeled in words;
    // secondaryContainer keeps it distinct from the row underneath in both
    // themes.
    return Material(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(dense ? 10 : 14),
      elevation: 3,
      shadowColor: theme.colorScheme.shadow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _btn(
              theme,
              const Key('quick-date-today'),
              'Today',
              'Move to today',
              () => onSetDue(DateMove.today),
            ),
            _btn(
              theme,
              const Key('quick-date-tomorrow'),
              'Tomorrow',
              'Move to tomorrow',
              () => onSetDue(DateMove.tomorrow),
            ),
            _btn(
              theme,
              const Key('quick-date-week'),
              '1 wk',
              'Next week',
              () => onSetDue(DateMove.nextWeek),
            ),
            _btn(
              theme,
              const Key('quick-date-month'),
              '1 mo',
              'Next month',
              () => onSetDue(DateMove.nextMonth),
            ),
            if (hasDue)
              _btn(
                theme,
                const Key('quick-date-clear'),
                null,
                'Remove date',
                () => onSetDue(DateMove.clear),
              ),
          ],
        ),
      ),
    );
  }

  /// One pill action. A null [label] renders the clear-date icon instead.
  Widget _btn(
    ThemeData theme,
    Key key,
    String? label,
    String tooltip,
    VoidCallback onTap,
  ) {
    final onColor = theme.colorScheme.onSecondaryContainer;
    final inner = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 12,
        vertical: dense ? 5 : 9,
      ),
      child: label == null
          ? Icon(Icons.close, size: dense ? 16 : 20, color: onColor)
          : Text(
              label,
              style:
                  (dense
                          ? theme.textTheme.labelMedium
                          : theme.textTheme.labelLarge)
                      ?.copyWith(color: onColor),
            ),
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(dense ? 8 : 12),
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
