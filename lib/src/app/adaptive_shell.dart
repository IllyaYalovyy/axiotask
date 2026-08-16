import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/search/supported_task_search_repository.dart';
import '../domain/model/preferences.dart';
import '../domain/model/search.dart';
import '../domain/model/tasks.dart';
import '../domain/policy/date_workflow.dart';
import '../domain/policy/smart_views.dart';
import '../domain/policy/subtask_progress.dart';
import '../domain/repository/tasks_repository.dart';
import '../features/search/search_overlay.dart';
import '../features/search/search_view_model.dart';
import '../features/tasks/bulk_add_view_model.dart';
import '../features/tasks/quick_add_view_model.dart';
import '../features/tasks/task_detail_view_model.dart';
import '../features/tasks/tasks_view_model.dart';
import '../features/tasks/widgets/bulk_add.dart';
import '../features/tasks/widgets/quick_add.dart';
import '../features/tasks/widgets/sync_health_header.dart';
import '../features/tasks/widgets/task_details.dart';
import '../sync/health/sync_health.dart';
import 'navigation_state.dart';

final class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    required this.viewModel,
    this.onHealthAction,
    this.initialQuickAddInput,
    this.initialBulkAddInput,
    this.initialSearchQuery,
    this.navigation,
    super.key,
  });

  final TasksViewModel viewModel;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final String? initialQuickAddInput;
  final String? initialBulkAddInput;
  final String? initialSearchQuery;
  final AppNavigationController? navigation;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

