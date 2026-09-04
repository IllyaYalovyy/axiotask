// A single top-level task row — the T7.2 "complete" fresh TaskRow: the main
// line (checkbox, title/inline-rename, pending-sync dot) plus a metadata line
// (notes badge, link badge, due/no-date/inherited-date segment, subtask
// progress, optional list tag) and a completion fade/shrink animation.
//
// Subtasks are never rows (invariant #1) — the caller only ever hands this
// widget a top-level task; there is no indent, connector, or expand toggle.
//
// Dates are set through the ONE shared [QuickDateAnchor] (#243): the due /
// "no date" segment IS the quick-date button, on every pointer. The hover- and
// swipe-revealed in-row quick-date strip it replaced is retired outright (D-1,
// ratified 2026-08-30) — it spoke its own vocabulary ("1 wk", "1 mo"), was
// invisible to a first-time user, and read as alien on both pointers.
//
// The coarse-pointer path (T8.1) is grafted on here: a touch swipe right
// completes the task, a swipe left opens the SAME quick-date sheet for the row
// (the gesture survives the strip's retirement as a shortcut), and a long-press
// toggles selection. Those gestures are gated to a touch pointer so the mouse
// keeps its right-click menu; the gesture arena disambiguates a horizontal
// swipe from the list's vertical scroll and a stationary long-press from either.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/pending_edits.dart';
import '../model/dates.dart';
import 'commit_flash.dart';
import 'completion_motion.dart';
import 'date_format.dart';
import 'detail_motion.dart';
import 'haptics.dart';
import 'quick_date_menu.dart';
import 'state_layer.dart';
import 'task_row_parts.dart';
import 'theme.dart';
import 'url_detect.dart';

/// The background wash a row carries while ITS task is the one the detail panel
/// currently shows (#221). Deliberately a SECONDARY tonal tint — the same
/// "this is the current one" role the sidebar's selected view already wears,
/// and a different hue family from [multiSelectWash], with no accent bar — so
/// "this is what the detail is showing" can never be misread as "this is
/// picked for a bulk op". Painted with no border and no padding, so it costs no
/// row geometry (the #168 no-reflow class).
///
/// The alpha differs by brightness so the wash reads the SAME distance from the
/// page in both themes: in the light scheme secondaryContainer already sits a
/// hair off the surface, so it is used neat; in the dark scheme it is far
/// lighter than the surface, so it is thinned to land the same step away
/// (undiluted it would be a bold band, at the light theme's alpha it would be a
/// near-invisible tint).
Color openDetailWash(ColorScheme scheme) => scheme.secondaryContainer
    .withValues(alpha: scheme.brightness == Brightness.dark ? 0.42 : 1.0);

/// The background wash of a MULTI-SELECTED row — a primary tint that pairs with
/// the left accent bar drawn in the same [ColorScheme.primary] (BulkOps).
Color multiSelectWash(ColorScheme scheme) =>
    scheme.primary.withValues(alpha: 0.08);

