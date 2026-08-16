import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('back removes the actual top route in deterministic surface order', () {
    final navigation = AppNavigationController();
    addTearDown(navigation.dispose);

    navigation.openDrawer();
    navigation.openTaskDetail(const TaskId(7));
    navigation.beginSelection(<TaskId>{const TaskId(7), const TaskId(8)});
    navigation.dialogOpened(AppDialogKind.taskEdit);

    expect(navigation.state.canHandlePredictiveBack, isTrue);
    expect(navigation.back(), const AppDialogRoute(AppDialogKind.taskEdit));
    expect(navigation.back(), isA<TaskSelectionRoute>());
    expect(navigation.back(), const TaskDetailRoute(TaskId(7)));
    expect(navigation.back(), const DrawerRoute());
    expect(navigation.state.canHandlePredictiveBack, isFalse);
    expect(navigation.back(), isNull);
  });

  test(
    'search/detail routes use stable local identity and replace duplicates',
    () {
      final navigation = AppNavigationController();
      addTearDown(navigation.dispose);

      navigation.openSearch();
      navigation.openSearch();
      navigation.openTaskDetail(const TaskId(4));
      navigation.openTaskDetail(const TaskId(5));

      expect(navigation.state.routes, <AppRoute>[
        const CollectionRoute(),
        const SearchRoute(),
        const TaskDetailRoute(TaskId(5)),
      ]);
      expect(
        navigation.state.predictiveBackRoute,
        const TaskDetailRoute(TaskId(5)),
      );
    },
  );

  test('drawer, selection, and dialog state contain no widget-owned flags', () {
    final navigation = AppNavigationController();
    addTearDown(navigation.dispose);

    navigation.openDrawer();
    navigation.beginSelection(<TaskId>{const TaskId(2)});
    navigation.dialogOpened(AppDialogKind.confirmation);
    expect(navigation.state.drawerOpen, isTrue);
    expect(navigation.state.selectedTaskIds, <TaskId>{const TaskId(2)});
    expect(navigation.state.dialog, AppDialogKind.confirmation);

    navigation.dialogClosed(AppDialogKind.confirmation);
    navigation.clearSelection();
    navigation.closeDrawer();
    expect(navigation.state.routes, const <AppRoute>[CollectionRoute()]);
  });

  test(
    'selection route equality is independent of selection insertion order',
    () {
      final left = TaskSelectionRoute(<TaskId>{
        const TaskId(1),
        const TaskId(2),
      });
      final right = TaskSelectionRoute(<TaskId>{
        const TaskId(2),
        const TaskId(1),
      });
      expect(left, right);
      expect(left.hashCode, right.hashCode);
    },
  );

  test('selection route snapshots caller-owned state', () {
    final selected = <TaskId>{const TaskId(1)};
    final route = TaskSelectionRoute(selected);

    selected.add(const TaskId(2));

    expect(route.taskIds, <TaskId>{const TaskId(1)});
  });
}
