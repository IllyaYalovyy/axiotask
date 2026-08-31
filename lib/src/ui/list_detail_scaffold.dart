// The one hand-rolled adaptive shell (RFC-011 §7 / RESEARCH §7). One widget,
// one width breakpoint, the SAME list and detail children composed both ways —
// no forked screens.
//
//   width ≥ 600dp (expanded): the sidebar + list + side-by-side detail pane.
//   width <  600dp (compact):  ONE app bar (hamburger + view title + the hosted
//                              list's own actions — #244), a slide-in
//                              drawer holding the full sidebar, a bottom
//                              [ShellNavBar], and a "new task" FAB. An open
//                              detail covers the list full-bleed and the chrome
//                              hides — the "pushed detail" model without a second
//                              Navigator, so it renders identically headless at
//                              both sizes.
//
// The breakpoint ACCOUNTS FOR THE DETAIL PANE (G9 #208): three side-by-side
// panes (sidebar + list + detail) only earn their keep on an expanded window, so
// when a detail is open the expand threshold rises to [detailBreakpoint]. Below
// it — a mid-width desktop window, a split-screen tablet — the detail takes the
// FULL screen via the exact same compact layout, rather than crushing the list
// into a sliver beside it. Closing the detail drops the threshold back to
// [breakpoint], so the two-pane sidebar+list view returns at the same width.
// This is the "detail open → collapse two panes to one" rule; the per-row meta
// and subtask titles ellipsize (task_row / task_detail) so nothing in the
// narrow band that stays side-by-side (≥ [detailBreakpoint]) overflows.
//
// Back handling: an open drawer is dismissed by the framework's own Drawer
// back-handling; a [PopScope] turns a back with an open detail into
// [onCloseDetail] instead of popping the whole app. The full back-precedence
// ladder is T8.3.
//
// Safe areas (#166/#160): the app bar clears the status bar (Material insets it
// natively), the drawer content is inset from the top/bottom/left with an
// explicit un-notched fallback, the FAB floats above the bottom gesture pill and
// off the right edge (Scaffold's FAB location honours the view padding), and the
// full-screen detail is wrapped so its header clears the status bar. When the
// compact bar collapses out of the way (#244) the body takes its slot but stops
// at the status bar — rows never slide under the notch.
//
// flutter_adaptive_scaffold is discontinued, so this is deliberately a handful
// of framework primitives we own and golden-test at both form factors.

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import 'compact_chrome.dart';
import 'detail_motion.dart';
import 'ime_inset_guard.dart';
import 'motion.dart';
import 'new_task_fab.dart';
import 'shell_nav_bar.dart';

export 'shell_nav_bar.dart' show ShellDestination, ShellNavBar;

/// Adaptive list-detail scaffold branching at [breakpoint].
class ListDetailScaffold extends StatelessWidget {
  const ListDetailScaffold({
    required this.sidebar,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.list,
    this.detail,
    this.onCloseDetail,
    this.title = '',
    this.detailTaskId,
    this.detailSlot,
    this.syncLine,
    this.onNewTask,
    this.composerOpen = false,
    this.scaffoldKey,
    this.sidebarWidth = defaultSidebarWidth,
    this.detailFraction = defaultDetailFraction,
    this.onSidebarWidthChanged,
    this.onDetailFractionChanged,
    this.onResetSidebarWidth,
    this.onResetDetailFraction,
    super.key,
  });

  /// The width breakpoint (logical pixels) between compact and expanded when NO
  /// detail is open (sidebar + list).
  static const double breakpoint = 600;

  /// The wider breakpoint used WHILE A DETAIL IS OPEN (G9 #208). Side-by-side
  /// list + detail needs an expanded window; below this the detail goes
  /// full-screen through the compact layout instead of squeezing three panes
  /// into a mid-width window. Mirrors the Material "expanded window" floor.
  static const double detailBreakpoint = 840;

  // Draggable-divider geometry (#210). The expanded layout only: the sidebar
  // and the list/detail split are resizable, clamped so neither pane can be
  // crushed nor swallow the window, and double-clicking a handle resets it.

  /// Default sidebar width (logical px) — the pre-#210 fixed width.
  static const double defaultSidebarWidth = 260;

  /// Narrowest the sidebar may be dragged.
  static const double minSidebarWidth = 200;

