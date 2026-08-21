import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/search/supported_task_search_repository.dart';
import '../domain/model/bulk_operations.dart';
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
import 'desktop_shortcuts.dart';
import 'desktop_task_drag.dart';
import 'navigation_state.dart';
import 'visual_tokens.dart';

final class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    required this.viewModel,
    this.onHealthAction,
    this.initialQuickAddInput,
    this.initialBulkAddInput,
    this.initialSearchQuery,
    this.navigation,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
    super.key,
  });

  final TasksViewModel viewModel;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final String? initialQuickAddInput;
  final String? initialBulkAddInput;
  final String? initialSearchQuery;
  final AppNavigationController? navigation;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

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
  final GlobalKey<_TaskCollectionState> _taskCollectionKey =
      GlobalKey<_TaskCollectionState>();
  final FocusNode _quickAddFocus = FocusNode(debugLabel: 'Quick add');
  final FocusNode _navigationPaneFocus = FocusNode(
    debugLabel: 'Desktop navigation pane',
  );
  final FocusNode _detailPaneFocus = FocusNode(
    debugLabel: 'Desktop detail pane',
  );
  TaskId? _focusedTaskId;
  bool _openedInitialBulkAdd = false;
  bool _suppressNavigationSync = false;
  DesktopTaskDragPayload? _dragPayload;
  _DesktopDropPreview? _dropPreview;

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
    _syncSelectionRoute();
    final focused = _focusedTaskId;
    if (focused != null &&
        !widget.viewModel.state.visibleProjection.rows.any(
          (row) => row.task.id == focused,
        )) {
      _focusedTaskId = null;
    }
  }

  void _syncSelectionRoute() {
    if (_suppressNavigationSync) return;
    final selected = widget.viewModel.state.bulkSelectedTaskIds;
    final routed = _navigation.state.selectedTaskIds;
    final matches =
        selected.length == routed.length && selected.every(routed.contains);
    if (matches) return;
    if (selected.isEmpty) {
      _navigation.clearSelection();
    } else {
      _navigation.beginSelection(selected);
    }
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

  void _startTaskDrag(DesktopTaskDragPayload payload) {
    setState(() {
      _dragPayload = payload;
      _dropPreview = _DesktopDropPreview.invalid(payload);
    });
  }

  void _previewTaskDrop(_DesktopDropPreview preview) {
    if (_dragPayload == null || _dropPreview == preview) return;
    setState(() => _dropPreview = preview);
  }

  void _cancelTaskDrag() {
    if (_dragPayload == null && _dropPreview == null) return;
    setState(() {
      _dragPayload = null;
      _dropPreview = null;
    });
  }

  void _acceptTaskDrop(DesktopTaskDropIntent intent) {
    _cancelTaskDrag();
    unawaited(
      widget.viewModel.moveTask(
        taskId: intent.taskId,
        destinationTaskListId: intent.destinationTaskListId,
        parentTaskId: intent.parentTaskId,
        previousTaskId: intent.previousTaskId,
      ),
    );
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
    } else if (route is TaskSelectionRoute) {
      widget.viewModel.clearBulkSelection();
    }
    _suppressNavigationSync = false;
    if (route is SearchRoute ||
        route is DrawerRoute ||
        route is TaskSelectionRoute ||
        route is TaskDetailRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _taskCollectionKey.currentState?.focusSelectedOrFirst();
      });
    }
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

  bool get _editingText {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    return focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleDesktopKeyEvent(FocusNode _, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final action = resolveDesktopShortcut(
      event: event,
      controlPressed: keyboard.isControlPressed,
      shiftPressed: keyboard.isShiftPressed,
      altPressed: keyboard.isAltPressed,
      editingText: _editingText,
      hasTask:
          _focusedTaskId != null ||
          widget.viewModel.state.selectedTaskId != null,
    );
    if (action == null) return KeyEventResult.ignored;
    switch (action) {
      case DesktopShortcutAction.showReference:
        unawaited(_showShortcutReference());
      case DesktopShortcutAction.search:
        _navigation.openSearch();
      case DesktopShortcutAction.quickAdd:
        _quickAddFocus.requestFocus();
      case DesktopShortcutAction.bulkCapture:
        unawaited(_showBulkAdd());
      case DesktopShortcutAction.focusNavigation:
        _navigationPaneFocus.requestFocus();
      case DesktopShortcutAction.focusTasks:
        _taskCollectionKey.currentState?.focusSelectedOrFirst();
      case DesktopShortcutAction.focusDetails:
        _detailPaneFocus.requestFocus();
      case DesktopShortcutAction.back:
        _handleBack();
      case DesktopShortcutAction.openTask:
        _runTaskAction(DesktopTaskAction.open);
      case DesktopShortcutAction.toggleCompletion:
        _runTaskAction(DesktopTaskAction.toggleCompletion);
      case DesktopShortcutAction.editTask:
        _runTaskAction(DesktopTaskAction.edit);
      case DesktopShortcutAction.chooseDate:
        _runTaskAction(DesktopTaskAction.chooseDate);
      case DesktopShortcutAction.moveTask:
        _runTaskAction(DesktopTaskAction.moveToList);
      case DesktopShortcutAction.deleteTask:
        _runTaskAction(DesktopTaskAction.delete);
    }
    return KeyEventResult.handled;
  }

  Future<void> _showShortcutReference() => showAppDialog<void>(
    context: context,
    kind: AppDialogKind.shortcutReference,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'Shortcuts are accelerators. Every command is also available '
                'from a visible button or menu.',
              ),
              const SizedBox(height: 12),
              for (final shortcut in desktopShortcutReference)
                ListTile(
                  dense: true,
                  title: Text(shortcut.description),
                  trailing: Text(shortcut.keys),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  void _runTaskAction(DesktopTaskAction action, [TaskId? explicitTaskId]) {
    final selected = widget.viewModel.state.selectedTaskId;
    final taskId =
        explicitTaskId ??
        (_navigation.currentRoute is TaskDetailRoute ? selected : null) ??
        _focusedTaskId ??
        selected;
    if (taskId == null || widget.viewModel.state.isTaskCommandPending) return;
    final task = widget.viewModel.state.tasks
        .where((candidate) => candidate.id == taskId)
        .firstOrNull;
    if (task == null) return;
    if (action == DesktopTaskAction.open) {
      _openTask(task.id);
      return;
    }
    if (action == DesktopTaskAction.toggleCompletion) {
      unawaited(
        widget.viewModel.setTaskCompletion(
          task.id,
          task.status == TaskStatus.completed
              ? TaskStatus.needsAction
              : TaskStatus.completed,
        ),
      );
      return;
    }
    if (action == DesktopTaskAction.delete) {
      unawaited(widget.viewModel.deleteTask(task.id));
      return;
    }
    _openTask(task.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final details = TaskDetailViewModel.fromTasks(
        widget.viewModel,
        navigateToTask: _openTask,
        navigateBack: _handleBack,
      );
      final detailState = details.state;
      if (detailState == null) return;
      switch (action) {
        case DesktopTaskAction.edit:
          unawaited(showTaskContentDialog(context, details, detailState.task));
        case DesktopTaskAction.chooseDate:
          unawaited(showTaskDateDialog(context, details, detailState.task));
        case DesktopTaskAction.moveToList:
          if (detailState.destinationLists.isEmpty) return;
          unawaited(
            showTaskMoveListDialog(
              context,
              details,
              detailState.task,
              detailState.destinationLists,
            ),
          );
        case DesktopTaskAction.open ||
            DesktopTaskAction.toggleCompletion ||
            DesktopTaskAction.delete:
          return;
      }
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_viewModelChanged);
    _navigation.removeListener(_navigationChanged);
    if (_ownsNavigation) _navigation.dispose();
    _quickAdd.dispose();
    _search.dispose();
    _quickAddFocus.dispose();
    _navigationPaneFocus.dispose();
    _detailPaneFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_navigation.state.canHandlePredictiveBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleDesktopKeyEvent,
        child: Scaffold(
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
                                    widget.viewModel.handleSyncHealthAction(
                                      action,
                                    ),
                                  ),
                        isRefreshing: state.isRefreshing,
                        isSyncControlPending: state.isSyncControlPending,
                        onRefresh: widget.viewModel.refresh,
                        onStopSync: widget.viewModel.stopSync,
                        onSearch: _navigation.openSearch,
                        onShowShortcuts: _showShortcutReference,
                        showSearch:
                            state.selectedTaskId == null &&
                            state.tasks.isNotEmpty,
                        onOpenNavigation: _navigation.openDrawer,
                        diagnosticsBuilder: widget.diagnosticsBuilder,
                        accountBackupBuilder: widget.accountBackupBuilder,
                        localDataRecoveryBuilder:
                            widget.localDataRecoveryBuilder,
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
                      if (state.bulkCommandFailureMessage case final message?)
                        MaterialBanner(
                          content: Text(message),
                          actions: const <Widget>[SizedBox.shrink()],
                        ),
                      if (state.latestBulkOperation case final summary?)
                        _BulkOperationResultBanner(summary: summary),
                      if (state.taskDeleteGroupUndos.firstOrNull
                          case final undo?)
                        MaterialBanner(
                          key: const Key('bulk-delete-undo'),
                          leading: const Icon(Icons.delete_outline),
                          content: Text(
                            '${undo.selectedCount} selected '
                            '${undo.selectedCount == 1 ? 'task' : 'tasks'} deleted',
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: state.isTaskCommandPending
                                  ? null
                                  : () => unawaited(
                                      widget.viewModel.undoTaskDeleteGroup(
                                        undo.groupId,
                                      ),
                                    ),
                              child: const Text('Undo all'),
                            ),
                          ],
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
                                      widget.viewModel.undoTaskDelete(
                                        undo.taskId,
                                      ),
                                    ),
                              child: const Text('Undo'),
                            ),
                          ],
                        ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth >= 1000;
                            final pages = <Page<Object?>>[
                              _surfacePage(const CollectionRoute()),
                              for (final route in _navigation.state.routes.skip(
                                1,
                              ))
                                _surfacePage(route),
                            ];
                            final visibleRoute = _navigation
                                .state
                                .routes
                                .reversed
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
    onTaskFocused: (taskId) => _focusedTaskId = taskId,
    onTaskAction: _runTaskAction,
    taskCollectionKey: _taskCollectionKey,
    navigationPaneFocus: _navigationPaneFocus,
    detailPaneFocus: _detailPaneFocus,
    onBack: _handleBack,
    dropPreview: _dropPreview,
    onDragStarted: _startTaskDrag,
    onDragPreview: _previewTaskDrop,
    onDragCanceled: _cancelTaskDrag,
    onDrop: _acceptTaskDrop,
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
    required this.onShowShortcuts,
    required this.showSearch,
    required this.onOpenNavigation,
    this.onHealthAction,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
  });

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final bool isRefreshing;
  final bool isSyncControlPending;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onStopSync;
  final VoidCallback onSearch;
  final VoidCallback onShowShortcuts;
  final bool showSearch;
  final VoidCallback onOpenNavigation;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 800;
    final tokens = Theme.of(context).axiotaskTokens;
    return Column(
      children: <Widget>[
        Container(
          height: tokens.headerHeight,
          padding: EdgeInsets.symmetric(horizontal: tokens.horizontalInset),
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
              IconButton(
                tooltip: 'Keyboard shortcuts',
                onPressed: onShowShortcuts,
                icon: const Icon(Icons.keyboard_outlined),
              ),
              const SizedBox(width: 4),
              if (accountBackupBuilder case final builder?) ...<Widget>[
                IconButton(
                  tooltip: 'Account backup',
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: builder)),
                  icon: const Icon(Icons.save_alt_outlined),
                ),
                const SizedBox(width: 4),
              ],
              if (localDataRecoveryBuilder case final builder?) ...<Widget>[
                IconButton(
                  tooltip: 'Local data recovery',
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: builder)),
                  icon: const Icon(Icons.settings_backup_restore),
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
        SyncHealthHeader(
          health: health,
          onAction: onHealthAction,
          diagnosticsBuilder: diagnosticsBuilder,
        ),
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
    required this.onTaskFocused,
    required this.onTaskAction,
    required this.taskCollectionKey,
    required this.navigationPaneFocus,
    required this.detailPaneFocus,
    required this.onBack,
    required this.dropPreview,
    required this.onDragStarted,
    required this.onDragPreview,
    required this.onDragCanceled,
    required this.onDrop,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final QuickAddViewModel quickAdd;
  final FocusNode quickAddFocus;
  final bool wide;
  final VoidCallback openBulkAdd;
  final ValueChanged<TaskId> openTask;
  final ValueChanged<TaskId> onTaskFocused;
  final void Function(DesktopTaskAction action, [TaskId? taskId]) onTaskAction;
  final GlobalKey<_TaskCollectionState> taskCollectionKey;
  final FocusNode navigationPaneFocus;
  final FocusNode detailPaneFocus;
  final VoidCallback onBack;
  final _DesktopDropPreview? dropPreview;
  final ValueChanged<DesktopTaskDragPayload> onDragStarted;
  final ValueChanged<_DesktopDropPreview> onDragPreview;
  final VoidCallback onDragCanceled;
  final ValueChanged<DesktopTaskDropIntent> onDrop;

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
                  key: taskCollectionKey,
                  state: state,
                  viewModel: viewModel,
                  quickAdd: quickAdd,
                  quickAddFocus: quickAddFocus,
                  openBulkAdd: openBulkAdd,
                  onTaskFocused: onTaskFocused,
                  onTaskAction: onTaskAction,
                  dropPreview: dropPreview,
                  onDragStarted: onDragStarted,
                  onDragPreview: onDragPreview,
                  onDragCanceled: onDragCanceled,
                  onDrop: onDrop,
                )
              : _DesktopPaneFocus(
                  key: const Key('desktop-detail-pane'),
                  focusNode: detailPaneFocus,
                  child: TaskDetailsPane(viewModel: detail, compact: true),
                )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 1200 ? 220 : 244,
                child: _DesktopPaneFocus(
                  key: const Key('desktop-navigation-pane'),
                  focusNode: navigationPaneFocus,
                  onKeyEvent: (_, event) =>
                      _handleNavigationKey(event, state, viewModel),
                  child: _ListNavigation(
                    state: state,
                    viewModel: viewModel,
                    dropPreview: dropPreview,
                    onDragPreview: onDragPreview,
                    onDrop: onDrop,
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _TaskCollection(
                  key: taskCollectionKey,
                  state: state,
                  viewModel: viewModel,
                  quickAdd: quickAdd,
                  quickAddFocus: quickAddFocus,
                  openBulkAdd: openBulkAdd,
                  onTaskFocused: onTaskFocused,
                  onTaskAction: onTaskAction,
                  dropPreview: dropPreview,
                  onDragStarted: onDragStarted,
                  onDragPreview: onDragPreview,
                  onDragCanceled: onDragCanceled,
                  onDrop: onDrop,
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 1200 ? 320 : 360,
                child: _DesktopPaneFocus(
                  key: const Key('desktop-detail-pane'),
                  focusNode: detailPaneFocus,
                  child: TaskDetailsPane(viewModel: detail, compact: false),
                ),
              ),
            ],
          );
    return KeyedSubtree(key: const Key('desktop-task-pane'), child: body);
  }
}

