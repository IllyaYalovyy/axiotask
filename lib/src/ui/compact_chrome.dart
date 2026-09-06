// ONE bar on a phone (#244) — the seam between the compact shell, which owns
// the app bar, and the list, which owns the actions that belong in it.
//
// The list view used to stack its own toolbar (search, add-multiple, sort,
// show-completed) under the shell's app bar: two full-width bars plus dividers
// above the first row, neither of which ever moved. On a 6-inch screen that is
// roughly a quarter of the display spent on chrome. So on the COMPACT shell the
// toolbar's actions move INTO the app bar and the second bar disappears.
//
// The list cannot reach up into the [Scaffold] that hosts it (it is the
// ShellRoute's swappable child, mounted under a nested Navigator), so the shell
// hands a [ListChromeController] down through [CompactChromeScope] and the list
// publishes its actions into it — the same "publish a handle upward" shape the
// selection/rename back-handles already use (providers.dart), except this one
// is owned by the shell's own State rather than app-wide: no provider means the
// scaffold still pumps in the tests that mount it with no ProviderScope.
//
// The presence of the scope IS the switch. Hosted → the list omits its inline
// toolbar and publishes; not hosted (the expanded layout, or a bare test
// harness) → the list renders exactly what it always did. Width never decides,
// so the mid-width band where an open detail collapses the shell (#208) cannot
// end up with the actions in neither place.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/task_view.dart' show SortMode;
import 'sort_dropdown.dart';

/// The list-wide actions the compact app bar renders on the list's behalf.
///
/// Value-equal by construction so republishing an unchanged set is a no-op: the
/// callbacks are METHOD TEAR-OFFS of the list's state (`_openSearch`, not
/// `() => _openSearch()`), and two tear-offs of the same method on the same
/// object are equal in Dart. A closure literal here would make every list
/// rebuild look like a change and drive the app bar in a loop.
@immutable
class ListChromeActions {
  const ListChromeActions({
    required this.sort,
    required this.showCompleted,
    required this.onSearch,
    required this.onSelectTasks,
    required this.selectTasksEnabled,
    required this.onBulkAdd,
    required this.onSort,
    required this.onShowCompleted,
    required this.onClearCompleted,
    required this.onExport,
  });

  /// The active sort order for the current view.
  final SortMode sort;

  /// Whether completed tasks are currently shown.
  final bool showCompleted;

  /// Open the search overlay.
  final VoidCallback onSearch;

  /// Enter multi-select with nothing selected (#245). `null` drops the entry —
  /// a mouse reaches selection by Ctrl-click and the right-click menu instead.
  final VoidCallback? onSelectTasks;

  /// Whether that entry is live; `false` greys it out (the mode is already on)
  /// without removing it, so the menu never re-flows under the finger.
  final bool selectTasksEnabled;

  /// Open the bulk-add dialog; `null` disables it (no list to target).
  final VoidCallback? onBulkAdd;

  /// Pick a sort order for the current view.
  final ValueChanged<SortMode> onSort;

  /// Show or hide completed tasks.
  final ValueChanged<bool> onShowCompleted;

  /// Permanently clear the completed tasks of the current list; `null` drops
  /// the entry (not a concrete list, or completed tasks are hidden).
  final VoidCallback? onClearCompleted;

  /// Open the export sheet for the current view (#297); `null` drops the entry.
  final VoidCallback? onExport;

  @override
  bool operator ==(Object other) =>
      other is ListChromeActions &&
      other.sort == sort &&
      other.showCompleted == showCompleted &&
      other.onSearch == onSearch &&
      other.onSelectTasks == onSelectTasks &&
      other.selectTasksEnabled == selectTasksEnabled &&
      other.onBulkAdd == onBulkAdd &&
      other.onSort == onSort &&
      other.onShowCompleted == onShowCompleted &&
      other.onClearCompleted == onClearCompleted &&
      other.onExport == onExport;