final class _AdaptiveShellState extends State<AdaptiveShell> {
  late QuickAddViewModel _quickAdd;
  late SearchViewModel _search;
  late AppNavigationController _navigation;
  late bool _ownsNavigation;
  final GlobalKey<NavigatorState> _surfaceNavigatorKey =
      GlobalKey<NavigatorState>();
  final FocusNode _quickAddFocus = FocusNode(debugLabel: 'Quick add');
  bool _openedInitialBulkAdd = false;
  bool _suppressNavigationSync = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.start();
    _ownsNavigation = widget.navigation == null;
    _navigation = widget.navigation ?? AppNavigationController();
    _navigation.addListener(_navigationChanged);
    _quickAdd = _createQuickAdd();
    _search = _createSearch();
    _openInitialSearch();
    if (widget.initialQuickAddInput case final input?) {
      _quickAdd.setInput(input);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _quickAddFocus.requestFocus();
      });
    }
    widget.viewModel.addListener(_viewModelChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeOpenInitialBulkAdd(),
    );
  }

  @override
  void didUpdateWidget(covariant AdaptiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) {
      oldWidget.viewModel.removeListener(_viewModelChanged);
      _quickAdd.dispose();
      _search.dispose();
      widget.viewModel.start();
      _quickAdd = _createQuickAdd();
      _search = _createSearch();
      _openInitialSearch();
      if (widget.initialQuickAddInput case final input?) {
        _quickAdd.setInput(input);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _quickAddFocus.requestFocus();
        });
      }
      widget.viewModel.addListener(_viewModelChanged);
      _openedInitialBulkAdd = false;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _maybeOpenInitialBulkAdd(),
      );
    }
    if (oldWidget.navigation != widget.navigation) {
      _navigation.removeListener(_navigationChanged);
      if (_ownsNavigation) _navigation.dispose();
      _ownsNavigation = widget.navigation == null;
      _navigation = widget.navigation ?? AppNavigationController();
      _navigation.addListener(_navigationChanged);
      _syncDetailRoute();
    }
  }

  SearchViewModel _createSearch() => SearchViewModel(
    accountId: widget.viewModel.accountId,
    repository: SupportedTaskSearchRepository(widget.viewModel.tasksRepository),
  );

  void _openInitialSearch() {
    final query = widget.initialSearchQuery;
    if (query == null) return;
    _search.setQuery(query);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navigation.openSearch();
    });
  }

  QuickAddViewModel _createQuickAdd() => QuickAddViewModel(
    accountId: widget.viewModel.accountId,
    repository: widget.viewModel.tasksRepository,
    today: () => widget.viewModel.state.today,
    lists: () => widget.viewModel.state.orderedTaskLists,
    defaultTarget: _defaultQuickAddTarget,
    defaultDue: _defaultQuickAddDue,
    localEditCommitted: widget.viewModel.localEditCommitted,
    created: (_, due) async {
      if (widget.viewModel.state.selectedSmartView == SmartView.missed &&
          due == widget.viewModel.state.today) {
        widget.viewModel.selectSmartView(SmartView.focus);
      }
    },
  );

  TaskListId? _defaultQuickAddTarget() {
    final state = widget.viewModel.state;
    if (state.selectedTaskListId case final selected?) return selected;
    for (final list in state.orderedTaskLists) {
      if (!state.excludedTaskLists.contains(list.id)) return list.id;
    }
    return state.orderedTaskLists.firstOrNull?.id;
  }

  TaskDate? _defaultQuickAddDue() =>
      switch (widget.viewModel.state.selectedSmartView) {
        SmartView.focus || SmartView.missed => widget.viewModel.state.today,
        SmartView.upcoming => resolveDateShortcut(
          widget.viewModel.state.today,
          DateShortcut.nextWeek,
        ),
        SmartView.unscheduled || SmartView.all || null => null,
      };

  void _viewModelChanged() {
    _quickAdd.refreshContext();
    _maybeOpenInitialBulkAdd();
    _syncDetailRoute();
  }

  void _navigationChanged() {
    if (mounted) setState(() {});
  }

  void _syncDetailRoute() {
    if (_suppressNavigationSync) return;
    final selected = widget.viewModel.state.selectedTaskId;
    final current = _navigation.state.routes
        .whereType<TaskDetailRoute>()
        .lastOrNull
        ?.taskId;
    if (selected == null && current != null) {
      _navigation.closeTaskDetail();
    } else if (selected != null && selected != current) {
      _navigation.openTaskDetail(selected);
    }
  }

  void _openTask(TaskId taskId) {
    _suppressNavigationSync = true;
    widget.viewModel.selectTask(taskId);
    _navigation.openTaskDetail(taskId);
    _suppressNavigationSync = false;
  }

  void _openSearchResult(TaskSearchResult result) {
    _suppressNavigationSync = true;
    _navigation.removeRoute(const SearchRoute());
    widget.viewModel.selectTask(result.parent.id);
    _navigation.openTaskDetail(result.parent.id);
    _suppressNavigationSync = false;
  }

  void _handleBack() {
    final route = _navigation.currentRoute;
    _suppressNavigationSync = true;
    _navigation.back();
    if (route is TaskDetailRoute) {
      widget.viewModel.backFromTaskDetail();
      final selected = widget.viewModel.state.selectedTaskId;
      if (selected != null) _navigation.openTaskDetail(selected);
    }
    _suppressNavigationSync = false;
  }

  void _pageRemoved(Page<Object?> page) {
    final key = page.key;
    if (key is ValueKey<AppRoute> && _navigation.currentRoute == key.value) {
      _handleBack();
    }
  }

  void _maybeOpenInitialBulkAdd() {
    if (!mounted ||
        _openedInitialBulkAdd ||
        widget.initialBulkAddInput == null ||
        widget.viewModel.state.orderedTaskLists.isEmpty) {
      return;
    }
    _openedInitialBulkAdd = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_showBulkAdd(initialInput: widget.initialBulkAddInput));
      }
    });
  }

  Future<void> _showBulkAdd({String? initialInput}) async {
    final repository = widget.viewModel.tasksRepository;
    if (repository is! BulkTasksRepository) return;
    final bulkRepository = repository as BulkTasksRepository;
    final model = BulkAddViewModel(
      accountId: widget.viewModel.accountId,
      repository: bulkRepository,
      lists: () => widget.viewModel.state.orderedTaskLists,
      defaultTarget: _defaultQuickAddTarget,
      localEditCommitted: widget.viewModel.localEditCommitted,
    );
    if (initialInput != null) model.setInput(initialInput);
    await showAppDialog<void>(
      context: context,
      kind: AppDialogKind.bulkCapture,
      barrierDismissible: !model.state.isSubmitting,
      builder: (dialogContext) => BulkAddDialog(
        viewModel: model,
        lists: widget.viewModel.state.orderedTaskLists,
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
    model.dispose();
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_viewModelChanged);
    _navigation.removeListener(_navigationChanged);
    if (_ownsNavigation) _navigation.dispose();
    _quickAdd.dispose();
    _search.dispose();
    _quickAddFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.viewModel,
          builder: (context, _) {
            final state = widget.viewModel.state;
            return AppNavigationScope(
              controller: _navigation,
              child: Column(
                children: <Widget>[
                  _ApplicationHeader(
                    health: state.health,
                    onHealthAction: state.isSyncControlPending
                        ? null
                        : widget.onHealthAction ??
                              (action) => unawaited(
                                widget.viewModel.handleSyncHealthAction(action),
                              ),
                    isRefreshing: state.isRefreshing,
                    isSyncControlPending: state.isSyncControlPending,
                    onRefresh: widget.viewModel.refresh,
                    onStopSync: widget.viewModel.stopSync,
                    onSearch: _navigation.openSearch,
                    showSearch:
                        state.selectedTaskId == null && state.tasks.isNotEmpty,
                    onOpenNavigation: _navigation.openDrawer,
                  ),
                  if (state.syncControlFailureMessage case final message?)
                    MaterialBanner(
                      content: Text(message),
                      actions: const <Widget>[SizedBox.shrink()],
                    ),
                  if (state.listCommandFailureMessage case final message?)
                    MaterialBanner(
                      content: Text(message),
                      actions: const <Widget>[SizedBox.shrink()],
                    ),
                  if (state.taskCommandFailureMessage case final message?)
                    MaterialBanner(
                      content: Text(message),
                      actions: const <Widget>[SizedBox.shrink()],
                    ),
                  if (state.preferenceFailureMessage case final message?)
                    MaterialBanner(
                      content: Text(message),
                      actions: const <Widget>[SizedBox.shrink()],
                    ),
                  if (state.taskDeleteUndos.firstOrNull case final undo?)
                    MaterialBanner(
                      leading: const Icon(Icons.delete_outline),
                      content: Text('“${undo.title}” deleted'),
                      actions: <Widget>[
                        TextButton(
                          onPressed: state.isTaskCommandPending
                              ? null
                              : () => unawaited(
                                  widget.viewModel.undoTaskDelete(undo.taskId),
                                ),
                          child: const Text('Undo'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 900;
                        final pages = <Page<Object?>>[
                          _surfacePage(const CollectionRoute()),
                          for (final route in _navigation.state.routes.skip(1))
                            _surfacePage(route),
                        ];
                        final visibleRoute = _navigation.state.routes.reversed
                            .firstWhere(
                              (route) =>
                                  route is SearchRoute ||
                                  route is TaskDetailRoute ||
                                  route is DrawerRoute ||
                                  route is CollectionRoute,
                            );
                        final visible = switch (visibleRoute) {
                          SearchRoute() => SearchOverlay(
                            viewModel: _search,
                            onOpenResult: _openSearchResult,
                            onClose: _handleBack,
                          ),
                          DrawerRoute() => _ListNavigation(
                            state: state,
                            viewModel: widget.viewModel,
                            onSelected: _handleBack,
                          ),
                          CollectionRoute() ||
                          TaskDetailRoute() => _shellBody(state, wide),
                          _ => throw StateError('unsupported_visual_route'),
                        };
                        return NavigatorPopHandler<Object?>(
                          onPopWithResult: (_) =>
                              _surfaceNavigatorKey.currentState?.maybePop(),
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              visible,
                              Offstage(
                                offstage: true,
                                child: ExcludeFocus(
                                  child: Navigator(
                                    key: _surfaceNavigatorKey,
                                    requestFocus: false,
                                    pages: pages,
                                    onDidRemovePage: _pageRemoved,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _shellBody(TasksViewState state, bool wide) => _ShellBody(
    state: state,
    viewModel: widget.viewModel,
    quickAdd: _quickAdd,
    quickAddFocus: _quickAddFocus,
    openBulkAdd: () => _showBulkAdd(),
    openTask: _openTask,
    onBack: _handleBack,
    wide: wide,
  );
}

MaterialPage<Object?> _surfacePage(AppRoute route) => MaterialPage<Object?>(
  key: ValueKey<AppRoute>(route),
  child: const SizedBox.expand(),
);

final class _ApplicationHeader extends StatelessWidget {
  const _ApplicationHeader({
    required this.health,
    required this.isRefreshing,
    required this.isSyncControlPending,
    required this.onRefresh,
    required this.onStopSync,
    required this.onSearch,
    required this.showSearch,
    required this.onOpenNavigation,
    this.onHealthAction,
  });

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final bool isRefreshing;
  final bool isSyncControlPending;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onStopSync;
  final VoidCallback onSearch;
  final bool showSearch;
  final VoidCallback onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Column(
      children: <Widget>[
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'Axiotask',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (MediaQuery.sizeOf(context).width < 900) ...<Widget>[
                IconButton(
                  tooltip: 'Open navigation',
                  onPressed: onOpenNavigation,
                  icon: const Icon(Icons.menu),
                ),
                const SizedBox(width: 4),
              ],
              if (showSearch) ...<Widget>[
                IconButton(
                  tooltip: 'Search tasks',
                  onPressed: onSearch,
                  icon: const Icon(Icons.search),
                ),
                const SizedBox(width: 4),
              ],
              if (compact)
                IconButton(
                  tooltip: 'Refresh',
                  onPressed:
                      isRefreshing ||
                          isSyncControlPending ||
                          health.inactiveReason ==
                              SyncInactiveReason.syncStopped
                      ? null
                      : onRefresh,
                  icon: isRefreshing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                )
              else
                FilledButton.icon(
                  onPressed:
                      isRefreshing ||
                          isSyncControlPending ||
                          health.inactiveReason ==
                              SyncInactiveReason.syncStopped
                      ? null
                      : onRefresh,
                  icon: isRefreshing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              if (health.outcome != SyncHealthOutcome.inactive) ...<Widget>[
                SizedBox(width: compact ? 4 : 12),
                if (compact)
                  IconButton(
                    tooltip: 'Stop sync',
                    onPressed: isSyncControlPending ? null : onStopSync,
                    icon: isSyncControlPending
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.pause_circle_outline),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: isSyncControlPending ? null : onStopSync,
                    icon: isSyncControlPending
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.pause_circle_outline),
                    label: const Text('Stop sync'),
                  ),
              ],
            ],
          ),
        ),
        SyncHealthHeader(health: health, onAction: onHealthAction),
      ],
    );
  }
}

final class _ShellBody extends StatelessWidget {
  const _ShellBody({
    required this.state,
    required this.viewModel,
    required this.quickAdd,
    required this.quickAddFocus,
    required this.wide,
    required this.openBulkAdd,
    required this.openTask,
    required this.onBack,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final QuickAddViewModel quickAdd;
  final FocusNode quickAddFocus;
  final bool wide;
  final VoidCallback openBulkAdd;
  final ValueChanged<TaskId> openTask;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    if (state.failureMessage case final message?) {
      return Center(child: Text(message));
    }
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = TaskDetailViewModel.fromTasks(
      viewModel,
      navigateToTask: openTask,
      navigateBack: onBack,
    );
    final body = !wide
        ? detail.state == null
              ? _TaskCollection(
                  state: state,
                  viewModel: viewModel,
                  quickAdd: quickAdd,
                  quickAddFocus: quickAddFocus,
                  openBulkAdd: openBulkAdd,
                  openTask: openTask,
                )
              : TaskDetailsPane(viewModel: detail, compact: true)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: 244,
                child: _ListNavigation(state: state, viewModel: viewModel),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _TaskCollection(
                  state: state,
                  viewModel: viewModel,
                  quickAdd: quickAdd,
                  quickAddFocus: quickAddFocus,
                  openBulkAdd: openBulkAdd,
                  openTask: openTask,
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 360,
                child: TaskDetailsPane(viewModel: detail, compact: false),
              ),
            ],
          );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onBack,
      },
      child: body,
    );
  }
}

final class _ListNavigation extends StatelessWidget {
  const _ListNavigation({
    required this.state,
    required this.viewModel,
    this.onSelected,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
        child: ListView(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'SMART VIEWS',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 8),
            for (final smartView in SmartView.values)
              ListTile(
                dense: true,
                selected: state.selectedSmartView == smartView,
                leading: Icon(_smartViewIcon(smartView)),
                title: Text(smartView.title),
                trailing: _CountBadge(
                  count: state.viewCount(SmartTaskView(smartView)),
                ),
                onTap: () {
                  viewModel.selectSmartView(smartView);
                  onSelected?.call();
                },
              ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'GOOGLE TASK LISTS',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (state.taskLists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No cached Google task lists'),
              ),
            for (final list in state.orderedTaskLists)
              ListTile(
                selected: list.id == state.selectedTaskListId,
                leading:
                    state.listPreferences[list.id]?.excludedFromSmartViews ==
                        true
                    ? const Tooltip(
                        message: 'Excluded from smart views',
                        child: Icon(Icons.visibility_off_outlined),
                      )
                    : const Icon(Icons.list_alt_outlined),
                title: Text(
                  list.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${state.viewCount(TaskListView(list.id))} tasks',
                ),
                trailing: viewModel.preferencesRepository == null
                    ? null
                    : _ListPreferenceMenu(
                        state: state,
                        viewModel: viewModel,
                        taskListId: list.id,
                      ),
                onTap: () {
                  viewModel.selectTaskList(list.id);
                  onSelected?.call();
                },
              ),
          ],
        ),
      ),
    );
  }
}

IconData _smartViewIcon(SmartView view) => switch (view) {
  SmartView.focus => Icons.center_focus_strong_outlined,
  SmartView.upcoming => Icons.calendar_month_outlined,
  SmartView.missed => Icons.history_outlined,
  SmartView.unscheduled => Icons.event_busy_outlined,
  SmartView.all => Icons.all_inbox_outlined,
};

final class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count ${count == 1 ? 'task' : 'tasks'}',
    child: Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$count', textAlign: TextAlign.center),
    ),
  );
}

