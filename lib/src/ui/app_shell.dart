// The app shell — the ShellRoute builder that turns the current URL into the
// adaptive [ListDetailScaffold], wires navigation back into go_router, persists
// the selected view, and keeps the desktop window title in sync.
//
// The All-Tasks list lands on the real store in T2.3 ([ViewListPane]); the
// detail panel fields in T2.4 ([TaskDetail]). What is real here is the shell:
// adaptive layout, routing, back handling, window title, theme.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import 'list_detail_scaffold.dart';
import 'router.dart';
import 'task_detail.dart';
import 'task_list_view.dart';
import 'views.dart';

/// The adaptive shell for the current [location], wrapping the list pane [child]
/// (the ShellRoute child) with navigation chrome and an optional detail pane.
class AppShell extends ConsumerWidget {
  const AppShell({required this.location, required this.child, super.key});

  /// The current router location (drives the selected view and detail).
  final Uri location;

  /// The list pane for the active view (the ShellRoute's swappable child).
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = parseShellLocation(location);
    final prefix = ref.watch(instancePrefixProvider);
    final titleController = ref.watch(windowTitleControllerProvider);

    // Keep the desktop window title in sync with the active view (no-op on
    // mobile / under tests via NoopWindowTitleController). Scheduled after the
    // frame so titling never blocks the first paint (the geometry-freeze lesson
    // applied to the title too).
    final title = windowTitleFor(sel.viewId, instancePrefix: prefix);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.setTitle(title);
    });

    final selectedIndex =
        SmartView.byId(sel.viewId)?.index ?? SmartView.all.index;

    return ListDetailScaffold(
      destinations: [
        for (final v in SmartView.values)
          ShellDestination(
            icon: v.icon,
            selectedIcon: v.selectedIcon,
            label: v.label,
          ),
      ],
      selectedIndex: selectedIndex,
      onDestinationSelected: (i) =>
          _selectView(context, ref, SmartView.values[i].id),
      list: child,
      detail: sel.taskId == null
          ? null
          : TaskDetail(
              key: ValueKey(sel.taskId),
              taskId: sel.taskId!,
              onClose: () => context.go(viewPath(sel.viewId)),
              onOpenTask: (id) => context.go(viewPath(sel.viewId, taskId: id)),
            ),
      onCloseDetail: () => context.go(viewPath(sel.viewId)),
    );
  }

  /// Persist the newly selected view (survives restart, localStorage parity)
  /// and navigate to it.
  void _selectView(BuildContext context, WidgetRef ref, String viewId) {
    final store = ref.read(prefsStoreProvider);
    store.save(store.load().copyWith(view: viewId));
    context.go(viewPath(viewId));
  }
}

/// The list pane for a view. The "All Tasks" view renders the real
/// [TaskListView] on the store (T2.3); the other smart views keep a placeholder
/// until their filters land in T7.1.
class ViewListPane extends StatelessWidget {
  const ViewListPane({required this.viewId, this.selectedTaskId, super.key});

  /// The view whose list this pane shows.
  final String viewId;

  /// The task the detail panel currently shows (drives new-task-follows-panel).
  final String? selectedTaskId;

  @override
  Widget build(BuildContext context) {
    if (viewId == SmartView.all.id) {
      return TaskListView(
        key: const ValueKey('view-all'),
        viewId: viewId,
        selectedTaskId: selectedTaskId,
        onOpenTask: (id) => context.go(viewPath(viewId, taskId: id)),
      );
    }
    final view = SmartView.byId(viewId);
    final label = viewLabelFor(viewId);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            view?.icon ?? Icons.checklist_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Tasks arrive in the next slice.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
