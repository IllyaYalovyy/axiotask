import 'dart:collection';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../domain/model/tasks.dart';

sealed class AppRoute {
  const AppRoute();
}

final class CollectionRoute extends AppRoute {
  const CollectionRoute();

  @override
  bool operator ==(Object other) => other is CollectionRoute;

  @override
  int get hashCode => 1;
}

final class DrawerRoute extends AppRoute {
  const DrawerRoute();

  @override
  bool operator ==(Object other) => other is DrawerRoute;

  @override
  int get hashCode => 2;
}

final class SearchRoute extends AppRoute {
  const SearchRoute();

  @override
  bool operator ==(Object other) => other is SearchRoute;

  @override
  int get hashCode => 3;
}

final class TaskDetailRoute extends AppRoute {
  const TaskDetailRoute(this.taskId);

  final TaskId taskId;

  @override
  bool operator ==(Object other) =>
      other is TaskDetailRoute && taskId == other.taskId;

  @override
  int get hashCode => Object.hash(TaskDetailRoute, taskId);
}

final class TaskSelectionRoute extends AppRoute {
  TaskSelectionRoute(Set<TaskId> taskIds)
    : taskIds = UnmodifiableSetView<TaskId>(Set<TaskId>.of(taskIds));

  final Set<TaskId> taskIds;

  @override
  bool operator ==(Object other) =>
      other is TaskSelectionRoute && setEquals(taskIds, other.taskIds);

  @override
  int get hashCode =>
      Object.hash(TaskSelectionRoute, Object.hashAllUnordered(taskIds));
}

enum AppDialogKind { taskEdit, listEdit, confirmation, date, bulkCapture }

final class AppDialogRoute extends AppRoute {
  const AppDialogRoute(this.kind);

  final AppDialogKind kind;

  @override
  bool operator ==(Object other) =>
      other is AppDialogRoute && kind == other.kind;

  @override
  int get hashCode => Object.hash(AppDialogRoute, kind);
}

final class AppNavigationState {
  AppNavigationState(List<AppRoute> routes)
    : routes = UnmodifiableListView<AppRoute>(routes);

  final List<AppRoute> routes;

  bool get canHandlePredictiveBack => routes.length > 1;
  AppRoute? get predictiveBackRoute =>
      canHandlePredictiveBack ? routes.last : null;
  bool get drawerOpen => routes.any((route) => route is DrawerRoute);
  Set<TaskId> get selectedTaskIds =>
      routes.whereType<TaskSelectionRoute>().lastOrNull?.taskIds ??
      const <TaskId>{};
  AppDialogKind? get dialog =>
      routes.whereType<AppDialogRoute>().lastOrNull?.kind;
}

final class AppNavigationController extends ChangeNotifier {
  AppNavigationController()
    : _state = AppNavigationState(const <AppRoute>[CollectionRoute()]);

  AppNavigationState _state;
  AppNavigationState get state => _state;
  AppRoute get currentRoute => _state.routes.last;

  void openDrawer() => _pushUnique(const DrawerRoute());
  void closeDrawer() => _removeWhere((route) => route is DrawerRoute);
  void openSearch() => _pushUnique(const SearchRoute());

  void openTaskDetail(TaskId taskId) {
    final routes = _without((route) => route is TaskDetailRoute);
    routes.add(TaskDetailRoute(taskId));
    _replace(routes);
  }

  void closeTaskDetail() => _removeWhere((route) => route is TaskDetailRoute);

  void removeRoute(AppRoute route) =>
      _removeWhere((candidate) => candidate == route, lastOnly: true);

  void beginSelection(Set<TaskId> taskIds) {
    if (taskIds.isEmpty) {
      clearSelection();
      return;
    }
    final routes = _without((route) => route is TaskSelectionRoute);
    routes.add(TaskSelectionRoute(taskIds));
    _replace(routes);
  }

  void clearSelection() => _removeWhere((route) => route is TaskSelectionRoute);

  void dialogOpened(AppDialogKind kind) => _pushUnique(AppDialogRoute(kind));

  void dialogClosed(AppDialogKind kind) => _removeWhere(
    (route) => route is AppDialogRoute && route.kind == kind,
    lastOnly: true,
  );

  AppRoute? back() {
    if (!_state.canHandlePredictiveBack) return null;
    final routes = _state.routes.toList(growable: true);
    final removed = routes.removeLast();
    _replace(routes);
    return removed;
  }

  void _pushUnique(AppRoute route) {
    final routes = _without(
      (candidate) => candidate.runtimeType == route.runtimeType,
    );
    routes.add(route);
    _replace(routes);
  }

  List<AppRoute> _without(bool Function(AppRoute route) predicate) => _state
      .routes
      .where((route) => route is CollectionRoute || !predicate(route))
      .toList(growable: true);

  void _removeWhere(
    bool Function(AppRoute route) predicate, {
    bool lastOnly = false,
  }) {
    final routes = _state.routes.toList(growable: true);
    if (lastOnly) {
      final index = routes.lastIndexWhere(predicate);
      if (index <= 0) return;
      routes.removeAt(index);
    } else {
      routes.removeWhere(
        (route) => route is! CollectionRoute && predicate(route),
      );
    }
    _replace(routes);
  }

  void _replace(List<AppRoute> routes) {
    _state = AppNavigationState(routes);
    notifyListeners();
  }
}

final class AppNavigationScope
    extends InheritedNotifier<AppNavigationController> {
  const AppNavigationScope({
    required AppNavigationController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppNavigationController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required AppDialogKind kind,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigation = AppNavigationScope.maybeOf(context);
  navigation?.dialogOpened(kind);
  try {
    return await showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
  } finally {
    navigation?.dialogClosed(kind);
  }
}