enum _ListPreferenceAction { includeOrExclude, moveUp, moveDown }

final class _ListPreferenceMenu extends StatelessWidget {
  const _ListPreferenceMenu({
    required this.state,
    required this.viewModel,
    required this.taskListId,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final TaskListId taskListId;

  @override
  Widget build(BuildContext context) {
    final lists = state.orderedTaskLists;
    final index = lists.indexWhere((list) => list.id == taskListId);
    final excluded =
        state.listPreferences[taskListId]?.excludedFromSmartViews ?? false;
    return PopupMenuButton<_ListPreferenceAction>(
      tooltip: 'List view settings',
      enabled: !state.isPreferenceCommandPending,
      onSelected: (action) {
        switch (action) {
          case _ListPreferenceAction.includeOrExclude:
            unawaited(viewModel.toggleListExclusion(taskListId));
          case _ListPreferenceAction.moveUp:
            unawaited(viewModel.moveTaskList(taskListId, -1));
          case _ListPreferenceAction.moveDown:
            unawaited(viewModel.moveTaskList(taskListId, 1));
        }
      },
      itemBuilder: (_) => <PopupMenuEntry<_ListPreferenceAction>>[
        PopupMenuItem<_ListPreferenceAction>(
          value: _ListPreferenceAction.includeOrExclude,
          child: Text(
            excluded ? 'Include in smart views' : 'Exclude from smart views',
          ),
        ),
        PopupMenuItem<_ListPreferenceAction>(
          value: _ListPreferenceAction.moveUp,
          enabled: index > 0,
          child: const Text('Move list up'),
        ),
        PopupMenuItem<_ListPreferenceAction>(
          value: _ListPreferenceAction.moveDown,
          enabled: index >= 0 && index < lists.length - 1,
          child: const Text('Move list down'),
        ),
      ],
    );
  }
}

final class _TaskCollection extends StatelessWidget {
  const _TaskCollection({
    required this.state,
    required this.viewModel,
    required this.quickAdd,
    required this.quickAddFocus,
    required this.openBulkAdd,
    required this.openTask,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final QuickAddViewModel quickAdd;
  final FocusNode quickAddFocus;
  final VoidCallback openBulkAdd;
  final ValueChanged<TaskId> openTask;

  @override
  Widget build(BuildContext context) {
    final projection = state.visibleProjection;
    final rows = projection.rows;
    final tasks = rows.map((row) => row.task).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      switch (state.selectedView) {
                        SmartTaskView(:final smartView) => smartView.title,
                        TaskListView() =>
                          state.selectedTaskList?.title ?? 'Cached tasks',
                      },
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (viewModel.preferencesRepository != null) ...<Widget>[
                    const SizedBox(width: 12),
                    Semantics(
                      label: 'Sort tasks',
                      child: DropdownButton<ViewSort>(
                        value: state.selectedViewPreferences.sort,
                        onChanged: state.isPreferenceCommandPending
                            ? null
                            : (value) {
                                if (value != null) {
                                  unawaited(viewModel.setViewSort(value));
                                }
                              },
                        items: const <DropdownMenuItem<ViewSort>>[
                          DropdownMenuItem(
                            value: ViewSort.manual,
                            child: Text('My order'),
                          ),
                          DropdownMenuItem(
                            value: ViewSort.effectiveDue,
                            child: Text('Effective due'),
                          ),
                          DropdownMenuItem(
                            value: ViewSort.title,
                            child: Text('Title'),
                          ),
                          DropdownMenuItem(
                            value: ViewSort.created,
                            child: Text('Reverse order'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Create task',
                    onPressed:
                        state.isTaskCommandPending ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showCreateTaskDialog(
                            context,
                            viewModel,
                            state.selectedTaskList!.id,
                          ),
                    icon: const Icon(Icons.add_task),
                  ),
                  IconButton(
                    tooltip: 'Create Google task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null
                        ? null
                        : () => _showCreateTaskListDialog(context, viewModel),
                    icon: const Icon(Icons.playlist_add),
                  ),
                  IconButton(
                    tooltip: 'Rename selected task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showRenameTaskListDialog(
                            context,
                            viewModel,
                            state.selectedTaskList!,
                          ),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Delete selected task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showDeleteTaskListConfirmation(
                            context,
                            viewModel,
                            state.selectedTaskList!,
                          ),
                    icon: const Icon(Icons.delete_forever_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              QuickAddBar(
                viewModel: quickAdd,
                lists: state.orderedTaskLists,
                focusNode: quickAddFocus,
              ),
              if (viewModel.tasksRepository is BulkTasksRepository)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('bulk-add-open'),
                    onPressed: state.orderedTaskLists.isNotEmpty
                        ? openBulkAdd
                        : null,
                    icon: const Icon(Icons.content_paste_outlined),
                    label: const Text('Paste multiple'),
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Text(
                    '${tasks.length} cached ${tasks.length == 1 ? 'task' : 'tasks'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (viewModel.preferencesRepository != null)
                    Semantics(
                      label: 'Show completed tasks',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Checkbox(
                            value: state.selectedViewPreferences.showCompleted,
                            onChanged: state.isPreferenceCommandPending
                                ? null
                                : (value) => unawaited(
                                    viewModel.setShowCompleted(value ?? false),
                                  ),
                          ),
                          const Text('Show completed'),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const Center(child: Text('No cached tasks in this list'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final task = row.task;
                    final progress = projectDirectChildProgress(
                      parentTaskId: task.id,
                      tasks: state.tasks,
                    );
                    return ListTile(
                      selected: task.id == state.selectedTaskId,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 6,
                      ),
                      leading: IconButton(
                        tooltip: task.status == TaskStatus.completed
                            ? 'Reopen task'
                            : 'Complete task',
                        onPressed: state.isTaskCommandPending
                            ? null
                            : () => unawaited(
                                viewModel.setTaskCompletion(
                                  task.id,
                                  task.status == TaskStatus.completed
                                      ? TaskStatus.needsAction
                                      : TaskStatus.completed,
                                ),
                              ),
                        icon: Icon(
                          task.status == TaskStatus.completed
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                      ),
                      title: Text(task.title),
                      subtitle: Text(
                        <String>[
                          if (task.due != null) 'Due ${task.due}',
                          if (row.effectiveDue.fromChildren != null)
                            'From subtasks ${row.effectiveDue.fromChildren}',
                          if (progress.total > 0) progress.label,
                        ].join(' • '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openTask(task.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Future<void> _showCreateTaskListDialog(
  BuildContext context,
  TasksViewModel viewModel,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.listEdit,
  builder: (_) => _TaskListEditDialog(
    viewModel: viewModel,
    dialogTitle: 'Create task list',
    actionLabel: 'Create',
    initialTitle: '',
    submit: viewModel.createTaskList,
  ),
);

Future<void> _showRenameTaskListDialog(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTaskList taskList,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.listEdit,
  builder: (_) => _TaskListEditDialog(
    viewModel: viewModel,
    dialogTitle: 'Rename task list',
    actionLabel: 'Rename',
    initialTitle: taskList.title,
    submit: (title) => viewModel.renameTaskList(taskList.id, title),
  ),
);

Future<void> _showCreateTaskDialog(
  BuildContext context,
  TasksViewModel viewModel,
  TaskListId taskListId, {
  TaskId? parentTaskId,
}) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.taskEdit,
  builder: (_) => _CreateTaskDialog(
    viewModel: viewModel,
    taskListId: taskListId,
    parentTaskId: parentTaskId,
  ),
);

final class _TaskListEditDialog extends StatefulWidget {
  const _TaskListEditDialog({
    required this.viewModel,
    required this.dialogTitle,
    required this.actionLabel,
    required this.initialTitle,
    required this.submit,
  });

  final TasksViewModel viewModel;
  final String dialogTitle;
  final String actionLabel;
  final String initialTitle;
  final Future<void> Function(String title) submit;

  @override
  State<_TaskListEditDialog> createState() => _TaskListEditDialogState();
}

final class _TaskListEditDialogState extends State<_TaskListEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.submit(_controller.text);
    if (mounted && widget.viewModel.state.listCommandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) => AlertDialog(
        title: Text(widget.dialogTitle),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 1024,
          decoration: const InputDecoration(labelText: 'List title'),
          onSubmitted: widget.viewModel.state.isListCommandPending
              ? null
              : (_) => _submit(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: widget.viewModel.state.isListCommandPending
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: widget.viewModel.state.isListCommandPending
                ? null
                : _submit,
            child: widget.viewModel.state.isListCommandPending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.actionLabel),
          ),
        ],
      ),
    );
  }
}

Future<void> _showDeleteTaskListConfirmation(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTaskList taskList,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.confirmation,
  builder: (_) => DeleteTaskListConfirmationDialog(
    viewModel: viewModel,
    taskList: taskList,
  ),
);

final class DeleteTaskListConfirmationDialog extends StatelessWidget {
  const DeleteTaskListConfirmationDialog({
    required this.viewModel,
    required this.taskList,
    super.key,
  });

  final TasksViewModel viewModel;
  final CachedTaskList taskList;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Delete “${taskList.title}”?'),
    content: const Text(
      'This deletes the Google task list and its tasks. This action cannot be undone.',
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          await viewModel.deleteTaskList(taskList.id);
          if (context.mounted &&
              viewModel.state.listCommandFailureMessage == null) {
            Navigator.of(context).pop();
          }
        },
        child: const Text('Delete list'),
      ),
    ],
  );
}

final class _CreateTaskDialog extends StatefulWidget {
  const _CreateTaskDialog({
    required this.viewModel,
    required this.taskListId,
    this.parentTaskId,
  });

  final TasksViewModel viewModel;
  final TaskListId taskListId;
  final TaskId? parentTaskId;

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

final class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  final TextEditingController _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.viewModel.createTask(
      taskListId: widget.taskListId,
      parentTaskId: widget.parentTaskId,
      title: _title.text,
    );
    if (mounted && widget.viewModel.state.taskCommandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: Text(
        widget.parentTaskId == null ? 'Create task' : 'Create subtask',
      ),
      content: TextField(
        controller: _title,
        autofocus: true,
        maxLength: 1024,
        decoration: const InputDecoration(labelText: 'Task title'),
        onSubmitted: widget.viewModel.state.isTaskCommandPending
            ? null
            : (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : _submit,
          child: widget.viewModel.state.isTaskCommandPending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    ),
  );
}
