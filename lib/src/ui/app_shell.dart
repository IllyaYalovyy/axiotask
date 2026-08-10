// The app shell — the ShellRoute builder that turns the current URL into the
// adaptive [ListDetailScaffold], builds the real [Sidebar] from the store and
// prefs, wires navigation + list management back into go_router / the command
// layer, persists the selected view, and keeps the desktop window title in sync
// (now resolving list ids to their titles).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'list_detail_scaffold.dart';
import 'router.dart';
import 'sidebar.dart';
import 'task_detail.dart';
import 'task_list_view.dart';
import 'views.dart';

/// The adaptive shell for the current [location], wrapping the list pane [child]
/// (the ShellRoute child) with the sidebar and an optional detail pane.
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

    final lists = ref.watch(orderedListsProvider);
    final counts = ref.watch(viewCountsProvider);
    final excluded = ref.watch(prefsControllerProvider).excludedLists.toSet();
    final footer = ref.watch(sidebarFooterProvider);
    final listTitles = {for (final l in lists) l.list.id: l.list.title};

    // Keep the desktop window title in sync with the active view (no-op on
    // mobile / under tests via NoopWindowTitleController). Scheduled after the
    // frame so titling never blocks the first paint (the geometry-freeze lesson
    // applied to the title too).
    final title = windowTitleFor(
      sel.viewId,
      instancePrefix: prefix,
      listTitles: listTitles,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.setTitle(title);
    });

    final selectedIndex =
        SmartView.byId(sel.viewId)?.index ?? SmartView.all.index;

    // Panel prev/next: the siblings of the open task in the CURRENT view's
    // visible ordering (the same order the list renders). Null at a boundary,
    // and for anything not in the ordering (a subtask, or a filtered-out task).
    String? prevTaskId;
    String? nextTaskId;
    if (sel.taskId != null) {
      final all =
          ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
      final prefs = ref.watch(prefsControllerProvider);
      final ordered = visibleTasksForView(
        allTasks: all,
        viewId: sel.viewId,
        excludedLists: prefs.excludedLists.toSet(),
        showCompleted: prefs.showCompleted,
        sort: SortMode.byId(prefs.sortPerView[sel.viewId]),
        window: dateWindowNow(),
      );
      final i = ordered.indexWhere((t) => t.task.id == sel.taskId);
      if (i >= 0) {
        if (i > 0) prevTaskId = ordered[i - 1].task.id;
        if (i < ordered.length - 1) nextTaskId = ordered[i + 1].task.id;
      }
    }

    final sidebar = Sidebar(
      selectedViewId: sel.viewId,
      counts: counts,
      lists: lists,
      excludedLists: excluded,
      onSelectView: (id) => _selectView(context, ref, id),
      onCreateList: (title, {localOnly = false}) =>
          ref.read(commandsProvider).createList(title, localOnly: localOnly),
      onRenameList: (id, title) =>
          ref.read(commandsProvider).renameList(id, title),
      onDeleteList: (id) async {
        await ref.read(commandsProvider).deleteList(id);
        // If the deleted list was the open view, fall back to All Tasks so the
        // pane never points at a list that is gone.
        if (sel.viewId == id && context.mounted) {
          _selectView(context, ref, SmartView.all.id);
        }
      },
      onToggleExclude: (id) =>
          ref.read(prefsControllerProvider.notifier).toggleExclude(id),
      onReorderLists: (ids) =>
          ref.read(prefsControllerProvider.notifier).setListOrder(ids),
      footer: footer,
    );

    return ListDetailScaffold(
      sidebar: sidebar,
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
              autofocusNotes: sel.focusNotes,
              onClose: () => context.go(viewPath(sel.viewId)),
              onOpenTask: (id) => context.go(viewPath(sel.viewId, taskId: id)),
              onPrev: prevTaskId == null
                  ? null
                  : () => context.go(viewPath(sel.viewId, taskId: prevTaskId)),
              onNext: nextTaskId == null
                  ? null
                  : () => context.go(viewPath(sel.viewId, taskId: nextTaskId)),
            ),
      onCloseDetail: () => context.go(viewPath(sel.viewId)),
    );
  }

  /// Persist the newly selected view (survives restart, localStorage parity)
  /// and navigate to it.
  void _selectView(BuildContext context, WidgetRef ref, String viewId) {
    ref.read(prefsControllerProvider.notifier).setView(viewId);
    context.go(viewPath(viewId));
  }
}

/// The list pane for a view — the real [TaskListView] for every smart view and
/// every list (the T7.1 filters + sort make this one widget serve them all).
class ViewListPane extends StatelessWidget {
  const ViewListPane({required this.viewId, this.selectedTaskId, super.key});

  /// The view whose list this pane shows.
  final String viewId;

  /// The task the detail panel currently shows (drives new-task-follows-panel).
  final String? selectedTaskId;

  @override
  Widget build(BuildContext context) {
    return TaskListView(
      key: ValueKey('view-$viewId'),
      viewId: viewId,
      selectedTaskId: selectedTaskId,
      onOpenTask: (id) => context.go(viewPath(viewId, taskId: id)),
      onOpenTaskNotes: (id) =>
          context.go(viewPath(viewId, taskId: id, focusNotes: true)),
      // Search may land on a DIFFERENT view (a subtask's parent list — #92), so
      // it navigates by an explicit target view rather than the current one.
      onOpenInView: (v, id) => context.go(viewPath(v, taskId: id)),
    );
  }
}
