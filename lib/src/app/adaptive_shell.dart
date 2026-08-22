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
import '../domain/repository/preferences_repository.dart';
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
import 'desktop_workspace.dart';
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
    this.preferencesRepository,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
    this.settingsBuilder,
    super.key,
  });

  final TasksViewModel viewModel;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final String? initialQuickAddInput;
  final String? initialBulkAddInput;
  final String? initialSearchQuery;
  final AppNavigationController? navigation;
  final PreferencesRepository? preferencesRepository;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;
  final WidgetBuilder? settingsBuilder;

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
  StreamSubscription<DevicePreferences>? _devicePreferences;
  DesktopWorkspacePreferences _workspace =
      const DesktopWorkspacePreferences.defaults();
  DensityPreference _density = DensityPreference.standard;
  bool _workspaceDirty = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.start();
    _ownsNavigation = widget.navigation == null;
    _navigation = widget.navigation ?? AppNavigationController();
    _navigation.addListener(_navigationChanged);
    _listenToDevicePreferences();
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

  void _listenToDevicePreferences() {
    _devicePreferences?.cancel();
    final repository = widget.preferencesRepository;
    if (repository == null) return;
    _devicePreferences = repository.watchDevicePreferences().listen((value) {
      if (!mounted) return;
      if (_workspaceDirty && value.workspace != _workspace) return;
      setState(() {
        _workspace = value.workspace;
        _density = value.density;
        _workspaceDirty = false;
      });
    });
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
    if (oldWidget.preferencesRepository != widget.preferencesRepository) {
      _listenToDevicePreferences();
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
    destinationRequired: () =>
        widget.viewModel.state.selectedTaskListId == null,
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
    widget.viewModel.startTaskDragFeedback();
    setState(() {
      _dragPayload = payload;
      _dropPreview = null;
    });
  }

  void _previewTaskDrop(_DesktopDropPreview preview) {
    if (_dragPayload == null || _dropPreview == preview) return;
    setState(() => _dropPreview = preview);
  }

  void _cancelTaskDrag() {
    if (_dragPayload == null && _dropPreview == null) return;
    final rejection = _dropPreview?.rejectionMessage;
    setState(() {
      _dragPayload = null;
      _dropPreview = null;
    });
    if (rejection != null) widget.viewModel.reportInvalidTaskDrop(rejection);
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

  void _updateWorkspace(DesktopWorkspacePreferences preferences) {
    setState(() {
      _workspace = preferences;
      _workspaceDirty = true;
    });
    final repository = widget.preferencesRepository;
    if (repository != null) {
      unawaited(repository.setWorkspacePreferences(preferences));
    }
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
    _devicePreferences?.cancel();
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
                        onRefresh: widget.viewModel.refreshRequested == null
                            ? null
                            : widget.viewModel.refresh,
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
                        settingsBuilder: widget.settingsBuilder,
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
                            final wide = constraints.maxWidth >= 1024;
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
    workspace: _workspace,
    density: _density,
    onWorkspaceChanged: _updateWorkspace,
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
    this.settingsBuilder,
  });

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final bool isRefreshing;
  final bool isSyncControlPending;
  final Future<void> Function()? onRefresh;
  final Future<void> Function() onStopSync;
  final VoidCallback onSearch;
  final VoidCallback onShowShortcuts;
  final bool showSearch;
  final VoidCallback onOpenNavigation;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;
  final WidgetBuilder? settingsBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildForWidth(context, constraints.maxWidth),
  );

  Widget _buildForWidth(BuildContext context, double width) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18.2;
    final tokens = Theme.of(context).axiotaskTokens;
    return Column(
      children: <Widget>[
        Semantics(
          container: true,
          label: 'Axiotask application controls',
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Container(
              key: const Key('desktop-application-header'),
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
                  const Spacer(),
                  if (width < 900)
                    _HeaderFocusOrder(
                      order: 1,
                      child: IconButton(
                        tooltip: 'Open navigation',
                        onPressed: onOpenNavigation,
                        icon: const Icon(Icons.menu),
                      ),
                    ),
                  if (showSearch)
                    _HeaderFocusOrder(
                      order: 2,
                      child: IconButton(
                        tooltip: 'Search tasks',
                        onPressed: onSearch,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  if (health.outcome == SyncHealthOutcome.good)
                    _HeaderFocusOrder(
                      order: 2.5,
                      child: SyncHealthHeader(
                        health: health,
                        diagnosticsBuilder: diagnosticsBuilder,
                        iconOnly: largeText,
                      ),
                    ),
                  _HeaderFocusOrder(
                    order: 3,
                    child: IconButton(
                      tooltip: 'Refresh',
                      onPressed:
                          isRefreshing ||
                              isSyncControlPending ||
                              onRefresh == null ||
                              health.outcome == SyncHealthOutcome.inactive
                          ? null
                          : onRefresh,
                      icon: isRefreshing
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ),
                  if (health.outcome != SyncHealthOutcome.inactive)
                    _HeaderFocusOrder(
                      order: 4,
                      child: IconButton(
                        tooltip: 'Stop sync',
                        onPressed: isSyncControlPending ? null : onStopSync,
                        icon: isSyncControlPending
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.pause_circle_outline),
                      ),
                    ),
                  _HeaderFocusOrder(
                    order: 5,
                    child: _ApplicationOverflow(
                      onShowShortcuts: onShowShortcuts,
                      settingsBuilder: settingsBuilder,
                      accountBackupBuilder: accountBackupBuilder,
                      localDataRecoveryBuilder: localDataRecoveryBuilder,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (health.outcome != SyncHealthOutcome.good)
          SyncHealthHeader(
            health: health,
            onAction: onHealthAction,
            diagnosticsBuilder: diagnosticsBuilder,
          ),
      ],
    );
  }
}

final class _HeaderFocusOrder extends StatelessWidget {
  const _HeaderFocusOrder({required this.order, required this.child});

  final double order;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      FocusTraversalOrder(order: NumericFocusOrder(order), child: child);
}

final class _ApplicationOverflow extends StatelessWidget {
  const _ApplicationOverflow({
    required this.onShowShortcuts,
    this.settingsBuilder,
    this.accountBackupBuilder,
    this.localDataRecoveryBuilder,
  });

  final VoidCallback onShowShortcuts;
  final WidgetBuilder? settingsBuilder;
  final WidgetBuilder? accountBackupBuilder;
  final WidgetBuilder? localDataRecoveryBuilder;

  void _open(BuildContext context, WidgetBuilder builder) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: builder));
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: <Widget>[
      MenuItemButton(
        leadingIcon: const Icon(Icons.keyboard_outlined),
        onPressed: onShowShortcuts,
        child: const Text('Keyboard shortcuts'),
      ),
      if (settingsBuilder case final builder?)
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_outlined),
          onPressed: () => _open(context, builder),
          child: const Text('Settings'),
        ),
      if (accountBackupBuilder case final builder?)
        MenuItemButton(
          leadingIcon: const Icon(Icons.save_alt_outlined),
          onPressed: () => _open(context, builder),
          child: const Text('Account backup'),
        ),
      if (localDataRecoveryBuilder case final builder?)
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_backup_restore),
          onPressed: () => _open(context, builder),
          child: const Text('Local data recovery'),
        ),
    ],
    builder: (context, controller, _) => Tooltip(
      message: 'More app actions',
      child: TextButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: const Icon(Icons.more_horiz),
        label: const Text('More'),
      ),
    ),
  );
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
    required this.workspace,
    required this.density,
    required this.onWorkspaceChanged,
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
  final DesktopWorkspacePreferences workspace;
  final DensityPreference density;
  final ValueChanged<DesktopWorkspacePreferences> onWorkspaceChanged;

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
                  density: density,
                )
              : _DesktopPaneFocus(
                  key: const Key('desktop-detail-pane'),
                  focusNode: detailPaneFocus,
                  child: TaskDetailsPane(viewModel: detail, compact: true),
                )
        : LayoutBuilder(
            builder: (context, constraints) {
              final hasDetail = detail.state != null;
              final layout = DesktopWorkspaceLayout.resolve(
                availableWidth: constraints.maxWidth,
                textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
                density: density,
                hasDetail: hasDetail,
                preferences: workspace,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: layout.navigationWidth,
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
                  _DesktopWorkspaceSplitter(
                    key: const Key('desktop-navigation-splitter'),
                    label: 'Resize navigation pane',
                    value: layout.navigationWidth,
                    onDrag: (delta) => onWorkspaceChanged(
                      DesktopWorkspaceLayout.adjustNavigation(
                        preferences: workspace,
                        delta: delta,
                        density: density,
                      ),
                    ),
                    onIncrease: () => onWorkspaceChanged(
                      DesktopWorkspaceLayout.adjustNavigation(
                        preferences: workspace,
                        delta: 16,
                        density: density,
                      ),
                    ),
                    onDecrease: () => onWorkspaceChanged(
                      DesktopWorkspaceLayout.adjustNavigation(
                        preferences: workspace,
                        delta: -16,
                        density: density,
                      ),
                    ),
                  ),
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
                      density: density,
                    ),
                  ),
                  if (hasDetail) ...<Widget>[
                    _DesktopWorkspaceSplitter(
                      key: const Key('desktop-detail-splitter'),
                      label: 'Resize task details pane',
                      value: layout.detailWidth,
                      onDrag: (delta) => onWorkspaceChanged(
                        DesktopWorkspaceLayout.adjustDetail(
                          preferences: workspace,
                          delta: -delta,
                          density: density,
                        ),
                      ),
                      onIncrease: () => onWorkspaceChanged(
                        DesktopWorkspaceLayout.adjustDetail(
                          preferences: workspace,
                          delta: 16,
                          density: density,
                        ),
                      ),
                      onDecrease: () => onWorkspaceChanged(
                        DesktopWorkspaceLayout.adjustDetail(
                          preferences: workspace,
                          delta: -16,
                          density: density,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: layout.detailWidth,
                      child: _DesktopPaneFocus(
                        key: const Key('desktop-detail-pane'),
                        focusNode: detailPaneFocus,
                        child: TaskDetailsPane(
                          viewModel: detail,
                          compact: false,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
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

final class _DesktopWorkspaceSplitter extends StatelessWidget {
  const _DesktopWorkspaceSplitter({
    required this.label,
    required this.value,
    required this.onDrag,
    required this.onIncrease,
    required this.onDecrease,
    super.key,
  });

  final String label;
  final double value;
  final ValueChanged<double> onDrag;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    slider: true,
    value: '${value.round()} pixels',
    increasedValue: '${(value + 16).round()} pixels',
    decreasedValue: '${(value - 16).round()} pixels',
    onIncrease: onIncrease,
    onDecrease: onDecrease,
    child: Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          onIncrease();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          onDecrease();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (focusContext) => MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: Listener(
            onPointerMove: (event) {
              if (event.buttons != 0) onDrag(event.delta.dx);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Focus.of(focusContext).requestFocus(),
              child: SizedBox(
                width: DesktopWorkspaceLayout.splitterWidth,
                child: Center(
                  child: Container(
                    width: 2,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
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
    return FocusTraversalGroup(
      key: const Key('selection-collection-command-bar'),
      policy: OrderedTraversalPolicy(),
      child: Material(
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
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FilledButton.icon(
                  key: const Key('bulk-complete-open'),
                  onPressed: enabled
                      ? () => unawaited(
                          _showBulkCompleteConfirmation(context, viewModel),
                        )
                      : null,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Complete'),
                ),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: OutlinedButton.icon(
                  key: const Key('bulk-reschedule-open'),
                  onPressed: enabled
                      ? () => unawaited(_showBulkDateDialog(context, viewModel))
                      : null,
                  icon: const Icon(Icons.event_outlined),
                  label: const Text('Reschedule'),
                ),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: OutlinedButton.icon(
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
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(4),
                child: OutlinedButton.icon(
                  key: const Key('bulk-delete-open'),
                  onPressed: enabled
                      ? () => unawaited(
                          _showBulkDeleteConfirmation(context, viewModel),
                        )
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(5),
                child: IconButton(
                  key: const Key('bulk-selection-close'),
                  tooltip: 'Exit task selection',
                  onPressed: enabled ? viewModel.clearBulkSelection : null,
                  icon: const Icon(Icons.close),
                ),
              ),
              if (state.isBulkCommandPending)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CollectionMenuAction {
  addTaskWithDetails,
  pasteMultiple,
  createList,
  renameList,
  deleteList,
  clearCompleted,
  toggleShowCompleted,
}

final class _NormalCollectionCommandBar extends StatelessWidget {
  const _NormalCollectionCommandBar({
    required this.state,
    required this.viewModel,
    required this.tasks,
    required this.clearCompletedCount,
    required this.openBulkAdd,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final List<CachedTask> tasks;
  final int clearCompletedCount;
  final VoidCallback openBulkAdd;

  @override
  Widget build(BuildContext context) {
    final canSelect =
        viewModel.tasksRepository is BulkTaskOperationsRepository &&
        tasks.isNotEmpty;
    final canManageLists = viewModel.taskListsRepository != null;
    final hasList = state.selectedTaskList != null;
    final canToggleCompleted = viewModel.preferencesRepository != null;
    final canClearCompleted =
        viewModel.tasksRepository is DestructiveTaskOperationsRepository &&
        hasList &&
        clearCompletedCount > 0;
    final hasMenuActions =
        (hasList && !state.isTaskCommandPending) ||
        viewModel.tasksRepository is BulkTasksRepository ||
        canManageLists ||
        canToggleCompleted ||
        canClearCompleted;

    return FocusTraversalGroup(
      key: const Key('normal-collection-command-bar'),
      policy: OrderedTraversalPolicy(),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (viewModel.preferencesRepository != null)
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: PopupMenuButton<ViewSort>(
                key: const Key('collection-sort'),
                tooltip: 'Sort tasks',
                initialValue: state.selectedViewPreferences.sort,
                enabled: !state.isPreferenceCommandPending,
                onSelected: (value) => unawaited(viewModel.setViewSort(value)),
                itemBuilder: (_) => <PopupMenuEntry<ViewSort>>[
                  for (final value in ViewSort.values)
                    CheckedPopupMenuItem<ViewSort>(
                      value: value,
                      checked: value == state.selectedViewPreferences.sort,
                      child: Text(_viewSortLabel(value)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.sort, size: 20),
                      const SizedBox(width: 4),
                      Text(_viewSortLabel(state.selectedViewPreferences.sort)),
                    ],
                  ),
                ),
              ),
            ),
          if (canSelect)
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: OutlinedButton.icon(
                key: const Key('bulk-select-open'),
                onPressed: () => viewModel.beginBulkSelection(tasks.first.id),
                icon: const Icon(Icons.library_add_check_outlined),
                label: const Text('Select'),
              ),
            ),
          if (hasMenuActions)
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: PopupMenuButton<_CollectionMenuAction>(
                key: const Key('collection-actions-menu'),
                tooltip: 'Collection actions',
                onSelected: (action) => _handleAction(context, action),
                itemBuilder: (menuContext) => _menuItems(
                  menuContext,
                  hasList: hasList,
                  canManageLists: canManageLists,
                  canToggleCompleted: canToggleCompleted,
                  canClearCompleted: canClearCompleted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<_CollectionMenuAction>> _menuItems(
    BuildContext context, {
    required bool hasList,
    required bool canManageLists,
    required bool canToggleCompleted,
    required bool canClearCompleted,
  }) => <PopupMenuEntry<_CollectionMenuAction>>[
    if (hasList)
      PopupMenuItem<_CollectionMenuAction>(
        key: const Key('collection-add-task-with-details'),
        value: _CollectionMenuAction.addTaskWithDetails,
        enabled: !state.isTaskCommandPending,
        child: Text('Add task with details'),
      ),
    if (viewModel.tasksRepository is BulkTasksRepository)
      const PopupMenuItem<_CollectionMenuAction>(
        key: Key('bulk-add-open'),
        value: _CollectionMenuAction.pasteMultiple,
        child: Text('Paste multiple tasks'),
      ),
    if (hasList || viewModel.tasksRepository is BulkTasksRepository)
      const PopupMenuDivider(),
    if (canManageLists)
      PopupMenuItem<_CollectionMenuAction>(
        key: const Key('collection-create-list'),
        value: _CollectionMenuAction.createList,
        enabled: !state.isListCommandPending,
        child: Text('Create Google task list'),
      ),
    if (canManageLists && hasList)
      PopupMenuItem<_CollectionMenuAction>(
        key: const Key('collection-rename-list'),
        value: _CollectionMenuAction.renameList,
        enabled: !state.isListCommandPending,
        child: Text('Rename task list'),
      ),
    if (canManageLists && hasList)
      PopupMenuItem<_CollectionMenuAction>(
        key: const Key('collection-delete-list'),
        value: _CollectionMenuAction.deleteList,
        enabled: !state.isListCommandPending,
        child: Text(
          'Delete task list',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    if (canManageLists && hasList && (canToggleCompleted || canClearCompleted))
      const PopupMenuDivider(),
    if (canToggleCompleted)
      CheckedPopupMenuItem<_CollectionMenuAction>(
        key: const Key('collection-show-completed'),
        value: _CollectionMenuAction.toggleShowCompleted,
        enabled: !state.isPreferenceCommandPending,
        checked: state.selectedViewPreferences.showCompleted,
        child: const Text('Show completed'),
      ),
    if (canClearCompleted)
      PopupMenuItem<_CollectionMenuAction>(
        key: const Key('clear-completed-open'),
        value: _CollectionMenuAction.clearCompleted,
        enabled: !state.isBulkCommandPending,
        child: Text(
          'Clear completed',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
  ];

  void _handleAction(BuildContext context, _CollectionMenuAction action) {
    final list = state.selectedTaskList;
    switch (action) {
      case _CollectionMenuAction.addTaskWithDetails:
        if (list != null) _showCreateTaskDialog(context, viewModel, list.id);
      case _CollectionMenuAction.pasteMultiple:
        openBulkAdd();
      case _CollectionMenuAction.createList:
        _showCreateTaskListDialog(context, viewModel);
      case _CollectionMenuAction.renameList:
        if (list != null) _showRenameTaskListDialog(context, viewModel, list);
      case _CollectionMenuAction.deleteList:
        if (list != null) {
          unawaited(_showDeleteTaskListConfirmation(context, viewModel, list));
        }
      case _CollectionMenuAction.clearCompleted:
        unawaited(_showClearCompletedConfirmation(context, viewModel));
      case _CollectionMenuAction.toggleShowCompleted:
        unawaited(
          viewModel.setShowCompleted(
            !state.selectedViewPreferences.showCompleted,
          ),
        );
    }
  }
}

String _viewSortLabel(ViewSort value) => switch (value) {
  ViewSort.manual => 'My order',
  ViewSort.effectiveDue => 'Due date',
  ViewSort.title => 'Title',
  ViewSort.created => 'Reverse order',
};

String _collectionCountLabel(SyncHealth health, int count) {
  final noun = count == 1 ? 'task' : 'tasks';
  return switch (health.outcome) {
    SyncHealthOutcome.good => '$count $noun',
    SyncHealthOutcome.failed
        when health.failureReason == SyncFailureReason.stale =>
      '$count stale $noun',
    _ => '$count cached $noun',
  };
}

final class _TransientTaskFeedbackSlot extends StatelessWidget {
  const _TransientTaskFeedbackSlot({required this.feedback});

  final TransientTaskFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final currentFeedback = feedback;
    final label = switch (currentFeedback) {
      TransientTaskFeedback(
        kind: TransientTaskFeedbackKind.invalidDrop,
        :final message?,
      ) =>
        message,
      TransientTaskFeedback(
        kind: TransientTaskFeedbackKind.bulkSuccess,
        bulkOperation: final summary?,
      ) =>
        '${_bulkKindLabel(summary.kind)}: '
            '${summary.confirmedCount} confirmed with Google',
      null => null,
      _ => null,
    };
    if (label == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Material(
        key: const Key('transient-task-feedback'),
        color: currentFeedback!.kind == TransientTaskFeedbackKind.invalidDrop
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color:
                  currentFeedback.kind == TransientTaskFeedbackKind.invalidDrop
                  ? Theme.of(context).colorScheme.onErrorContainer
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
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
        onPreview!(
          intent == null
              ? _DesktopDropPreview.invalid(
                  message:
                      DesktopTaskDragAdapter.moveToListRejectionReason(
                        payload: details.data,
                        destinationTaskListId: taskList.id,
                      ) ??
                      'This drop target is not available.',
                  targetKey: targetKey,
                )
              : _DesktopDropPreview(
                  intent: intent,
                  label: 'Move “${details.data.title}” to “${taskList.title}”',
                  targetKey: targetKey,
                ),
        );
      },
      onAcceptWithDetails: (details) {
        final intent = _intent(details.data);
        if (intent != null) onDrop!(intent);
      },
      builder: (context, _, _) => Material(
        key: Key('desktop-list-drop-target-${taskList.id.value}'),
        color: preview?.targetKey != targetKey
            ? Colors.transparent
            : preview!.valid
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.errorContainer,
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
    required this.density,
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
  final DensityPreference density;

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
    final rowMetrics = _DesktopTaskRowMetrics.forDensity(widget.density);
    final clearSelection = state.clearCompletedSelection;
    final clearCompletedCount = clearSelection == null
        ? 0
        : clearSelection.completedTaskCount -
              clearSelection.skippedParentTaskIds.length;
    _ensureFocusNodes(tasks.length);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          key: const Key('collection-header'),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow =
                  MediaQuery.textScalerOf(context).scale(14) / 14 > 1.4;
              final title = Text(
                switch (state.selectedView) {
                  SmartTaskView(:final smartView) => smartView.title,
                  TaskListView() => state.selectedTaskList?.title ?? 'Tasks',
                },
                maxLines: narrow ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              );
              final commands = state.isBulkSelectionActive
                  ? _BulkActionBar(state: state, viewModel: viewModel)
                  : _NormalCollectionCommandBar(
                      state: state,
                      viewModel: viewModel,
                      tasks: tasks,
                      clearCompletedCount: clearCompletedCount,
                      openBulkAdd: openBulkAdd,
                    );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (narrow) ...<Widget>[
                    title,
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerLeft, child: commands),
                  ] else
                    Row(
                      children: <Widget>[
                        Expanded(child: title),
                        const SizedBox(width: 8),
                        commands,
                      ],
                    ),
                  const SizedBox(height: 2),
                  QuickAddBar(
                    viewModel: quickAdd,
                    lists: state.orderedTaskLists,
                    focusNode: quickAddFocus,
                    onPasteMultiple: openBulkAdd,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _collectionCountLabel(state.health, tasks.length),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
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
                  padding: EdgeInsets.symmetric(vertical: rowMetrics.listInset),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, indent: rowMetrics.contentStart),
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
                      density: widget.density,
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
            ],
          ),
        ),
      ],
    );
    final feedback = state.transientFeedback;
    if (feedback == null) return content;

    return Stack(
      children: <Widget>[
        content,
        Positioned(
          top: 20,
          left: 24,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: _TransientTaskFeedbackSlot(feedback: feedback),
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
    required this.density,
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
  final DensityPreference density;

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
    if (intent == null) {
      return _DesktopDropPreview.invalid(
        message:
            DesktopTaskDragAdapter.reorderRejectionReason(
              payload: payload,
              target: widget.task,
              placement: placement,
              canonicalSiblings: widget.canonicalSiblings,
              manualOrderEnabled: widget.manualOrderEnabled,
            ) ??
            'This drop target is not available.',
        targetKey: 'row-${widget.task.id.value}-${placement.name}',
      );
    }
    return _DesktopDropPreview(
      intent: intent,
      label: 'Move “${payload.title}” ${placement.name} “${widget.task.title}”',
      targetKey: 'row-${widget.task.id.value}-${placement.name}',
    );
  }

  Widget _tile(CachedTask task) {
    final metrics = _DesktopTaskRowMetrics.forDensity(widget.density);
    final theme = Theme.of(context);
    final focused = widget.focusNode.hasFocus;
    final selected = widget.selected || focused;
    final completed = task.status == TaskStatus.completed;
    final foreground = completed
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    final background = selected
        ? theme.colorScheme.secondaryContainer
        : _hovered
        ? theme.axiotaskTokens.hoverColor
        : Colors.transparent;
    final titleStyle = theme.textTheme.bodyLarge?.copyWith(
      color: foreground,
      decoration: completed ? TextDecoration.lineThrough : null,
    );
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      decoration: completed ? TextDecoration.lineThrough : null,
    );
    final controlStyle = IconButton.styleFrom(
      minimumSize: Size.square(metrics.controlSize),
      maximumSize: Size.square(metrics.controlSize),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
    final completion = widget.selectionMode
        ? SizedBox(
            width: metrics.controlSize,
            height: metrics.controlSize,
            child: Checkbox(
              key: Key('bulk-select-task-${task.id.value}'),
              value: widget.bulkSelected,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: widget.enabled
                  ? (_) => widget.onSelectionToggle()
                  : null,
            ),
          )
        : IconButton(
            tooltip: completed ? 'Reopen task' : 'Complete task',
            style: controlStyle,
            onPressed: widget.enabled
                ? () => widget.onAction(DesktopTaskAction.toggleCompletion)
                : null,
            icon: Icon(
              completed ? Icons.check_circle : Icons.radio_button_unchecked,
              size: metrics.iconSize,
            ),
          );
    final actions = widget.selectionMode
        ? const SizedBox.shrink()
        : SizedBox(
            width: metrics.actionSlotWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                AnimatedOpacity(
                  opacity: _hovered || focused ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hovered && !focused,
                    child: IconButton(
                      tooltip: 'Open ${task.title}',
                      style: controlStyle,
                      onPressed: widget.enabled
                          ? () => widget.onAction(DesktopTaskAction.open)
                          : null,
                      icon: Icon(Icons.open_in_new, size: metrics.iconSize),
                    ),
                  ),
                ),
                Semantics(
                  container: true,
                  button: true,
                  label: 'Task actions for ${task.title}',
                  child: PopupMenuButton<DesktopTaskAction>(
                    tooltip: 'Task actions for ${task.title}',
                    enabled: widget.enabled,
                    iconSize: metrics.iconSize,
                    constraints: BoxConstraints.tightFor(
                      width: metrics.controlSize,
                      height: metrics.controlSize,
                    ),
                    onSelected: widget.onAction,
                    itemBuilder: (_) =>
                        _taskActionMenuItems(task, canMove: widget.canMove),
                  ),
                ),
              ],
            ),
          );
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Material(
          color: background,
          child: InkWell(
            excludeFromSemantics: true,
            onTap: widget.enabled
                ? widget.selectionMode
                      ? widget.onSelectionToggle
                      : () => widget.onAction(DesktopTaskAction.open)
                : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: metrics.minimumHeight),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: metrics.horizontalInset,
                  vertical: metrics.verticalInset,
                ),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: metrics.leadingWidth,
                      child: Center(child: completion),
                    ),
                    SizedBox(width: metrics.contentGap),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                          if (widget.subtitle.isNotEmpty)
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                            ),
                        ],
                      ),
                    ),
                    if (!widget.selectionMode) actions,
                  ],
                ),
              ),
            ),
          ),
        ),
        if (focused)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

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
      container: true,
      explicitChildNodes: true,
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
          widget.onDragPreview(
            _DesktopDropPreview.invalid(
              message: 'This drop target is not available.',
              targetKey: 'row-${widget.task.id.value}',
            ),
          );
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
              when preview.targetKey.startsWith('row-${widget.task.id.value}'))
            if (preview.valid)
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
              )
            else
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: Key('desktop-task-drop-rejection-${task.id.value}'),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Keeps desktop task rows calm and compact while allowing larger text to grow
/// the row naturally instead of clipping either line or the focus treatment.
final class _DesktopTaskRowMetrics {
  const _DesktopTaskRowMetrics({
    required this.minimumHeight,
    required this.horizontalInset,
    required this.verticalInset,
    required this.leadingWidth,
    required this.contentGap,
    required this.actionSlotWidth,
    required this.controlSize,
    required this.iconSize,
    required this.listInset,
  });

  factory _DesktopTaskRowMetrics.forDensity(DensityPreference density) =>
      switch (density) {
        DensityPreference.standard => const _DesktopTaskRowMetrics(
          minimumHeight: 56,
          horizontalInset: 16,
          verticalInset: 4,
          leadingWidth: 40,
          contentGap: 8,
          actionSlotWidth: 96,
          controlSize: 40,
          iconSize: 20,
          listInset: 4,
        ),
        DensityPreference.compact => const _DesktopTaskRowMetrics(
          minimumHeight: 48,
          horizontalInset: 12,
          verticalInset: 2,
          leadingWidth: 36,
          contentGap: 8,
          actionSlotWidth: 96,
          controlSize: 36,
          iconSize: 20,
          listInset: 2,
        ),
      };

  final double minimumHeight;
  final double horizontalInset;
  final double verticalInset;
  final double leadingWidth;
  final double contentGap;
  final double actionSlotWidth;
  final double controlSize;
  final double iconSize;
  final double listInset;

  double get contentStart => horizontalInset + leadingWidth + contentGap;
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

  factory _DesktopDropPreview.invalid({
    required String message,
    required String targetKey,
  }) => _DesktopDropPreview(intent: null, label: message, targetKey: targetKey);

  final DesktopTaskDropIntent? intent;
  final String label;
  final String targetKey;
  bool get valid => intent != null;
  String? get rejectionMessage => valid ? null : label;

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