  /// Widest the sidebar may be dragged.
  static const double maxSidebarWidth = 400;

  /// Default detail-pane width as a fraction of the list+detail region — the
  /// pre-#210 fixed 2:3 (list:detail) flex, i.e. detail = 3/5.
  static const double defaultDetailFraction = 0.6;

  /// Smallest share of the list+detail region the detail pane may take.
  static const double minDetailFraction = 0.3;

  /// Largest share of the list+detail region the detail pane may take.
  static const double maxDetailFraction = 0.7;

  /// The full navigation sidebar (smart views + lists + footer). The left panel
  /// in the expanded layout; the slide-in [Drawer] content when compact.
  final Widget sidebar;

  /// Bottom-nav destinations for the compact layout, in display order.
  final List<ShellDestination> destinations;

  /// Index of the selected destination, or `null` when the active view is NOT
  /// one of [destinations] — a list opened from the drawer (#236). The bar then
  /// shows no destination as selected rather than keeping the last smart view
  /// highlighted and claiming the user is somewhere they are not.
  final int? selectedIndex;

  /// Called when the user picks a compact bottom-nav destination.
  final ValueChanged<int> onDestinationSelected;

  /// The list pane — always present (left pane when expanded, base screen when
  /// compact).
  final Widget list;

  /// The detail pane, or `null` when nothing is selected.
  final Widget? detail;

  /// Called when a compact back gesture should close the open detail.
  final VoidCallback? onCloseDetail;

  /// The compact app-bar title (the active view's name). Ignored when expanded.
  final String title;

  /// The open task's id (#253) — the ONE thing the compact container transform
  /// needs from the router: whether the rect a row last recorded belongs to the
  /// task now opening. A [detail] with no id (or one that no row reported)
  /// simply fades in.
  final String? detailTaskId;

  /// The open task's position in the view's visible ordering (#253), so the
  /// detail's prev/next step knows which way along that ordering it is going.
  /// `null` for a task with no place in it — a subtask, or a filtered-out task.
  final int? detailSlot;

  /// The quiet sync line (#255), OVERLAID on the compact app bar's bottom edge.
  /// A widget rather than a bool so this scaffold keeps no provider dependency
  /// (it is mounted with no [ProviderScope] in goldens and layout tests), and
  /// so a sync starting rebuilds the line alone. It rides the bar's
  /// `flexibleSpace`, which adds no height whatsoever: a sync can never move a
  /// row. `null` on a layout that shows no sync at all.
  final Widget? syncLine;

  /// The compact FAB action — opens the touch composer (never creates an empty
  /// task). `null` hides the FAB entirely: the fine-pointer layout has its
  /// always-visible quick-add bar instead (#216), and bare goldens pass nothing.
  final VoidCallback? onNewTask;

  /// Whether the touch composer is currently on screen (#234). The FAB and the
  /// composer are ONE surface: while the composer is up there is no FAB, so it
  /// can never render over the sheet it opened. Ignored when expanded.
  final bool composerOpen;