KeyEventResult _handleNavigationKey(
  KeyEvent event,
  TasksViewState state,
  TasksViewModel viewModel,
) {
  if (event is! KeyDownEvent ||
      (event.logicalKey != LogicalKeyboardKey.arrowUp &&
          event.logicalKey != LogicalKeyboardKey.arrowDown)) {
    return KeyEventResult.ignored;
  }
  final smartViews = SmartView.values;
  final selectedSmart = state.selectedSmartView;
  final selectedList = state.selectedTaskListId;
  var index = selectedSmart == null
      ? smartViews.length +
            state.orderedTaskLists.indexWhere((list) => list.id == selectedList)
      : smartViews.indexOf(selectedSmart);
  final count = smartViews.length + state.orderedTaskLists.length;
  if (count == 0) return KeyEventResult.ignored;
  index = (index + (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1))
      .clamp(0, count - 1);
  if (index < smartViews.length) {
    viewModel.selectSmartView(smartViews[index]);
  } else {
    viewModel.selectTaskList(
      state.orderedTaskLists[index - smartViews.length].id,
    );
  }
  return KeyEventResult.handled;
}

final class _DesktopPaneFocus extends StatelessWidget {
  const _DesktopPaneFocus({
    required this.focusNode,
    required this.child,
    this.onKeyEvent,
    super.key,
  });