  @override
  int get hashCode => Object.hash(
    sort,
    showCompleted,
    onSearch,
    onSelectTasks,
    selectTasksEnabled,
    onBulkAdd,
    onSort,
    onShowCompleted,
    onClearCompleted,
    onExport,
  );
}

/// The channel the hosted list publishes its [ListChromeActions] into. Held by
/// the compact shell's State and rebuilt into the app bar's `actions` through a
/// [ValueListenableBuilder], so an action change repaints the bar alone — never
/// the shell (and never the list under it).
class ListChromeController extends ValueNotifier<ListChromeActions?> {
  ListChromeController() : super(null);

  bool _disposed = false;

  /// Publish [actions], ignoring a repeat of what is already up. Safe after
  /// disposal: the list publishes from a post-frame callback, and the compact
  /// shell can unmount in between (a rotation into the expanded layout).
  void publish(ListChromeActions? actions) {
    if (_disposed || value == actions) return;
    value = actions;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Marks a subtree as hosted by the compact shell's app bar, carrying the
/// [ListChromeController] the list publishes into. Absent → the list owns its
/// own toolbar.
class CompactChromeScope extends InheritedWidget {
  const CompactChromeScope({
    required this.controller,
    required super.child,
    super.key,
  });

  /// The channel to publish list actions into.
  final ListChromeController controller;

  /// The hosting shell's chrome channel, or `null` when nothing hosts it.
  static ListChromeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CompactChromeScope>()
      ?.controller;

  @override
  bool updateShouldNotify(CompactChromeScope oldWidget) =>
      controller != oldWidget.controller;
}

/// The merged actions as they render in the compact app bar: search and sort
/// stay one tap away; everything with a name too long for an icon goes into one
/// overflow. The keys match the ones the desktop toolbar uses for the same
/// actions, so "where is show-completed" has one answer per form factor.
class CompactListActions extends StatelessWidget {
  const CompactListActions({required this.actions, super.key});

  /// The list's published actions.
  final ListChromeActions actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('search-button'),
          icon: const Icon(Icons.search),
          tooltip: 'Search tasks',
          onPressed: actions.onSearch,
        ),
        // Icon-only in the bar: the full "Sort: <order>" label is a toolbar
        // affordance and would crowd out the view title on a phone. The menu
        // it opens — and its key — are the same on both form factors.
        SortDropdown(
          value: actions.sort,
          onChanged: actions.onSort,
          iconOnly: true,
        ),
        PopupMenuButton<String>(
          key: const Key('toolbar-overflow'),
          tooltip: 'More list actions',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'select':
                actions.onSelectTasks?.call();
              case 'bulk-add':
                actions.onBulkAdd?.call();
              case 'show-completed':
                actions.onShowCompleted(!actions.showCompleted);
              case 'clear-completed':
                actions.onClearCompleted?.call();
              case 'export':
                actions.onExport?.call();
            }
          },
          itemBuilder: (context) => [
            if (actions.onSelectTasks != null)
              PopupMenuItem<String>(
                key: const Key('toolbar-select-tasks'),
                value: 'select',
                enabled: actions.selectTasksEnabled,
                child: _entry(
                  context,
                  Icons.check_box_outlined,
                  'Select tasks',
                  // A disabled entry greys its LABEL (a DefaultTextStyle) but
                  // not an icon, which would leave a half-disabled row.
                  enabled: actions.selectTasksEnabled,
                ),
              ),
            PopupMenuItem<String>(
              key: const Key('bulk-add-button'),
              value: 'bulk-add',
              enabled: actions.onBulkAdd != null,
              child: _entry(
                context,
                Icons.playlist_add,
                'Add multiple tasks',
                enabled: actions.onBulkAdd != null,
              ),
            ),
            PopupMenuItem<String>(
              key: const Key('show-completed-toggle'),
              value: 'show-completed',
              child: _entry(
                context,
                // The state is the icon: a ticked box means they are showing.
                actions.showCompleted
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                'Show completed',
              ),
            ),
            if (actions.onExport != null)
              PopupMenuItem<String>(
                key: const Key('toolbar-export'),
                value: 'export',
                child: _entry(
                  context,
                  Icons.file_download_outlined,
                  'Export view…',
                ),
              ),
            if (actions.onClearCompleted != null) ...[
              const PopupMenuDivider(),
              // Last, divided off and error-toned: the one destructive,
              // non-undoable entry reads as one before the finger commits.
              PopupMenuItem<String>(
                key: const Key('clear-completed-button'),
                value: 'clear-completed',
                child: _entry(
                  context,
                  Icons.delete_sweep_outlined,
                  'Clear completed',
                  color: scheme.error,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// One overflow row: icon, gap, label. The label is [Flexible] so a large
  /// text scale wraps it inside the menu's capped width instead of clipping it.
  Widget _entry(
    BuildContext context,
    IconData icon,
    String label, {
    bool enabled = true,
    Color? color,
  }) {
    final tone = enabled ? color : Theme.of(context).disabledColor;
    return Row(
      children: [
        Icon(icon, size: 20, color: tone),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: color == null ? null : TextStyle(color: tone),
          ),
        ),
      ],
    );
  }
}

/// An app bar that can ride the list's scroll off the top of the screen.
///
/// It collapses by LAYOUT, not by transform alone: the slot it occupies shrinks
/// from the bar's full height to nothing while the bar itself stays full-size
/// and overflows upward, so the bar's bottom edge and the body's top edge move
/// together — the body follows the bar up instead of leaving a hole where it
/// was, exactly as a non-pinned sliver app bar scrolls off. At [shown] == 1 it
/// IS the bare [AppBar] (no wrapper between the theme and the pixels, so a
/// pinned bar is pixel-identical to the one that never collapsed) and at 0 it is
/// GONE — not merely off-screen, so a hidden action is out of the hit-test AND
/// out of the semantics tree that a screen reader walks.
class CollapsingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const CollapsingAppBar({
    required this.bar,
    required this.shown,
    required this.topPadding,
    super.key,
  });

  /// The bar itself, at its full height.
  final AppBar bar;

  /// How much of it is on screen: 1 pinned, 0 fully collapsed.
  final double shown;

  /// The status-bar inset the bar covers on top of its own toolbar (an [AppBar]
  /// insets itself past the status bar, through its own [SafeArea], when it is
  /// the [Scaffold]'s primary bar).
  final double topPadding;

  /// The height the bar occupies when fully shown.
  double get fullHeight => bar.preferredSize.height + topPadding;

  /// The height the slot actually occupies at [shown] — where the bar's bottom
  /// edge, and with it the body's top edge, sits.
  double get height => fullHeight * shown;

  /// What the hosting [Scaffold] is TOLD to reserve — the slot MINUS the status
  /// bar, because the Scaffold adds that inset back itself
  /// (`Scaffold._appBarMaxHeight` = its app bar's preferred height + the top
  /// padding, for a `primary` Scaffold — the default, and what the compact
  /// shell mounts). Counting it here too has the phone reserve it twice: the bar's
  /// top-aligned fill takes the whole over-tall slot, so the toolbar draws
  /// where it belongs and the surplus becomes a band of bar-coloured nothing
  /// under it — every row pushed down past it, and a `flexibleSpace` sync line
  /// left floating at the bottom of the band rather than on the bar's edge
  /// (#262). Never negative: a slot shorter than the status bar (a bar nearly
  /// gone) asks for nothing, and the SizedBox below still gives the exact
  /// height — the Scaffold's is a MAXIMUM, not a demand.
  @override
  Size get preferredSize => Size.fromHeight(math.max(0, height - topPadding));

  @override
  Widget build(BuildContext context) {
    if (shown >= 1) return bar;
    if (shown <= 0) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      // Bottom-aligned and unclipped: the bar keeps its full height and slides
      // up past the top of the screen, which is what clips it.
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: fullHeight,
        maxHeight: fullHeight,
        child: bar,
      ),
    );
  }
}
