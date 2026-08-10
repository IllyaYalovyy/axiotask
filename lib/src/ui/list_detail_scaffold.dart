// The one hand-rolled adaptive shell (RFC-011 §7 / RESEARCH §7). One widget,
// one width breakpoint, the SAME list and detail children composed both ways —
// no forked screens.
//
//   width ≥ 600dp (expanded): the sidebar + list + side-by-side detail pane.
//   width <  600dp (compact):  an app bar (hamburger + view title), a slide-in
//                              drawer holding the full sidebar, a bottom
//                              NavigationBar, and a "new task" FAB. An open
//                              detail covers the list full-bleed and the chrome
//                              hides — the "pushed detail" model without a second
//                              Navigator, so it renders identically headless at
//                              both sizes.
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
// full-screen detail is wrapped so its header clears the status bar.
//
// flutter_adaptive_scaffold is discontinued, so this is deliberately a handful
// of framework primitives we own and golden-test at both form factors.

import 'package:flutter/material.dart';

/// A single navigation destination for the shell (rail + bar share this data).
class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// Icon shown when the destination is not selected.
  final IconData icon;

  /// Icon shown when the destination is selected.
  final IconData selectedIcon;

  /// The destination label (nav text).
  final String label;
}

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
    this.scaffoldKey,
    super.key,
  });

  /// The single width breakpoint (logical pixels) between compact and expanded.
  static const double breakpoint = 600;

  /// The full navigation sidebar (smart views + lists + footer). The left panel
  /// in the expanded layout; the slide-in [Drawer] content when compact.
  final Widget sidebar;

  /// Bottom-nav destinations for the compact layout, in display order.
  final List<ShellDestination> destinations;

  /// Index of the selected destination.
  final int selectedIndex;

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

  /// The compact FAB action — focuses the always-visible quick-add input (never
  /// creates an empty task). `null` hides the FAB (e.g. under a bare golden).
  final VoidCallback? onNewTask;

  /// The key for the compact [Scaffold], so the shell can close the drawer after
  /// a navigation. `null` in tests that do not drive the drawer.
  final GlobalKey<ScaffoldState>? scaffoldKey;

  bool get _showingDetail => detail != null;

  @override
  Widget build(BuildContext context) {
    final expanded = MediaQuery.sizeOf(context).width >= breakpoint;
    // One PopScope for both layouts: a back gesture with a detail open turns
    // into [onCloseDetail] rather than popping the whole app. An OPEN DRAWER is
    // handled by the framework's own Drawer back-dismissal (which unmounts with
    // the compact layout on rotation), so it is deliberately NOT tracked here —
    // caching "drawer open" would deaden the back button after a phone rotates
    // into the expanded layout mid-open. Note the [list] is kept mounted in BOTH
    // layouts (a Row child when expanded, Offstage when compact) so the
    // ShellRoute's Navigator is never torn down under go_router — unmounting it
    // crashes go_router's popRoute.
    return PopScope(
      canPop: !_showingDetail,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showingDetail) onCloseDetail?.call();
      },
      child: expanded ? _buildExpanded() : _buildCompact(),
    );
  }

  Widget _buildExpanded() {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            sidebar,
            const VerticalDivider(width: 1),
            Expanded(flex: 2, child: list),
            if (_showingDetail) ...[
              const VerticalDivider(width: 1),
              Expanded(flex: 3, child: detail!),
            ],
          ],
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

    return Scaffold(
      key: scaffoldKey,
      // Keep inputs visible above the soft keyboard (IME) — the quick-add bar
      // and the detail's fields must never sit under the keyboard.
      resizeToAvoidBottomInset: true,
      // The app bar auto-adds the hamburger (a drawer is present) and clears the
      // status bar itself; its title orients the user to the active view.
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      // The slide-in drawer IS the full sidebar. Inset its content past the
      // notch / status bar / gesture pill on the top, bottom, and left edges,
      // with a small explicit fallback so un-notched devices still breathe.
      drawer: Drawer(
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(vertical: 8),
          child: sidebar,
        ),
      ),
      // The list keeps the app bar's top inset; SafeArea handles the side/bottom
      // insets the bottom nav does not (a landscape side notch).
      body: SafeArea(top: false, child: list),
      floatingActionButton: onNewTask == null
          ? null
          : FloatingActionButton(
              tooltip: 'New task',
              onPressed: onNewTask,
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