  final FocusNode focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    onKeyEvent: onKeyEvent,
    child: AnimatedBuilder(
      animation: focusNode,
      child: child,
      builder: (context, child) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: focusNode.hasPrimaryFocus
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    ),
  );
}

final class _BulkActionBar extends StatelessWidget {
  const _BulkActionBar({required this.state, required this.viewModel});

  final TasksViewState state;
  final TasksViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final count = state.bulkSelectedTaskIds.length;
    final enabled = !state.isBulkCommandPending;
    return Material(
      key: const Key('bulk-action-bar'),
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Semantics(
              liveRegion: true,
              label: '$count tasks selected',
              child: Text('$count selected'),
            ),
            FilledButton.icon(
              key: const Key('bulk-complete-open'),
              onPressed: enabled
                  ? () => unawaited(
                      _showBulkCompleteConfirmation(context, viewModel),
                    )
                  : null,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Complete'),
            ),
            OutlinedButton.icon(
              key: const Key('bulk-reschedule-open'),
              onPressed: enabled
                  ? () => unawaited(_showBulkDateDialog(context, viewModel))
                  : null,
              icon: const Icon(Icons.event_outlined),
              label: const Text('Reschedule'),
            ),
            OutlinedButton.icon(
              key: const Key('bulk-move-open'),
              onPressed: enabled && state.orderedTaskLists.isNotEmpty
                  ? () => unawaited(
                      _showBulkMoveDialog(
                        context,
                        viewModel,
                        state.orderedTaskLists,
                      ),
                    )
                  : null,
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('Move'),
            ),
            OutlinedButton.icon(
              key: const Key('bulk-delete-open'),
              onPressed: enabled
                  ? () => unawaited(
                      _showBulkDeleteConfirmation(context, viewModel),
                    )
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
            IconButton(
              key: const Key('bulk-selection-close'),
              tooltip: 'Exit task selection',
              onPressed: enabled ? viewModel.clearBulkSelection : null,
              icon: const Icon(Icons.close),
            ),
            if (state.isBulkCommandPending)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

final class _BulkOperationResultBanner extends StatelessWidget {
  const _BulkOperationResultBanner({required this.summary});

  final BulkOperationSummary summary;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    key: const Key('bulk-operation-result'),
    leading: Icon(summary.failedCount == 0 ? Icons.sync : Icons.sync_problem),
    content: Semantics(
      liveRegion: true,
      label:
          '${summary.confirmedCount} confirmed, '
          '${summary.pendingCount} pending, ${summary.failedCount} failed',
      child: Text(
        '${_bulkKindLabel(summary.kind)}: '
        '${summary.confirmedCount} confirmed • '
        '${summary.pendingCount} pending • '
        '${summary.failedCount} failed '
        '(${summary.affectedCount} Google ${_bulkRemoteNoun(summary)} '
        'from ${summary.selectedCount} selected)',
      ),
    ),
    actions: const <Widget>[SizedBox.shrink()],
  );
}

String _bulkKindLabel(BulkOperationKind kind) => switch (kind) {
  BulkOperationKind.complete => 'Bulk complete',
  BulkOperationKind.reschedule => 'Bulk reschedule',
  BulkOperationKind.move => 'Bulk move',
  BulkOperationKind.delete => 'Bulk delete',
  BulkOperationKind.clearCompleted => 'Clear completed',
};

String _bulkRemoteNoun(BulkOperationSummary summary) {
  final delete =
      summary.kind == BulkOperationKind.delete ||
      summary.kind == BulkOperationKind.clearCompleted;
  final noun = delete ? 'delete' : 'update';
  return summary.affectedCount == 1 ? noun : '${noun}s';
}

Future<void> _showBulkCompleteConfirmation(
  BuildContext context,
  TasksViewModel viewModel,
) async {
  final count = viewModel.state.bulkSelectedTaskIds.length;
  final confirmed = await showAppDialog<bool>(
    context: context,
    kind: AppDialogKind.confirmation,
    builder: (dialogContext) => AlertDialog(
      key: const Key('bulk-complete-confirmation'),
      title: Text('Complete $count ${count == 1 ? 'task' : 'tasks'}?'),
      content: const Text(
        'Every selected local change will commit together. Google confirms '
        'each task independently.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('bulk-complete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Complete tasks'),
        ),
      ],
    ),
  );
  if (confirmed == true) await viewModel.completeBulkSelection();
}

Future<void> _showBulkDeleteConfirmation(
  BuildContext context,
  TasksViewModel viewModel,
) async {
  final count = viewModel.state.bulkSelectedTaskIds.length;
  final confirmed = await showAppDialog<bool>(
    context: context,
    kind: AppDialogKind.confirmation,
    builder: (dialogContext) => AlertDialog(
      key: const Key('bulk-delete-confirmation'),
      title: Text('Delete $count selected ${count == 1 ? 'task' : 'tasks'}?'),
      content: const Text(
        'The complete selection is hidden together. One Undo all action '
        'remains available for 30 seconds before Google deletion begins.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('bulk-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete tasks'),
        ),
      ],
    ),
  );
  if (confirmed == true) await viewModel.deleteBulkSelection();
}

