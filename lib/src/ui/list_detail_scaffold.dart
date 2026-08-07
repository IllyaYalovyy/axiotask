// The one hand-rolled adaptive shell (RFC-011 §7 / RESEARCH §7). One widget,
// one width breakpoint, the SAME list and detail children composed both ways —
// no forked screens.
//
//   width ≥ 600dp (expanded): NavigationRail + list + side-by-side detail pane.
//   width <  600dp (compact):  NavigationBar; the detail, when open, covers the
//                              list full-bleed and the nav bar hides — the
//                              "pushed detail" model without a second Navigator,
//                              so it renders identically headless at both sizes.
//
// The compact back handling lives in a [PopScope]: when a detail is open, a
// system/Android back is intercepted and turned into [onCloseDetail] instead of
// popping the whole app. That PopScope is the back_dispatcher skeleton (T2.2);
// the actual detail content is a placeholder until T2.4.
//
// flutter_adaptive_scaffold is discontinued, so this is deliberately ~100 lines
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
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.list,
    this.detail,
    this.onCloseDetail,
    super.key,
  });

  /// The single width breakpoint (logical pixels) between compact and expanded.
  static const double breakpoint = 600;

  /// Navigation destinations, in display order.
  final List<ShellDestination> destinations;

  /// Index of the selected destination.
  final int selectedIndex;

  /// Called when the user picks a destination.
  final ValueChanged<int> onDestinationSelected;

  /// The list pane — always present (left pane when expanded, base screen when
  /// compact).
  final Widget list;

  /// The detail pane, or `null` when nothing is selected.
  final Widget? detail;

  /// Called when a compact back gesture should close the open detail.
  final VoidCallback? onCloseDetail;

  bool get _showingDetail => detail != null;

  @override
  Widget build(BuildContext context) {
    final expanded = MediaQuery.sizeOf(context).width >= breakpoint;
    // One PopScope for both layouts: a back gesture with a detail open closes
    // the detail rather than popping the whole app (the back_dispatcher
    // skeleton). Note the [list] is kept mounted in BOTH layouts (a Row child
    // when expanded, Offstage when compact) so the ShellRoute's Navigator is
    // never torn down under go_router — unmounting it crashes go_router's
    // popRoute (its _findCurrentNavigators dereferences the shell navigator).
    return PopScope(
      canPop: !_showingDetail,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onCloseDetail?.call();
      },
      child: expanded ? _buildExpanded() : _buildCompact(),
    );
  }

  Widget _buildExpanded() {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
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
    return Scaffold(
      body: SafeArea(
        // Force the Stack to fill the screen. Without this it would size to its
        // only non-positioned child — the [Offstage] list, which collapses to
        // 0×0 while the detail is open — starving the detail pane of height (a
        // lazy ListView in it would then build zero rows).
        child: SizedBox.expand(
          child: Stack(
            children: [
              // The list stays mounted (keeps the ShellRoute Navigator alive);
              // Offstage hides it from paint/hit-test and from finders when the
              // detail covers it.
              Offstage(offstage: _showingDetail, child: list),
              if (_showingDetail) Positioned.fill(child: detail!),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _showingDetail
          ? null
          : NavigationBar(
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