  /// The key for the compact [Scaffold], so the shell can close the drawer after
  /// a navigation. `null` in tests that do not drive the drawer.
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Persisted sidebar width for the expanded layout (#210). Clamped internally
  /// to [minSidebarWidth]–[maxSidebarWidth]; ignored by the compact layout.
  final double sidebarWidth;

  /// Persisted detail-pane fraction for the expanded layout (#210). Clamped
  /// internally to [minDetailFraction]–[maxDetailFraction]; compact-ignored.
  final double detailFraction;

  /// Called once when a sidebar-divider drag ends, with the new clamped width
  /// to persist. `null` disables persistence (the drag still tracks live).
  final ValueChanged<double>? onSidebarWidthChanged;

  /// Called once when a list/detail-divider drag ends, with the new clamped
  /// fraction to persist. `null` disables persistence.
  final ValueChanged<double>? onDetailFractionChanged;

  /// Called when the sidebar handle is double-clicked to reset the default.
  final VoidCallback? onResetSidebarWidth;

  /// Called when the list/detail handle is double-clicked to reset the default.
  final VoidCallback? onResetDetailFraction;

  bool get _showingDetail => detail != null;

  @override
  Widget build(BuildContext context) {
    // The detail pane is accounted for: an open detail raises the expand
    // threshold so a mid-width window collapses to the full-screen compact
    // detail rather than a crushed three-pane row (G9 #208).
    final effectiveBreakpoint = _showingDetail ? detailBreakpoint : breakpoint;
    final expanded = MediaQuery.sizeOf(context).width >= effectiveBreakpoint;
    // One PopScope for both layouts: a back gesture with a detail open turns
    // into [onCloseDetail] rather than popping the whole app. An OPEN DRAWER is
    // handled by the framework's own Drawer back-dismissal (which unmounts with
    // the compact layout on rotation), so it is deliberately NOT tracked here —
    // caching "drawer open" would deaden the back button after a phone rotates
    // into the expanded layout mid-open. Note the [list] is kept mounted in BOTH
    // layouts (a Row child when expanded, Offstage when compact) so the
    // ShellRoute's Navigator is never torn down under go_router — unmounting it
    // crashes go_router's popRoute.
    // Every layout is wrapped: a bottom inset that outlives the keyboard would
    // otherwise reserve half the screen for a keyboard that is gone, leaving a
    // black region under the body for the rest of the session (#233).
    return ImeInsetGuard(
      child: PopScope(
        canPop: !_showingDetail,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _showingDetail) onCloseDetail?.call();
        },
        child: expanded ? _buildExpanded() : _buildCompact(),
      ),
    );
  }

  Widget _buildExpanded() {
    return Scaffold(
      body: SafeArea(
        child: _ResizableExpanded(
          sidebar: sidebar,
          list: list,
          detail: _showingDetail ? detail : null,
          sidebarWidth: sidebarWidth.clamp(minSidebarWidth, maxSidebarWidth),
          detailFraction: detailFraction.clamp(
            minDetailFraction,
            maxDetailFraction,
          ),
          onSidebarWidthChanged: onSidebarWidthChanged,
          onDetailFractionChanged: onDetailFractionChanged,
          onResetSidebarWidth: onResetSidebarWidth,
          onResetDetailFraction: onResetDetailFraction,
        ),
      ),
    );
  }

  Widget _buildCompact() {
    // An open detail owns the whole screen — no app bar, drawer, nav, or FAB —
    // but it GETS there by growing out of the row that was tapped (#253), so
    // the chrome it covers stays mounted underneath for as long as the
    // transform is running, and comes back under the surface as it shrinks
    // away. Fully open, the whole shell is [Offstage]: mounted (which keeps the
    // ShellRoute's Navigator alive and the list's scroll offset with it),
    // painting nothing, hit-testing nothing, and invisible to finders and to a
    // screen reader alike.
    return _CompactDetailLayer(
      detail: _showingDetail ? detail : null,
      detailTaskId: detailTaskId,
      detailSlot: detailSlot,
      onCloseDetail: onCloseDetail,
      shell: _CompactShell(
        scaffoldKey: scaffoldKey,
        title: title,
        syncLine: syncLine,
        sidebar: sidebar,
        list: list,
        destinations: destinations,
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        onNewTask: onNewTask,
        composerOpen: composerOpen,
      ),
    );
  }
}

/// The compact layout's two layers (#253): the phone chrome, and the detail
/// that grows out of one of its rows to cover it.
///
/// Stateful because the CLOSE has to outlive the route change that causes it.
/// The moment the URL drops the task, [detail] is `null` — but the surface the
/// user is watching still has to shrink back into the row it came from, so the
/// last panel is held here until the transform reaches zero, over a shell that
/// is already back on screen underneath it.
///
/// It also owns the Android predictive back gesture: with a detail open, a
/// system back drag drives this transform DIRECTLY, so the surface follows the
/// finger and snaps back if the gesture is abandoned. Under reduced motion the
/// gesture is declined outright and the framework performs its ordinary pop —
/// a user who turned animations off did not ask for a scrubbable one.
class _CompactDetailLayer extends StatefulWidget {
  const _CompactDetailLayer({
    required this.shell,
    required this.detail,
    required this.detailTaskId,
    required this.detailSlot,
    required this.onCloseDetail,
  });

  /// The phone chrome — app bar, drawer, list, nav bar, FAB.
  final Widget shell;

  /// The open detail panel, or `null` when none is open.
  final Widget? detail;

  final String? detailTaskId;
  final int? detailSlot;

  /// Closes the detail — the same callback the scaffold's [PopScope] uses. The
  /// predictive back gesture commits through it, so a gesture-driven close and
  /// a button-driven close are the same close.
  final VoidCallback? onCloseDetail;

