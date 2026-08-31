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

import 'compact_chrome.dart';
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
    // An open detail owns the whole screen — no app bar, drawer, nav, or FAB.
    // Its own header is wrapped in a SafeArea so it clears the status bar (#166).
    if (_showingDetail) {
      return Scaffold(
        // Force the Stack to fill the screen. Without this it would size to its
        // only non-positioned child — the [Offstage] list, which collapses to
        // 0×0 — starving the detail pane of height (a lazy ListView in it would
        // then build zero rows).
        body: SizedBox.expand(
          child: Stack(
            children: [
              // The list stays mounted (keeps the ShellRoute Navigator alive);
              // Offstage hides it from paint/hit-test and from finders.
              Offstage(offstage: true, child: list),
              Positioned.fill(child: SafeArea(child: detail!)),
            ],
          ),
        ),
      );
    }

    return _CompactShell(
      scaffoldKey: scaffoldKey,
      title: title,
      sidebar: sidebar,
      list: list,
      destinations: destinations,
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      onNewTask: onNewTask,
      composerOpen: composerOpen,
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

class _ResizableExpandedState extends State<_ResizableExpanded> {
  late double _sidebarWidth = widget.sidebarWidth;
  late double _detailFraction = widget.detailFraction;

  @override
  void didUpdateWidget(_ResizableExpanded old) {
    super.didUpdateWidget(old);
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
          child: widget.detail == null
              ? widget.list
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final region = constraints.maxWidth;
                    // Detail is width-pinned to its fraction of the region; the
                    // list flexes into the remainder, so no configuration
                    // overflows the row (#208 still holds).
                    final detailWidth = _detailFraction * region;
                    return Row(
                      children: [
                        Expanded(child: widget.list),
                        _ResizeHandle(
                          key: const Key('detail-resize-handle'),
                          semanticLabel: 'Resize detail panel',
                          onDelta: (dx) => _dragDetail(dx, region),
                          onDragEnd: () => widget.onDetailFractionChanged?.call(
                            _detailFraction,
                          ),
                          onReset: _resetDetail,
                        ),
                        SizedBox(
                          key: const Key('expanded-detail'),
                          width: detailWidth,
                          child: widget.detail,
                        ),
                      ],
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