Future<void> _showClearCompletedConfirmation(
  BuildContext context,
  TasksViewModel viewModel,
) async {
  final selection = viewModel.state.clearCompletedSelection;
  if (selection == null) return;
  final skipped = selection.skippedParentTaskIds.length;
  final deleteCount = selection.completedTaskCount - skipped;
  final confirmed = await showAppDialog<bool>(
    context: context,
    kind: AppDialogKind.confirmation,
    builder: (dialogContext) => AlertDialog(
      key: const Key('clear-completed-confirmation'),
      title: Text(
        'Permanently clear $deleteCount completed '
        '${deleteCount == 1 ? 'task' : 'tasks'}?',
      ),
      content: Text(
        'This action has no Undo. Google confirms each delete independently.'
        '${skipped == 0 ? '' : ' $skipped completed ${skipped == 1 ? 'parent is' : 'parents are'} kept because unfinished subtasks remain.'}',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('clear-completed-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Clear completed'),
        ),
      ],
    ),
  );
  if (confirmed == true) await viewModel.clearCompleted();
}

Future<void> _showBulkDateDialog(
  BuildContext context,
  TasksViewModel viewModel,
) async {
  final shortcut = await showAppDialog<DateShortcut>(
    context: context,
    kind: AppDialogKind.date,
    builder: (dialogContext) => SimpleDialog(
      key: const Key('bulk-reschedule-dialog'),
      title: Text(
        'Reschedule ${viewModel.state.bulkSelectedTaskIds.length} selected',
      ),
      children: <Widget>[
        for (final value in DateShortcut.values)
          SimpleDialogOption(
            key: Key('bulk-reschedule-${value.name}'),
            onPressed: () => Navigator.of(dialogContext).pop(value),
            child: Text(switch (value) {
              DateShortcut.today => 'Today',
              DateShortcut.tomorrow => 'Tomorrow',
              DateShortcut.nextWeek => 'Next week',
              DateShortcut.nextMonth => 'Next month',
              DateShortcut.clear => 'Clear date',
            }),
          ),
      ],
    ),
  );
  if (shortcut != null) {
    await viewModel.rescheduleBulkSelectionShortcut(shortcut);
  }
}