  @override
  State<_CompactDetailLayer> createState() => _CompactDetailLayerState();
}

class _CompactDetailLayerState extends State<_CompactDetailLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 0 = the row, 1 = the whole screen. Seeded AT its end state when a detail
  /// is already open on mount: a shell that comes up with a task selected (a
  /// restored URL, a rotation, a golden) is not an event — nothing was opened,
  /// it simply is open. The same rule the list choreography follows for the
  /// first contents of a view (#251).
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: MotionDurations.emphasized,
    value: widget.detail == null ? 0 : 1,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _open,
    curve: MotionCurves.standard,
  );

  /// The panel being drawn — [_CompactDetailLayer.detail] while one is open,
  /// and the last one for as long as it is still leaving.
  Widget? _shown;

  /// Its slot in the view's ordering, held with it so a prev/next step measured
  /// against a panel that is already gone still reads the right direction.
  int? _shownSlot;

  /// The row rect the transform grows out of, in THIS widget's own coordinate
  /// space; `null` when the open did not come from a row.
  Rect? _origin;

  /// Whether a predictive back gesture is currently driving [_open].
  bool _backGesture = false;

  /// Whether motion travels here at all — cached from the last dependency
  /// change, because the back-gesture callbacks arrive from the platform
  /// outside any build and must not go looking up the tree from there.
  bool _motion = true;

  @override
  void initState() {
    super.initState();
    _shown = widget.detail;
    _shownSlot = widget.detailSlot;
    _open.addStatusListener(_onStatus);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = Motion.of(context);
    _motion = motion.enabled;
    _open.duration = motion.resolve(MotionDurations.emphasized);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _curved.dispose();
    _open.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    // The surface has finished shrinking away: let the panel go. Guarded on the
    // CURRENT props, so a detail re-opened mid-close (the transform reverses
    // back up before reaching zero) is never dropped.
    if (status != AnimationStatus.dismissed) return;
    if (widget.detail != null || _shown == null) return;
    setState(() {
      _shown = null;
      _shownSlot = null;
      _origin = null;
    });
  }

  @override
  void didUpdateWidget(_CompactDetailLayer old) {
    super.didUpdateWidget(old);
    if (widget.detail != null) {
      _shown = widget.detail;
      _shownSlot = widget.detailSlot;
      if (old.detail == null) {
        _origin = _resolveOrigin();
        _open.forward();
      }
    } else if (old.detail != null) {
      _backGesture = false;
      _open.reverse();
    }
  }

  /// The tapped row's rect, converted from the screen coordinates the row
  /// recorded into this layer's own space. Resolved at OPEN time, off the
  /// previous frame's layout — the layer has been on screen showing the list,
  /// so its render object is attached and sized.
  Rect? _resolveOrigin() {
    final rect = DetailOriginScope.maybeOf(
      context,
    )?.rectFor(widget.detailTaskId);
    if (rect == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return rect.shift(-box.localToGlobal(Offset.zero));
  }

  // ── Android predictive back ──────────────────────────────────────────────
  // Returning true claims the gesture: this observer, and only this observer,
  // then hears its updates, and the framework performs no pop of its own — the
  // commit below closes the detail through the app's own path instead.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!mounted || widget.detail == null || widget.onCloseDetail == null) {
      return false;
    }
    if (!_open.isCompleted || !_motion) return false;
    _open.stop();
    _backGesture = true;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_backGesture) return;
    _open.value = 1 - backEvent.progress.clamp(0.0, 1.0);
  }

  @override
  void handleCommitBackGesture() {
    if (!_backGesture) return;
    _backGesture = false;
    // The route change lands as a prop update, whose reverse picks the
    // transform up exactly where the finger left it.
    widget.onCloseDetail?.call();
  }

  @override
  void handleCancelBackGesture() {
    if (!_backGesture) return;
    _backGesture = false;
    _open.forward();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _shown;
    return AnimatedBuilder(
      animation: _curved,
      child: widget.shell,
      builder: (context, shell) {
        final t = _curved.value.clamp(0.0, 1.0);
        final covered = detail != null && t >= 1;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Keyed so the shell keeps its element — and with it the list's
            // scroll offset and every row's state — as the detail comes and
            // goes above it. TickerMode stops anything in there animating to
            // an audience of nobody while it is covered.
            TickerMode(
              key: const ValueKey('compact-shell'),
              enabled: !covered,
              // Covered, the shell is out of reach in every sense: no paint,
              // no hit test, no semantics, no focus. Focus matters as much as
              // the rest — a field left focused down there would keep the
              // keyboard up over a detail that never asked for one. It also
              // stops answering taps the moment a detail EXISTS, so a stray
              // second tap during the 400ms it takes to arrive cannot open
              // something else underneath it.
              child: ExcludeFocus(
                excluding: covered,
                child: Offstage(
                  offstage: covered,
                  child: IgnorePointer(ignoring: detail != null, child: shell),
                ),
              ),
            ),
            if (detail != null)
              Positioned.fill(
                key: const ValueKey('compact-detail'),
                child: DetailContainerTransform(
                  progress: t,
                  origin: _origin,
                  // The panel's own Scaffold: it owns the keyboard inset for
                  // the fields inside it, and paints the surface the transform
                  // grows into. SafeArea so its header clears the status bar
                  // (#166).
                  child: Scaffold(
                    body: SafeArea(
                      child: DetailSharedAxis(slot: _shownSlot, child: detail),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The compact (phone) chrome: ONE app bar (title + the hosted list's own
/// actions), drawer, list, bottom nav — and the one touch creation affordance
/// floating over it.
///
/// Stateful for the chrome that MOVES (#234, #244). A FAB parked over the list
/// — and a bar pinned above it — are obstructions the moment the user starts
/// reading, so this listens to the list's own scrolling and pulls BOTH out of
/// the way while the content moves up, returning them together as soon as the
/// scroll reverses or stops. One gesture, one [scrollThreshold], one state.
///
/// The FAB comes and goes without moving a single row (the list already
/// reserves [NewTaskFab.clearance] at its foot); the app bar takes its slot
/// with it, so the rows follow it up rather than leaving a hole behind.
class _CompactShell extends StatefulWidget {
  const _CompactShell({
    required this.title,
    required this.syncLine,
    required this.sidebar,
    required this.list,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onNewTask,
    required this.composerOpen,
    required this.scaffoldKey,
  });

  final String title;
  final Widget? syncLine;
  final Widget sidebar;
  final Widget list;
  final List<ShellDestination> destinations;

  /// The selected destination, or `null` for an out-of-set view (#236).
  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onNewTask;
  final bool composerOpen;
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// How far the list must travel in one direction before the chrome reacts.
  /// Big enough that a nudge, a tap-jitter or a settling fling tail does not
  /// flicker it; small enough that a deliberate scroll clears the corner
  /// immediately. Shared by the FAB and the app bar so they move as one.
  static const double scrollThreshold = 24;

  @override
  State<_CompactShell> createState() => _CompactShellState();
}

class _CompactShellState extends State<_CompactShell>
    with SingleTickerProviderStateMixin {
  /// Distance travelled since the last direction change: positive while the
  /// content moves up (the user is scrolling down the list).
  double _travelled = 0;

  /// Whether scrolling is currently holding the chrome off screen.
  bool _hiddenByScroll = false;

  /// Whether a soft keyboard is up. A bottom view inset means something has
  /// focus, and a user who is typing must never be left without the bar (nor
  /// shown a "new task" button floating over the field — #233).
  bool _imeUp = false;

  /// How much of the app bar is on screen: 1 pinned, 0 collapsed. Driven at the
  /// FAB's own pace so the two halves of the chrome leave and return together.
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: NewTaskFab.transition,
    value: 1,
  );

  /// The channel the hosted list publishes its toolbar actions into (#244).
  final ListChromeController _chrome = ListChromeController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" (Android) / reduced motion: the bar still leaves and
    // returns, it just stops travelling to get there — the same rule the
    // completion collapse follows (#241).
    _bar.duration = Motion.of(context).resolve(NewTaskFab.transition);
    final imeUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (imeUp == _imeUp) return;
    _imeUp = imeUp;
    _syncBar();
  }

  @override
  void dispose() {
    _bar.dispose();
    _chrome.dispose();
    super.dispose();
  }

  /// Drive the bar to where the current state says it belongs. A raised
  /// keyboard CANCELS the hide outright: whatever the scroll was doing, the bar
  /// comes back.
  void _syncBar() {
    if (_hiddenByScroll && !_imeUp) {
      _bar.reverse();
    } else {
      _bar.forward();
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollEndNotification) {
      // At rest the chrome is always there — the list foot is padded for the
      // FAB, and a bar you cannot reach at rest is a bar you cannot use.
      _travelled = 0;
      if (_hiddenByScroll) _setHidden(false);
    } else if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta == 0) return false;
      // A reversal starts the count again, so "24dp down then 24dp up" reads as
      // a reversal rather than as 48dp of downward travel.
      if (delta.sign != _travelled.sign) _travelled = 0;
      _travelled += delta;
      if (_travelled > _CompactShell.scrollThreshold && !_hiddenByScroll) {
        _setHidden(true);
      } else if (_travelled < -_CompactShell.scrollThreshold &&
          _hiddenByScroll) {
        _setHidden(false);
      }
    }
    return false;
  }

  void _setHidden(bool hidden) {
    setState(() => _hiddenByScroll = hidden);
    _syncBar();
  }

  @override
  Widget build(BuildContext context) {
    final onNewTask = widget.onNewTask;
    final topInset = MediaQuery.paddingOf(context).top;
    // Built ONCE per rebuild and handed to the collapse animation as its
    // pre-built child: the list is the expensive subtree and nothing in it
    // changes as the bar slides. Only the BODY's scrolling drives the chrome —
    // the drawer is the Scaffold's own child and its notifications never reach
    // this listener. SafeArea handles the side/bottom insets the bottom nav
    // does not (a landscape side notch); the TOP is left to the app bar.
    final body = CompactChromeScope(
      controller: _chrome,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SafeArea(top: false, child: widget.list),
      ),
    );
    return AnimatedBuilder(
      animation: _bar,
      child: body,
      builder: (context, body) {
        // The app bar auto-adds the hamburger (a drawer is present) and clears
        // the status bar itself; its title orients the user to the active view,
        // and the hosted list's own actions ride beside it — ONE bar (#244).
        final bar = CollapsingAppBar(
          shown: _bar.value,
          topPadding: topInset,
          bar: AppBar(
            title: Text(widget.title, overflow: TextOverflow.ellipsis),
            // The sync line lives in `flexibleSpace` — the one slot that fills
            // the bar without changing its preferred height (`bottom` would
            // add its own, pushing every row down the moment a sync began).
            // Bottom-aligned, so it sits on the bar's edge even while the bar
            // is sliding away under a scroll (#244).
            flexibleSpace: widget.syncLine == null
                ? null
                : Align(
                    alignment: Alignment.bottomCenter,
                    child: widget.syncLine,
                  ),
            actions: [
              ValueListenableBuilder<ListChromeActions?>(
                valueListenable: _chrome,
                builder: (context, actions, _) => actions == null
                    ? const SizedBox.shrink()
                    : CompactListActions(actions: actions),
              ),
            ],
          ),
        );
        // As the bar collapses its slot shrinks and the body's top rises with
        // it — but never past the status bar: rows must not slide under the
        // notch just because the bar went away.
        final statusBarFloor = math.max(
          0.0,
          topInset - bar.preferredSize.height,
        );
        return Scaffold(
          key: widget.scaffoldKey,
          // Keep inputs visible above the soft keyboard (IME) — the quick-add
          // bar and the detail's fields must never sit under the keyboard.
          resizeToAvoidBottomInset: true,
          appBar: bar,
          // The slide-in drawer IS the full sidebar. Inset its content past the
          // notch / status bar / gesture pill on the top, bottom, and left
          // edges, with a small explicit fallback so un-notched devices still
          // breathe.
          drawer: Drawer(
            child: SafeArea(
              minimum: const EdgeInsets.symmetric(vertical: 8),
              child: widget.sidebar,
            ),
          ),
          body: Padding(
            padding: EdgeInsets.only(top: statusBarFloor),
            child: body!,
          ),
          floatingActionButton: onNewTask == null
              ? null
              : NewTaskFab(
                  visible: !widget.composerOpen && !_imeUp && !_hiddenByScroll,
                  onPressed: onNewTask,
                ),
          bottomNavigationBar: ShellNavBar(
            destinations: widget.destinations,
            // Nullable by construction (#237): a list opened from the drawer is
            // not a destination, and the bar says so in pixels AND in semantics
            // — no sentinel index to draw over or explain away.
            selectedIndex: widget.selectedIndex,
            onDestinationSelected: widget.onDestinationSelected,
          ),
        );
      },
    );
  }
}

/// The expanded-layout body with two draggable dividers (#210): the sidebar/list
/// split and — when a detail is open — the list/detail split. Stateful so a drag
/// tracks the pointer live (setState per frame) while persistence fires only
/// ONCE, on drag end, keeping the prefs write off the per-frame path. The parent
/// re-seeds the local widths only when the persisted props actually change (a
/// drag end reports the same value it holds, so an unrelated rebuild — a new
/// task, a count tick — never clobbers an in-progress or just-finished drag).
class _ResizableExpanded extends StatefulWidget {
  const _ResizableExpanded({
    required this.sidebar,
    required this.list,
    required this.detail,
    required this.sidebarWidth,
    required this.detailFraction,
    required this.onSidebarWidthChanged,
    required this.onDetailFractionChanged,
    required this.onResetSidebarWidth,
    required this.onResetDetailFraction,
  });

  final Widget sidebar;
  final Widget list;
  final Widget? detail;
  final double sidebarWidth;
  final double detailFraction;
  final ValueChanged<double>? onSidebarWidthChanged;
  final ValueChanged<double>? onDetailFractionChanged;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetDetailFraction;

  @override
  State<_ResizableExpanded> createState() => _ResizableExpandedState();
}

class _ResizableExpandedState extends State<_ResizableExpanded>
    with SingleTickerProviderStateMixin {
  late double _sidebarWidth = widget.sidebarWidth;
  late double _detailFraction = widget.detailFraction;

  /// The detail pane's arrival and departure (#253), as ONE span: the pane
  /// slides in from the end edge while the list eases to its narrower width,
  /// and only once it has landed does the #221 open-row highlight fade in.
  /// Reversed, the highlight goes first and the pane leaves after it.
  ///
  /// Seeded at its end state when a detail is already open on mount — a window
  /// restored with a task selected did not just open it.
  late final AnimationController _pane = AnimationController(
    vsync: this,
    duration: MotionDurations.detailPane,
    value: widget.detail == null ? 0 : 1,
  );

  /// The pane's own travel: the first beat of [_pane].
  late final CurvedAnimation _slide = CurvedAnimation(
    parent: _pane,
    curve: const Interval(
      0,
      MotionDurations.detailPaneSlideFraction,
      curve: MotionCurves.standard,
    ),
  );

  /// The open-row highlight's arrival: the second beat, which is flat at zero
  /// for the whole of the first.
  late final CurvedAnimation _reveal = CurvedAnimation(
    parent: _pane,
    curve: const Interval(
      MotionDurations.detailPaneSlideFraction,
      1,
      curve: MotionCurves.enter,
    ),
  );

  /// The pane being drawn — [_ResizableExpanded.detail] while one is open, and
  /// the last one for as long as it is still sliding out.
  late Widget? _shown = widget.detail;

  @override
  void initState() {
    super.initState();
    _pane.addStatusListener(_onPaneStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pane.duration = Motion.of(context).resolve(MotionDurations.detailPane);
  }

  @override
  void dispose() {
    _slide.dispose();
    _reveal.dispose();
    _pane.dispose();
    super.dispose();
  }

  void _onPaneStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (widget.detail != null || _shown == null) return;
    setState(() => _shown = null);
  }

  @override
  void didUpdateWidget(_ResizableExpanded old) {
    super.didUpdateWidget(old);
    if (widget.detail != null) {
      _shown = widget.detail;
      if (old.detail == null) _pane.forward();
    } else if (old.detail != null) {
      _pane.reverse();
    }
    // Only adopt a prop change that did NOT originate from our own drag end
    // (where the incoming value already equals the local one). A cross-rebuild
    // with unchanged props leaves the live drag state untouched.
    if (widget.sidebarWidth != old.sidebarWidth) {
      _sidebarWidth = widget.sidebarWidth;
    }
    if (widget.detailFraction != old.detailFraction) {
      _detailFraction = widget.detailFraction;
    }
  }

  void _dragSidebar(double dx) {
    setState(() {
      _sidebarWidth = (_sidebarWidth + dx).clamp(
        ListDetailScaffold.minSidebarWidth,
        ListDetailScaffold.maxSidebarWidth,
      );
    });
  }

  void _resetSidebar() {
    setState(() => _sidebarWidth = ListDetailScaffold.defaultSidebarWidth);
    widget.onResetSidebarWidth?.call();
  }

  void _dragDetail(double dx, double region) {
    if (region <= 0) return;
    setState(() {
      // Dragging the handle right grows the list and shrinks the detail, so the
      // detail fraction falls by the pointer's share of the region.
      _detailFraction = (_detailFraction - dx / region).clamp(
        ListDetailScaffold.minDetailFraction,
        ListDetailScaffold.maxDetailFraction,
      );
    });
  }

  void _resetDetail() {
    setState(() => _detailFraction = ListDetailScaffold.defaultDetailFraction);
    widget.onResetDetailFraction?.call();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _shown;
    return Row(
      children: [
        SizedBox(
          key: const Key('expanded-sidebar'),
          width: _sidebarWidth,
          child: widget.sidebar,
        ),
        _ResizeHandle(
          key: const Key('sidebar-resize-handle'),
          semanticLabel: 'Resize sidebar',
          onDelta: _dragSidebar,
          onDragEnd: () => widget.onSidebarWidthChanged?.call(_sidebarWidth),
          onReset: _resetSidebar,
        ),
        Expanded(
          child: detail == null
              ? widget.list
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final region = constraints.maxWidth;
                    // Detail is width-pinned to its fraction of the region; the
                    // list flexes into the remainder, so no configuration
                    // overflows the row (#208 still holds).
                    final detailWidth = _detailFraction * region;
                    // Handle and pane travel as ONE slot, so the list's edge
                    // eases the whole way rather than jumping the handle's
                    // width at the start of the slide.
                    final slotWidth = detailWidth + _ResizeHandle.hitWidth;
                    return AnimatedBuilder(
                      animation: _slide,
                      builder: (context, _) {
                        final arrived = _slide.value.clamp(0.0, 1.0);
                        return Row(
                          children: [
                            // The list eases into what the slot leaves it —
                            // and learns how far the pane has come, so the
                            // #221 highlight can wait for it to land.
                            Expanded(
                              child: DetailRevealScope(
                                reveal: _reveal,
                                child: widget.list,
                              ),
                            ),
                            SizedBox(
                              width: slotWidth * arrived,
                              child: ClipRect(
                                clipBehavior: arrived >= 1
                                    ? Clip.none
                                    : Clip.hardEdge,
                                // The pane is LAID OUT at its settled width the
                                // whole way in and anchored to the slot's
                                // leading edge, so it slides in from off the
                                // end edge instead of being squeezed out of a
                                // growing box — a pane that re-laid-out every
                                // frame would reflow its text as it travelled.
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: slotWidth,
                                  maxWidth: slotWidth,
                                  // A divider you can grab while it is still
                                  // flying in is a wobble, not a control.
                                  child: IgnorePointer(
                                    ignoring: arrived < 1,
                                    child: Row(
                                      children: [
                                        _ResizeHandle(
                                          key: const Key(
                                            'detail-resize-handle',
                                          ),
                                          semanticLabel: 'Resize detail panel',
                                          onDelta: (dx) =>
                                              _dragDetail(dx, region),
                                          onDragEnd: () => widget
                                              .onDetailFractionChanged
                                              ?.call(_detailFraction),
                                          onReset: _resetDetail,
                                        ),
                                        SizedBox(
                                          key: const Key('expanded-detail'),
                                          width: detailWidth,
                                          child: detail,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A draggable divider: a comfortable hit area over the 1px [VerticalDivider],
/// with a column-resize cursor for the mouse and double-click-to-reset. Reports
/// horizontal drag deltas so the parent owns the clamp and the persistence.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.onDelta,
    required this.onDragEnd,
    required this.onReset,
    required this.semanticLabel,
    super.key,
  });

  /// The width of the transparent grab area straddling the 1px divider.
  static const double hitWidth = 11;

  final ValueChanged<double> onDelta;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Track from the very first pixel (no 18px slop dead-zone), so the pane
        // edge follows the pointer 1:1 the instant the drag begins.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onDoubleTap: onReset,
        child: Semantics(
          label: semanticLabel,
          child: const SizedBox(
            width: hitWidth,
            child: Center(child: VerticalDivider(width: 1)),
          ),
        ),
      ),
    );
  }
}