/// One tappable task row. Stateful to host the inline-rename editor and the
/// in-flight touch swipe.
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
    this.openInDetail = false,
    this.onSelectToggle,
    this.onContextMenu,
    this.editRequested = false,
    this.onEditDone,
    this.pendingEdits,
    this.onInlineEditActive,
    this.completionProgress,
    this.commit,
    this.haptics = const NoHaptics(),
    super.key,
  });

  /// The task's display title (blank titles render as "Untitled").
  final String title;

  /// The task's notes — scanned for URLs and drives the "has notes" badge.
  final String? notes;

  /// Whether the task is completed (drives the checkbox, strikethrough, and the
  /// completion fade/shrink).
  final bool completed;

  /// The completion sequence's settle progress (0 = open, 1 = completed), which
  /// drives the strike sweep, the fade, and the shrink together (#241). Supplied
  /// by the list's [CompletionMotion] so a tick, a swipe-right, and a bulk
  /// Complete all animate identically. When `null` the completed look is simply
  /// drawn at rest — a row with no sequence around it has nothing to play.
  final Animation<double>? completionProgress;

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

  /// Apply a frozen date move (Today/Tomorrow/Next week/Next month/Clear) the
  /// user chose from the shared quick-date menu (#243). With [onPickDate] it
  /// makes the due segment a quick-date button and arms the swipe-left
  /// shortcut; `null` leaves the segment a plain calendar tap.
  final ValueChanged<DateMove>? onSetDue;

  /// Open the calendar for this task — the menu's "Pick a date…", and the whole
  /// of the due segment's action when [onSetDue] is not wired. `null` renders
  /// the segment as plain, non-interactive text.
  final VoidCallback? onPickDate;

  /// Open a detected URL (a tap on the link badge); `null` hides the badge.
  final ValueChanged<String>? onOpenUrl;

  /// Whether this row is part of the current multi-select — draws the left
  /// accent bar and a tinted background (BulkOps).
  final bool selected;

  /// Whether the detail panel is currently showing THIS task (#221) — draws the
  /// [openDetailWash] so the list↔detail link is visible in the two-pane
  /// layout. Driven by the router-derived selection, so it follows the detail
  /// through every entry path; [selected] outranks it when both apply.
  final bool openInDetail;

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

  /// The haptic seam this row's own gestures speak through (#257). Only ONE
  /// row event is the row's to report: a swipe crossing the distance at which
  /// it would fire, which happens while the finger is still down and so has no
  /// callback anywhere else. Everything else a row does (the checkbox, the
  /// selection toggle, a quick date) is a callback the list answers, and the
  /// list ticks there. Defaults to the no-op, so a row mounted outside the app
  /// is silent.
  final Haptics haptics;

  /// The most recent write the STORE confirmed for this task, and which element
  /// of the row it changed (#252) — the row washes that element once per
  /// commit. `null` for a row that has had none (and for a row mounted outside
  /// the list, which has nothing watching the store for it).
  final TaskCommit? commit;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  TextEditingController? _editor;
  FocusNode? _focus;

  // The rename flush held in a field so [PendingEdits.unregister]'s identity
  // check matches — a bare `_flushRename` tear-off is not identical across
  // calls, so unregistering with one would silently miss (#183/G4).
  VoidCallback? _renameFlush;

  // ── T8.1 touch gestures ────────────────────────────────────────────────
  // A mostly-horizontal swipe ≥80px right completes the task; ≥80px left opens
  // the shared quick-date sheet for the row (#243). The content follows the
  // finger (dampened, capped) during the drag and always settles square — the
  // strip that used to latch open under it is retired (D-1). The gesture arena
  // resolves a swipe against the list's vertical scroll, and a stationary
  // long-press (select) against either — any motion before it fires cancels it.
  static const double _swipeThreshold = 80;
  static const double _swipeRevealMax = 96;
  // Touch gestures only — a mouse taps the row's date segment instead.
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
  // Whether the in-flight swipe is currently PAST the distance at which
  // releasing would fire its action — the rising edge of this is the one haptic
  // a row reports itself (#257), so the user learns "let go now" without
  // looking. Falls back to false if the finger comes back, and ticks again on
  // the next crossing: it is a live statement about the gesture, not a latch.
  bool _swipeArmed = false;
  // The content's live horizontal offset (0 at rest, negative while peeking).
  double _swipeOffset = 0;

  /// Whether this row can offer the shared quick-date menu — the due segment's
  /// tap, and the swipe-left shortcut, both need a move AND a calendar route.
  bool get _dateMenuWired =>
      widget.onSetDue != null && widget.onPickDate != null;

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

  /// A body tap: on a touch platform with a selection already active a plain tap
  /// toggles this row's membership (F18); otherwise a Ctrl/Cmd-modified tap
  /// toggles selection (BulkOps) and a plain tap opens the detail panel.
  void _onBodyTap() {
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

  /// Whether a release at [dx] of travel would actually DO something — a
  /// swipe-right on an already-completed row, or a swipe-left on a row with no
  /// calendar route, fires nothing, and a gesture that fires nothing must not
  /// promise that it will.
  bool _swipeWouldAct(double dx) =>
      (dx >= _swipeThreshold && !widget.completed) ||
      (dx <= -_swipeThreshold && _dateMenuWired);

  void _onSwipeStart(DragStartDetails _) {
    _swipeDx = 0;
    _swipeArmed = false;
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    _swipeDx += d.primaryDelta ?? 0;
    final armed = _swipeWouldAct(_swipeDx);
    if (armed && !_swipeArmed) widget.haptics.tick();
    _swipeArmed = armed;
    setState(() {
      if (_swipeDx < -10 && _dateMenuWired) {
        // A leftward drag drags the content with the finger — dampened and
        // capped so a long fling never rips the row off-screen — which is the
        // only feedback that the shortcut is live before it fires.
        _swipeOffset = (_swipeDx * 0.35).clamp(-_swipeRevealMax, 0.0);
      } else {
        _swipeOffset = 0;
      }
    });
  }

  void _onSwipeEnd(DragEndDetails _) {
    final dx = _swipeDx;
    _swipeArmed = false;
    var complete = false;
    var openDates = false;
    setState(() {
      // The finger-following nudge lives only during the drag; the row always
      // returns square (nothing is revealed underneath it any more — D-1).
      _swipeOffset = 0;
      if (dx >= _swipeThreshold && !widget.completed) {
        // Swipe right → complete (fire after the frame settles). A row that is
        // already completed has nothing to complete: swipe-right is a no-op —
        // it must never toggle the task back open (F15 #193). Re-opening stays
        // an explicit affordance (the checkbox / detail panel), never a stray
        // right-swipe.
        complete = true;
      } else if (dx <= -_swipeThreshold && _dateMenuWired) {
        // Swipe left → the SAME quick-date sheet the date segment opens (#243).
        openDates = true;
      }
      // Otherwise: not far enough — the row simply settles back.
    });
    if (complete) widget.onToggle();
    if (openDates) _openDateMenu();
  }

  /// Raise the shared quick-date surface for this row — the swipe-left
  /// shortcut's destination. Always the coarse-pointer sheet: only a touch
  /// pointer can swipe (the recognizer is gated to it).
  void _openDateMenu() {
    showQuickDateSheet(
      context,
      onSetDue: widget.onSetDue!,
      onPickDate: widget.onPickDate!,
    );
  }

  void _onSwipeCancel() {
    _swipeArmed = false;
    setState(() => _swipeOffset = 0);
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
        EdgeAwareHorizontalDragRecognizer:
            GestureRecognizerFactoryWithHandlers<
              EdgeAwareHorizontalDragRecognizer
            >(
              () => EdgeAwareHorizontalDragRecognizer(
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
    // No per-row "⋮" on ANY pointer (#245): it cost a 48dp column on every row
    // and went unused. A mouse reaches the actions by right-click; a finger
    // reaches them by the row tap (detail), the date segment, swipe, long-press
    // and the bulk bar — see [showTaskContextMenu]'s header for the full map.
    final width = MediaQuery.sizeOf(context).width;
    // Refresh the swipe edge-gutter limits (F15 #193): the leading gutter is the
    // wider of the drawer edge band and the left system-gesture inset; the
    // trailing gutter is the right system-gesture inset. Touch drags starting
    // inside either forward to the drawer / OS back gesture, not the row.
    final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
    _leftEdgeLimit = math.max(_drawerEdgeWidth, gestureInsets.left);
    _rightEdgeLimit = width - gestureInsets.right;
    // The completion sequence's progress (#241): the list hands every row the
    // same animation, so a tick, a swipe-right and a bulk Complete settle
    // identically. Standing alone (no sequence around it) the row simply wears
    // the resting look for its state.
    final completion =
        widget.completionProgress ??
        AlwaysStoppedAnimation<double>(widget.completed ? 1.0 : 0.0);
    final content = FadeTransition(
      key: const Key('row-completion-fade'),
      // Completion fades the whole row (the reference's `.completed`/
      // `.completing` opacity), so a checked task reads as "done, on its way
      // out" before the show-completed filter removes it.
      opacity: completion.drive(Tween<double>(begin: 1.0, end: 0.5)),
      child: ScaleTransition(
        scale: completion.drive(Tween<double>(begin: 1.0, end: 0.98)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          // The content follows the finger during a left drag (T8.1).
          // Transform.translate is paint-only, so the row's size — and the
          // #168 no-reflow geometry — is unchanged whatever the offset.
          child: Transform.translate(
            key: const Key('swipe-content'),
            // The whole row body is one open-the-detail surface (#214):
            // explicit controls (checkbox, badges) win
            // the gesture arena as deeper children; every other tap —
            // including the space the old invisible checkbox box used to
            // swallow and the former dead zones between the title band
            // and the badge boxes — routes to the harmless default.
            // Completion is ONLY the checkbox (and the deliberate
            // swipe-right) — precision directive 2026-08-18.
            offset: Offset(_swipeOffset, 0),
            // ONE state layer for the whole body (#259): the hover wash, the
            // press ripple and the keyboard focus ring all belong to the
            // open-the-detail surface, so they cover exactly it — inside the
            // row's own 8dp gutter, rounded to match, rather than bleeding to
            // the window edge. It replaces a bare GestureDetector: the row is
            // the app's most-used control and was the one that answered a
            // pointer with nothing at all.
            child: StateLayer(
              onTap: _onBodyTap,
              borderRadius: BorderRadius.circular(8),
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
                        // A rename that LANDS washes the title line, wherever
                        // it was typed — this row's inline editor, the detail
                        // panel's Title field, a sync pull (#252). OUTSIDE
                        // [_mainLine] because the inline editor replaces the
                        // whole line while it is open: a wrapper inside would
                        // be torn down by the very rename it exists to report,
                        // and would come back with nothing left to play.
                        CommitFlash(
                          commit: widget.commit,
                          target: CommitTarget.title,
                          child: _mainLine(theme, completion),
                        ),
                        if (!coarsePointerPlatform(theme.platform))
                          const SizedBox(height: 2),
                        _metaLine(theme),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // A selected row gets a left accent bar and a tinted wash so a multi-select
    // reads at a glance (BulkOps); the row the DETAIL is showing gets the
    // quieter [openDetailWash] instead, so the two-pane list↔detail link is
    // visible without ever competing with a bulk-op selection — multi-select
    // wins when a row is both. The right-click surface wraps the whole row so a
    // secondary tap anywhere opens the context menu (desktop). Every one of
    // these is out of the row's default render, so the clean-state golden is
    // unchanged, and neither wash pads or insets, so the row's height and the
    // content's position are identical washed or not (#168 no-reflow).
    final Widget decorated;
    if (widget.selected) {
      decorated = DecoratedBox(
        decoration: BoxDecoration(
          color: multiSelectWash(theme.colorScheme),
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: content,
      );
    } else if (widget.openInDetail) {
      // The wash arrives WITH the pane it belongs to (#253): on the expanded
      // layout [DetailRevealScope] holds it at zero for the whole of the pane's
      // slide, so the highlight never runs ahead of the panel it is pointing
      // at. Outside a scope — the compact layout, an isolated test — it is
      // simply there. The box is drawn at every reveal, transparent included,
      // so the fade changes no tree shape and therefore no row geometry.
      final reveal = DetailRevealScope.of(context);
      final wash = openDetailWash(theme.colorScheme);
      decorated = DecoratedBox(
        decoration: BoxDecoration(
          color: wash.withValues(alpha: wash.a * reveal),
        ),
        child: content,
      );
    } else {
      decorated = content;
    }

    // A commit whose changed element is unknown or several washes the WHOLE row
    // (#252): a bulk action that hit N rows at once, or a change the sync
    // pulled in. Outside the selection/detail washes, so it reads as one flash
    // over the row as the user sees it, and square — a row has no corners of
    // its own to round.
    final flashed = CommitFlash(
      commit: widget.commit,
      target: CommitTarget.row,
      radius: 0,
      child: decorated,
    );

    // Secondary-tap (right-click) opens the desktop context menu anywhere on the
    // row; touch selection is the long-press bound by _wrapTouchGestures below.
    final withContext = widget.onContextMenu == null
        ? flashed
        : GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (d) => widget.onContextMenu!(d.globalPosition),
            child: flashed,
          );
    // The coarse-pointer swipe/long-press layer wraps everything so a gesture
    // anywhere on the row is caught (T8.1).
    return _wrapTouchGestures(withContext);
  }

  /// The main line: title (or inline editor) and the pending-sync dot.
  /// [completion] drives the title's strike sweep (#241).
  Widget _mainLine(ThemeData theme, Animation<double> completion) {
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
    // mobile gesture. Drop it there (rename on touch is the detail screen's Title
    // field); the mouse keeps double-click-to-rename (F19 #198).
    final doubleTapToRename = coarsePointerPlatform(theme.platform)
        ? null
        : _startEdit;
    // On touch the title's decorative padding shrinks: the 48dp metadata tap
    // boxes below already hold generous whitespace, and stacking the desktop
    // paddings on top of them made the mobile list sparse (density directive
    // 2026-08-18 — the 'touch row density' contract).
    final compact = coarsePointerPlatform(theme.platform);
    final line = Padding(
      padding: EdgeInsets.only(top: compact ? 4 : 12, bottom: compact ? 0 : 2),
      child: Row(
        children: [
          Expanded(
            child: StrikeSweep(
              title: widget.title.isEmpty ? 'Untitled' : widget.title,
              progress: completion,
              completedColor: completedTitleColor(theme.colorScheme),
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
    );
    // The row's ONE tap surface is the body's [StateLayer] (#259), so this
    // layer no longer catches the tap — a press on the title washes and ripples
    // exactly like a press on any other part of the row, instead of being
    // swallowed by a bare GestureDetector over the busiest part of it. What
    // stays is the desktop-only double-click-to-rename, and it competes with
    // the StateLayer's tap recognizer exactly as it competed with the tap
    // recognizer that used to sit here — so the desktop's tap timing is
    // unchanged, and a touch row has no second recognizer at all.
    if (doubleTapToRename == null) return line;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: doubleTapToRename,
      child: line,
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
            LinkBadge(
              url: urls.first,
              extra: urls.length - 1,
              onOpen: widget.onOpenUrl!,
              theme: theme,
            ),
          _dueSegment(theme, muted),
          if (widget.subtaskTotal > 0)
            SubtaskProgress(
              done: widget.subtaskDone,
              total: widget.subtaskTotal,
              theme: theme,
            ),
          if ((widget.listTag ?? '').isNotEmpty)
            // A move to another list washes the tag that names the new one
            // (#252) — in a cross-list view the row stays put, and the tag is
            // the only thing about it that changed.
            CommitFlash(
              commit: widget.commit,
              target: CommitTarget.listTag,
              child: Container(
                key: const Key('list-tag'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                // A long list name ellipsizes rather than pushing the tag past
                // the (narrow) meta column and overflowing it (G9 #208). Each
                // Wrap child is constrained to the column width, so an un-capped
                // tag is the one meta item that can exceed it.
                child: Text(
                  widget.listTag!,
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The due badge (own date), the read-only inherited "↳" date, or "no date".
  ///
  /// This segment IS the row's quick-date button (#243): tapping it raises the
  /// ONE shared option set — Today · Tomorrow · Next week · Next month ·
  /// Pick a date… · Clear — as an anchored menu on a mouse and a bottom sheet
  /// under a finger. "no date" stays a button (user ruling): it is how an
  /// undated task gets a date without opening the detail panel. With only
  /// [TaskRow.onPickDate] wired the tap goes straight to the calendar, and with
  /// neither callback the segment is plain text (no dead button).
  Widget _dueSegment(ThemeData theme, TextStyle? muted) {
    final own = (widget.due ?? '').isNotEmpty ? widget.due : null;
    final inherited = (widget.inheritedDue ?? '').isNotEmpty
        ? widget.inheritedDue
        : null;

    Widget child;
    if (own != null) {
      final urgency = dueUrgency(own);
      // The shared urgency palette (#242) — never a colour literal here: the
      // row, the Focus overdue heading and the detail Due field must say the
      // same thing with the same tone.
      final color = dueColor(urgency, theme.colorScheme);
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

    // A date that LANDS washes the badge that shows it (#252) — the quick-date
    // menu, the calendar, a swipe-left, a clear. Inside the 48dp touch target,
    // so the wash hugs the badge rather than the invisible box around it.
    child = CommitFlash(
      commit: widget.commit,
      target: CommitTarget.due,
      child: child,
    );
    if (widget.onPickDate == null) return child;
    // A touch pointer gets a full 48dp hit target on this small date segment
    // (F19 #198 — a finger can't reliably land on ~20dp of text); the mouse
    // keeps the compact desktop segment (it's precise, and the row stays dense
    // — the desktop UX standard).
    final target = touchTarget(
      theme.platform,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: child,
      ),
    );
    if (!_dateMenuWired) {
      return StateLayer(
        key: const Key('row-due-segment'),
        onTap: widget.onPickDate!,
        borderRadius: BorderRadius.circular(4),
        child: target,
      );
    }
    return QuickDateAnchor(
      onSetDue: widget.onSetDue!,
      onPickDate: widget.onPickDate!,
      builder: (context, open) => StateLayer(
        key: const Key('row-due-segment'),
        onTap: open,
        borderRadius: BorderRadius.circular(4),
        child: target,
      ),
    );
  }
}