Future<void> _showBulkMoveDialog(
  BuildContext context,
  TasksViewModel viewModel,
  List<CachedTaskList> lists,
) async {
  final destination = await showAppDialog<TaskListId>(
    context: context,
    kind: AppDialogKind.confirmation,
    builder: (dialogContext) => SimpleDialog(
      key: const Key('bulk-move-dialog'),
      title: Text(
        'Move ${viewModel.state.bulkSelectedTaskIds.length} selected',
      ),
      children: <Widget>[
        for (final list in lists)
          SimpleDialogOption(
            key: Key('bulk-move-list-${list.id.value}'),
            onPressed: () => Navigator.of(dialogContext).pop(list.id),
            child: Text(list.title),
          ),
      ],
    ),
  );
  if (destination != null) await viewModel.moveBulkSelection(destination);
}

final class _ListNavigation extends StatelessWidget {
  const _ListNavigation({
    required this.state,
    required this.viewModel,
    this.onSelected,
    this.dropPreview,
    this.onDragPreview,
    this.onDrop,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final VoidCallback? onSelected;
  final _DesktopDropPreview? dropPreview;
  final ValueChanged<_DesktopDropPreview>? onDragPreview;
  final ValueChanged<DesktopTaskDropIntent>? onDrop;

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
              _DesktopTaskListDropTarget(
                taskList: list,
                preview: dropPreview,
                onPreview: onDragPreview,
                onDrop: onDrop,
                child: ListTile(
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
              ),
          ],
        ),
      ),
    );
  }
}

final class _DesktopTaskListDropTarget extends StatelessWidget {
  const _DesktopTaskListDropTarget({
    required this.taskList,
    required this.preview,
    required this.onPreview,
    required this.onDrop,
    required this.child,
  });

  final CachedTaskList taskList;
  final _DesktopDropPreview? preview;
  final ValueChanged<_DesktopDropPreview>? onPreview;
  final ValueChanged<DesktopTaskDropIntent>? onDrop;
  final Widget child;

  DesktopTaskDropIntent? _intent(DesktopTaskDragPayload value) =>
      DesktopTaskDragAdapter.moveToList(
        payload: value,
        destinationTaskListId: taskList.id,
      );

  @override
  Widget build(BuildContext context) {
    if (onPreview == null || onDrop == null) return child;
    final targetKey = 'list-${taskList.id.value}';
    return DragTarget<DesktopTaskDragPayload>(
      onWillAcceptWithDetails: (details) => _intent(details.data) != null,
      onMove: (details) {
        final intent = _intent(details.data);
        if (intent != null) {
          onPreview!(
            _DesktopDropPreview(
              intent: intent,
              label: 'Move “${details.data.title}” to “${taskList.title}”',
              targetKey: targetKey,
            ),
          );
        }
      },
      onAcceptWithDetails: (details) {
        final intent = _intent(details.data);
        if (intent != null) onDrop!(intent);
      },
      builder: (context, _, _) => Material(
        color: preview?.targetKey == targetKey
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        child: child,
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

final class _TaskCollection extends StatefulWidget {
  const _TaskCollection({
    required this.state,
    required this.viewModel,
    required this.quickAdd,
    required this.quickAddFocus,
    required this.openBulkAdd,
    required this.onTaskFocused,
    required this.onTaskAction,
    required this.dropPreview,
    required this.onDragStarted,
    required this.onDragPreview,
    required this.onDragCanceled,
    required this.onDrop,
    super.key,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final QuickAddViewModel quickAdd;
  final FocusNode quickAddFocus;
  final VoidCallback openBulkAdd;
  final ValueChanged<TaskId> onTaskFocused;
  final void Function(DesktopTaskAction action, [TaskId? taskId]) onTaskAction;
  final _DesktopDropPreview? dropPreview;
  final ValueChanged<DesktopTaskDragPayload> onDragStarted;
  final ValueChanged<_DesktopDropPreview> onDragPreview;
  final VoidCallback onDragCanceled;
  final ValueChanged<DesktopTaskDropIntent> onDrop;

  @override
  State<_TaskCollection> createState() => _TaskCollectionState();
}

final class _TaskCollectionState extends State<_TaskCollection> {
  final List<FocusNode> _rowFocusNodes = <FocusNode>[];
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();

  TasksViewState get state => widget.state;
  TasksViewModel get viewModel => widget.viewModel;
  QuickAddViewModel get quickAdd => widget.quickAdd;
  FocusNode get quickAddFocus => widget.quickAddFocus;
  VoidCallback get openBulkAdd => widget.openBulkAdd;

  void _ensureFocusNodes(int count) {
    while (_rowFocusNodes.length < count) {
      _rowFocusNodes.add(
        FocusNode(debugLabel: 'Desktop task row ${_rowFocusNodes.length + 1}'),
      );
    }
    while (_rowFocusNodes.length > count) {
      _rowFocusNodes.removeLast().dispose();
    }
  }

  void focusSelectedOrFirst() {
    final rows = state.visibleProjection.rows;
    if (rows.isEmpty) return;
    _ensureFocusNodes(rows.length);
    final selected = state.selectedTaskId;
    final selectedIndex = selected == null
        ? -1
        : rows.indexWhere((row) => row.task.id == selected);
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    widget.onTaskFocused(rows[index].task.id);
    _rowFocusNodes[index].requestFocus();
  }

  void _moveFocus(int index, int delta, List<CachedTask> tasks) {
    final next = (index + delta).clamp(0, tasks.length - 1);
    widget.onTaskFocused(tasks[next].id);
    _rowFocusNodes[next].requestFocus();
  }

  void _autoscroll(Offset globalPosition) {
    if (!_scrollController.hasClients) return;
    final renderObject = _scrollViewportKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final pointer = renderObject.globalToLocal(globalPosition);
    final position = _scrollController.position;
    final target = DesktopDragAutoscroll.targetOffset(
      currentOffset: position.pixels,
      minOffset: position.minScrollExtent,
      maxOffset: position.maxScrollExtent,
      pointerY: pointer.dy,
      viewportHeight: renderObject.size.height,
    );
    if (target != null) _scrollController.jumpTo(target);
  }

  @override
  void dispose() {
    for (final node in _rowFocusNodes) {
      node.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projection = state.visibleProjection;
    final rows = projection.rows;
    final tasks = rows.map((row) => row.task).toList(growable: false);
    final clearSelection = state.clearCompletedSelection;
    final clearCompletedCount = clearSelection == null
        ? 0
        : clearSelection.completedTaskCount -
              clearSelection.skippedParentTaskIds.length;
    _ensureFocusNodes(tasks.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                switch (state.selectedView) {
                  SmartTaskView(:final smartView) => smartView.title,
                  TaskListView() =>
                    state.selectedTaskList?.title ?? 'Cached tasks',
                },
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (viewModel.preferencesRepository != null) ...<Widget>[
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
                  if (viewModel.tasksRepository
                          is BulkTaskOperationsRepository &&
                      tasks.isNotEmpty)
                    OutlinedButton.icon(
                      key: const Key('bulk-select-open'),
                      onPressed: state.isBulkSelectionActive
                          ? null
                          : () => viewModel.beginBulkSelection(tasks.first.id),
                      icon: const Icon(Icons.library_add_check_outlined),
                      label: const Text('Select tasks'),
                    ),
                  if (viewModel.tasksRepository
                          is DestructiveTaskOperationsRepository &&
                      state.selectedTaskList != null)
                    OutlinedButton.icon(
                      key: const Key('clear-completed-open'),
                      onPressed:
                          state.isBulkCommandPending || clearCompletedCount == 0
                          ? null
                          : () => unawaited(
                              _showClearCompletedConfirmation(
                                context,
                                viewModel,
                              ),
                            ),
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('Clear completed'),
                    ),
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
              if (state.isBulkSelectionActive) ...<Widget>[
                _BulkActionBar(state: state, viewModel: viewModel),
                const SizedBox(height: 12),
              ],
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
              Wrap(
                spacing: 16,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    '${tasks.length} cached ${tasks.length == 1 ? 'task' : 'tasks'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
          child: Stack(
            key: _scrollViewportKey,
            children: <Widget>[
              if (tasks.isEmpty)
                const Center(child: Text('No cached tasks in this list'))
              else
                ListView.separated(
                  key: const Key('desktop-task-scroll'),
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final task = row.task;
                    final canonicalSiblings = state.tasks
                        .where(
                          (candidate) =>
                              candidate.taskListId == task.taskListId &&
                              candidate.parentTaskId == task.parentTaskId,
                        )
                        .toList(growable: false);
                    final progress = projectDirectChildProgress(
                      parentTaskId: task.id,
                      tasks: state.tasks,
                    );
                    return _DesktopTaskRow(
                      key: Key('desktop-task-row-${task.id.value}'),
                      focusNode: _rowFocusNodes[index],
                      onFocused: () => widget.onTaskFocused(task.id),
                      onMoveFocus: (delta) => _moveFocus(index, delta, tasks),
                      onAction: (action) =>
                          widget.onTaskAction(action, task.id),
                      canonicalSiblings: canonicalSiblings,
                      manualOrderEnabled:
                          state.selectedTaskListId == task.taskListId &&
                          state.selectedViewPreferences.sort == ViewSort.manual,
                      dropPreview: widget.dropPreview,
                      onDragStarted: widget.onDragStarted,
                      onDragPreview: widget.onDragPreview,
                      onDragCanceled: widget.onDragCanceled,
                      onDrop: widget.onDrop,
                      onDragMove: _autoscroll,
                      task: task,
                      canMove: state.orderedTaskLists.any(
                        (list) => list.id != task.taskListId,
                      ),
                      enabled:
                          !state.isTaskCommandPending &&
                          !state.isBulkCommandPending,
                      selectionMode: state.isBulkSelectionActive,
                      bulkSelected: state.bulkSelectedTaskIds.contains(task.id),
                      onSelectionToggle: () =>
                          viewModel.toggleBulkSelection(task.id),
                      onBeginSelection: () =>
                          viewModel.beginBulkSelection(task.id),
                      selected: task.id == state.selectedTaskId,
                      subtitle: <String>[
                        if (task.due != null) 'Due ${task.due}',
                        if (row.effectiveDue.fromChildren != null)
                          'From subtasks ${row.effectiveDue.fromChildren}',
                        if (progress.total > 0) progress.label,
                      ].join(' • '),
                    );
                  },
                ),
              if (widget.dropPreview case final preview?)
                Positioned(
                  left: 16,
                  right: 16,
                  top: 8,
                  child: IgnorePointer(
                    child: Material(
                      key: const Key('desktop-task-drag-preview'),
                      elevation: 4,
                      color: preview.valid
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(preview.label),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _DesktopTaskRow extends StatefulWidget {
  const _DesktopTaskRow({
    required this.focusNode,
    required this.onFocused,
    required this.onMoveFocus,
    required this.onAction,
    required this.task,
    required this.canMove,
    required this.subtitle,
    required this.enabled,
    required this.selectionMode,
    required this.bulkSelected,
    required this.onSelectionToggle,
    required this.onBeginSelection,
    required this.selected,
    required this.canonicalSiblings,
    required this.manualOrderEnabled,
    required this.dropPreview,
    required this.onDragStarted,
    required this.onDragPreview,
    required this.onDragCanceled,
    required this.onDrop,
    required this.onDragMove,
    super.key,
  });

  final FocusNode focusNode;
  final VoidCallback onFocused;
  final ValueChanged<int> onMoveFocus;
  final ValueChanged<DesktopTaskAction> onAction;
  final CachedTask task;
  final bool canMove;
  final String subtitle;
  final bool enabled;
  final bool selectionMode;
  final bool bulkSelected;
  final VoidCallback onSelectionToggle;
  final VoidCallback onBeginSelection;
  final bool selected;
  final List<CachedTask> canonicalSiblings;
  final bool manualOrderEnabled;
  final _DesktopDropPreview? dropPreview;
  final ValueChanged<DesktopTaskDragPayload> onDragStarted;
  final ValueChanged<_DesktopDropPreview> onDragPreview;
  final VoidCallback onDragCanceled;
  final ValueChanged<DesktopTaskDropIntent> onDrop;
  final ValueChanged<Offset> onDragMove;

  @override
  State<_DesktopTaskRow> createState() => _DesktopTaskRowState();
}

final class _DesktopTaskRowState extends State<_DesktopTaskRow> {
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant _DesktopTaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    if (widget.focusNode.hasFocus) widget.onFocused();
    if (mounted) setState(() {});
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      widget.onMoveFocus(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      widget.onMoveFocus(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showContextMenu(Offset position) async {
    if (!widget.enabled) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<DesktopTaskAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _taskActionMenuItems(widget.task, canMove: widget.canMove),
    );
    if (action != null) widget.onAction(action);
  }

  DesktopTaskDropPlacement _placement(Offset globalPosition) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(globalPosition);
    return local.dy < box.size.height / 2
        ? DesktopTaskDropPlacement.before
        : DesktopTaskDropPlacement.after;
  }

  DesktopTaskDropIntent? _dropIntent(
    DesktopTaskDragPayload payload,
    Offset globalPosition,
  ) => DesktopTaskDragAdapter.reorder(
    payload: payload,
    target: widget.task,
    placement: _placement(globalPosition),
    canonicalSiblings: widget.canonicalSiblings,
    manualOrderEnabled: widget.manualOrderEnabled,
  );

  _DesktopDropPreview _preview(
    DesktopTaskDragPayload payload,
    Offset globalPosition,
  ) {
    final placement = _placement(globalPosition);
    final intent = _dropIntent(payload, globalPosition);
    if (intent == null) return _DesktopDropPreview.invalid(payload);
    return _DesktopDropPreview(
      intent: intent,
      label: 'Move “${payload.title}” ${placement.name} “${widget.task.title}”',
      targetKey: 'row-${widget.task.id.value}-${placement.name}',
    );
  }

  Widget _tile(CachedTask task) => ListTile(
    selected: widget.selected || widget.focusNode.hasFocus,
    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
    leading: widget.selectionMode
        ? Checkbox(
            key: Key('bulk-select-task-${task.id.value}'),
            value: widget.bulkSelected,
            onChanged: widget.enabled
                ? (_) => widget.onSelectionToggle()
                : null,
          )
        : IconButton(
            tooltip: task.status == TaskStatus.completed
                ? 'Reopen task'
                : 'Complete task',
            onPressed: widget.enabled
                ? () => widget.onAction(DesktopTaskAction.toggleCompletion)
                : null,
            icon: Icon(
              task.status == TaskStatus.completed
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
            ),
          ),
    title: Text(task.title),
    subtitle: Text(widget.subtitle),
    trailing: widget.selectionMode
        ? null
        : SizedBox(
            width: 100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                AnimatedOpacity(
                  opacity: _hovered || widget.focusNode.hasFocus ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hovered && !widget.focusNode.hasFocus,
                    child: IconButton(
                      tooltip: 'Open ${task.title}',
                      onPressed: widget.enabled
                          ? () => widget.onAction(DesktopTaskAction.open)
                          : null,
                      icon: const Icon(Icons.open_in_new),
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  label: 'Task actions for ${task.title}',
                  child: PopupMenuButton<DesktopTaskAction>(
                    tooltip: 'Task actions for ${task.title}',
                    enabled: widget.enabled,
                    onSelected: widget.onAction,
                    itemBuilder: (_) =>
                        _taskActionMenuItems(task, canMove: widget.canMove),
                  ),
                ),
              ],
            ),
          ),
    onTap: widget.enabled
        ? widget.selectionMode
              ? widget.onSelectionToggle
              : () => widget.onAction(DesktopTaskAction.open)
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.enabled ? widget.onBeginSelection : null,
      onSecondaryTapDown: (details) => widget.selectionMode
          ? null
          : unawaited(_showContextMenu(details.globalPosition)),
      child: _tile(task),
    );
    final draggable = Semantics(
      label:
          'Drag ${task.title} to reorder or move. '
          'Move buttons are available in task details.',
      child: _DesktopPointerDraggable<DesktopTaskDragPayload>(
        data: DesktopTaskDragPayload.fromTask(task),
        maxSimultaneousDrags: widget.enabled && !widget.selectionMode ? 1 : 0,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListTile(
              leading: const Icon(Icons.drag_indicator),
              title: Text(task.title),
              subtitle: const Text('Drop to reorder or move'),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.42, child: tile),
        onDragStarted: () =>
            widget.onDragStarted(DesktopTaskDragPayload.fromTask(task)),
        onDragEnd: (_) => widget.onDragCanceled(),
        child: tile,
      ),
    );
    return DragTarget<DesktopTaskDragPayload>(
      onWillAcceptWithDetails: (details) =>
          _dropIntent(details.data, details.offset) != null,
      onMove: (details) {
        widget.onDragMove(details.offset);
        widget.onDragPreview(_preview(details.data, details.offset));
      },
      onLeave: (payload) {
        if (payload != null) {
          widget.onDragPreview(_DesktopDropPreview.invalid(payload));
        }
      },
      onAcceptWithDetails: (details) {
        final intent = _dropIntent(details.data, details.offset);
        if (intent != null) widget.onDrop(intent);
      },
      builder: (context, _, _) => Stack(
        children: <Widget>[
          Focus(
            focusNode: widget.focusNode,
            onKeyEvent: _handleKey,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: draggable,
            ),
          ),
          if (widget.dropPreview case final preview?
              when preview.targetKey.startsWith('row-${widget.task.id.value}-'))
            Positioned(
              left: 16,
              right: 16,
              top: preview.targetKey.endsWith('-before') ? 0 : null,
              bottom: preview.targetKey.endsWith('-after') ? 0 : null,
              child: Divider(
                key: Key('desktop-task-drop-indicator-${task.id.value}'),
                height: 2,
                thickness: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

final class _DesktopPointerDraggable<T extends Object> extends Draggable<T> {
  const _DesktopPointerDraggable({
    required super.data,
    required super.feedback,
    required super.child,
    super.childWhenDragging,
    super.maxSimultaneousDrags,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => ImmediateMultiDragGestureRecognizer(
    supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
  )..onStart = onStart;
}

final class _DesktopDropPreview {
  const _DesktopDropPreview({
    required this.intent,
    required this.label,
    required this.targetKey,
  });

  factory _DesktopDropPreview.invalid(DesktopTaskDragPayload payload) =>
      _DesktopDropPreview(
        intent: null,
        label: 'Cannot drop “${payload.title}” here',
        targetKey: 'invalid',
      );

  final DesktopTaskDropIntent? intent;
  final String label;
  final String targetKey;
  bool get valid => intent != null;

  @override
  bool operator ==(Object other) =>
      other is _DesktopDropPreview &&
      other.intent == intent &&
      other.label == label &&
      other.targetKey == targetKey;

  @override
  int get hashCode => Object.hash(intent, label, targetKey);
}

List<PopupMenuEntry<DesktopTaskAction>> _taskActionMenuItems(
  CachedTask task, {
  required bool canMove,
}) => <PopupMenuEntry<DesktopTaskAction>>[
  const PopupMenuItem(
    value: DesktopTaskAction.open,
    child: Text('Open details'),
  ),
  PopupMenuItem(
    value: DesktopTaskAction.toggleCompletion,
    child: Text(
      task.status == TaskStatus.completed ? 'Reopen task' : 'Complete task',
    ),
  ),
  const PopupMenuItem(value: DesktopTaskAction.edit, child: Text('Edit task…')),
  const PopupMenuItem(
    value: DesktopTaskAction.chooseDate,
    child: Text('Choose date…'),
  ),
  PopupMenuItem(
    value: DesktopTaskAction.moveToList,
    enabled: canMove,
    child: const Text('Move to list…'),
  ),
  const PopupMenuDivider(),
  const PopupMenuItem(
    value: DesktopTaskAction.delete,
    child: Text('Delete task'),
  ),
];

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
