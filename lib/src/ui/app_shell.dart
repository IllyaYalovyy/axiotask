// The app shell — the ShellRoute builder that turns the current URL into the
// adaptive [ListDetailScaffold], builds the real [Sidebar] from the store and
// prefs, wires navigation + list management back into go_router / the command
// layer, persists the selected view, and keeps the desktop window title in sync
// (now resolving list ids to their titles).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/pending_edits.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'composer_controller.dart';
import 'detail_motion.dart';
import 'guarded_command.dart';
import 'haptics.dart';
import 'list_detail_scaffold.dart';
import 'onboarding.dart';
import 'properties.dart';
import 'router.dart';
import 'sidebar.dart';
import 'sync_feedback.dart';
import 'task_detail.dart';
import 'task_list_view.dart';
import 'theme.dart' show coarsePointerPlatform;
import 'toast.dart';
import 'view_motion.dart';
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
    final prefs = ref.watch(prefsControllerProvider);
    final excluded = prefs.excludedLists.toSet();
    final footer = ref.watch(sidebarFooterProvider);
    final listTitles = {for (final l in lists) l.list.id: l.list.title};

    // First-launch welcome: an empty task workspace the user has never dismissed
    // the intro on. The Flutter bootstrap always ensures a default list, so
    // "empty workspace" here means "no tasks yet" (adapted from the reference's
    // lists-and-tasks-empty gate). Once dismissed, onboardingSeen keeps it away.
    //
    // It waits for the store to ANSWER (#260): "not loaded yet" is not "empty",
    // and a returning user with a first-launch pref would otherwise be shown a
    // modal welcome for the one frame before their tasks arrive.
    final tasksSnapshot = ref.watch(allTasksProvider);
    final allTasks = tasksSnapshot.asData?.value ?? const <StoredTask>[];
    final showOnboarding =
        tasksSnapshot.hasValue && allTasks.isEmpty && !prefs.onboardingSeen;
    // Persist the welcome as seen — from its button OR the back-ladder's top
    // rung (T8.3), so a back dismissal sticks exactly like a tap dismissal.
    void dismissOnboarding() =>
        ref.read(prefsControllerProvider.notifier).setOnboardingSeen(true);

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

    // The bottom bar carries the SMART VIEWS only. A list opened from the
    // drawer is not one of its destinations, so nothing is selected — the bar
    // never keeps the last smart view highlighted over a list (#236).
    final selectedIndex = SmartView.byId(sel.viewId)?.index;

    // The compact app-bar title — the plain view label (windowTitleFor carries
    // the dev prefix and " — axiotask" suffix, which the on-device app bar
    // should not repeat).
    final viewTitle = viewLabelFor(sel.viewId, listTitles: listTitles);

    // Closing the slide-in drawer after a navigation (drawer > selection) — a
    // no-op when expanded, where the compact Scaffold (and its key) is unmounted.
    final scaffoldKey = ref.watch(mobileScaffoldKeyProvider);
    void closeDrawer() => scaffoldKey.currentState?.closeDrawer();
    // …and the same drawer's open state, watched, so the back ladder below can
    // publish its claim on the gesture BEFORE the gesture happens (#263).
    final drawerOpen = ref.watch(drawerOpenProvider);

    // Panel prev/next: the siblings of the open task in the CURRENT view's
    // visible ordering (the same order the list renders). Null at a boundary,
    // and for anything not in the ordering (a subtask, or a filtered-out task).
    String? prevTaskId;
    String? nextTaskId;
    // The open task's own place in that ordering (#253): the direction the
    // detail's prev/next step travels along it. -1 for a task with no place —
    // a subtask, or one the current filter hides.
    var detailSlot = -1;
    if (sel.taskId != null) {
      final ordered = visibleTasksForView(
        allTasks: allTasks,
        viewId: sel.viewId,
        excludedLists: prefs.excludedLists.toSet(),
        showCompleted: prefs.showCompleted,
        sort: SortMode.byId(prefs.sortPerView[sel.viewId]),
        window: dateWindowNow(),
      );
      final i = ordered.indexWhere((t) => t.task.id == sel.taskId);
      detailSlot = i;
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
      onSelectView: (id) {
        closeDrawer(); // a view/list pick dismisses the drawer (drawer > select)
        _selectView(context, ref, id);
      },
      // List mutations route through the guarded seam: a store failure (or a
      // hung command) surfaces a redacted error toast instead of an unhandled
      // exception (#128/#135), and never leaves the sidebar in a half-state.
      onCreateList: (title, {localOnly = false}) => guardCommand(
        ref.read(toastControllerProvider),
        'create_list',
        () async {
          await ref
              .read(commandsProvider)
              .createList(title, localOnly: localOnly);
        },
      ),
      onRenameList: (id, title) => guardCommand(
        ref.read(toastControllerProvider),
        'rename_list',
        () => ref.read(commandsProvider).renameList(id, title),
      ),
      onDeleteList: (id) async {
        await guardCommand(
          ref.read(toastControllerProvider),
          'delete_list',
          () => ref.read(commandsProvider).deleteList(id),
        );
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
      onOpenProperties: () {
        closeDrawer(); // don't leave the drawer stacked over the dialog (#166)
        showProperties(context);
      },
      onToggleTheme: () {
        // Flip to the opposite explicit theme (a "system" pref resolves to its
        // effective brightness, then flips). Keeps the sun/moon meaningful.
        final next = _resolvedDark(context, prefs.theme) ? 'light' : 'dark';
        ref.read(prefsControllerProvider.notifier).setTheme(next);
      },
      isDark: _resolvedDark(context, prefs.theme),
      haptics: ref.watch(hapticsProvider),
    );

    // The system-back close of the detail is a go_router navigation via the
    // scaffold's PopScope — it never runs the panel's own flush-on-close, and
    // unmounting the panel disposes the focused field before a blur can persist
    // it. Run the panel's flush-AND-DISCARD funnel BEFORE navigating away, so a
    // mid-typing edit is saved AND an abandoned blank subtask is discarded on
    // system back exactly as on the panel's own Back button (#183/G4).
    void closeDetail() {
      ref.read(pendingEditsProvider).flushDetailClose();
      context.go(viewPath(sel.viewId));
    }

    final prefsCtl = ref.read(prefsControllerProvider.notifier);
    final scaffold = ListDetailScaffold(
      sidebar: sidebar,
      scaffoldKey: scaffoldKey,
      title: viewTitle,
      // What the detail's own motion needs from the router (#253): which task
      // is open (so a rect recorded by a row is only ever replayed under that
      // task) and where it sits in the view's ordering.
      detailTaskId: sel.taskId,
      detailSlot: detailSlot < 0 ? null : detailSlot,
      // The quiet sync line (#255) on the compact app bar's bottom edge. Its
      // own Consumer, so a sync starting or ending never rebuilds the shell.
      syncLine: const LiveSyncLine(),
      // Desktop divider drags (#210): the persisted widths seed the expanded
      // layout, and each drag end / double-click reset writes back through the
      // prefs controller (one write per gesture, not per frame).
      sidebarWidth:
          prefs.sidebarWidth ?? ListDetailScaffold.defaultSidebarWidth,
      detailFraction:
          prefs.detailFraction ?? ListDetailScaffold.defaultDetailFraction,
      onSidebarWidthChanged: prefsCtl.setSidebarWidth,
      onDetailFractionChanged: prefsCtl.setDetailFraction,
      onResetSidebarWidth: () =>
          prefsCtl.setSidebarWidth(ListDetailScaffold.defaultSidebarWidth),
      onResetDetailFraction: () =>
          prefsCtl.setDetailFraction(ListDetailScaffold.defaultDetailFraction),
      // ONE creation affordance per pointer class (#216): on touch the FAB is
      // it — it opens the list's bottom-sheet composer (never a silent
      // empty-task create, #166). On a fine pointer the always-visible
      // quick-add bar is it, and the FAB never renders — width does not decide
      // (a narrow desktop window keeps the bar, not the FAB).
      onNewTask: coarsePointerPlatform(Theme.of(context).platform)
          ? ref.read(newTaskRequestProvider.notifier).bump
          : null,
      // Every open and close of the compact drawer, plus the retraction when a
      // rotation unmounts it still open — the input to [drawerOpen] above.
      onDrawerChanged: ref.read(drawerOpenProvider.notifier).set,
      // …and while that composer is up there is NO FAB: the two are one surface
      // (#234), so the FAB can never render over the sheet it turned into.
      composerOpen: ref.watch(composerOpenProvider),
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
              onClose: closeDetail,
              onOpenTask: (id) => context.go(viewPath(sel.viewId, taskId: id)),
              onPrev: prevTaskId == null
                  ? null
                  : () => context.go(viewPath(sel.viewId, taskId: prevTaskId)),
              onNext: nextTaskId == null
                  ? null
                  : () => context.go(viewPath(sel.viewId, taskId: nextTaskId)),
            ),
      onCloseDetail: closeDetail,
    );

    // Overlay the welcome above the shell. Dismissal persists onboardingSeen,
    // which flips [showOnboarding] false and removes the overlay for good.
    final Widget shell = showOnboarding
        ? Stack(
            fit: StackFit.expand,
            children: [
              scaffold,
              Positioned.fill(
                child: OnboardingIntro(onDismiss: dismissOnboarding),
              ),
            ],
          )
        : scaffold;

    // The Android system-back precedence ladder (T8.3), layered OVER the detail
    // PopScope that [ListDetailScaffold] already owns. One system back resolves
    // the single highest-priority app-owned mode — one rung per press:
    //
    //   0. an open drawer            → close it
    //   1. the first-launch welcome  → dismiss it (persist onboardingSeen)
    //   2. an open detail            → close it   (owned by the scaffold below)
    //   3. an active selection       → clear it
    //   4. (nothing left)            → let the OS pop the app
    //
    // This PopScope owns rungs 0, 1 and 3 only; it deliberately leaves rung 2 to
    // the scaffold's own PopScope. Both PopScopes register on the same route, so
    // a blocked back fires BOTH callbacks — the `!detailOpen` guard below keeps
    // this one from ALSO clearing the selection on the back that closes a detail
    // (one back is exactly one rung).
    //
    // The open drawer is rung 0, above every other app-owned one. The framework
    // has its own handling for it — the drawer registers a LocalHistoryEntry —
    // but a route's PopScope entries preempt local history in
    // `ModalRoute.popDisposition`, so when a selection makes THIS PopScope
    // `canPop: false`, the framework's drawer-close never runs and this back
    // would clear the selection while leaving the drawer stacked over it
    // (F14/#192). So gate the whole ladder on the drawer: if it is open, close
    // it and stop (one back is one rung). Which rung to RUN is read from the
    // live [ScaffoldState] at pop time, never from a cached flag — the flag
    // could outlive the drawer (T8.2).
    //
    // The drawer must also make `canPop` false (#263). Android decides a
    // predictive back BEFORE the gesture, from the value the framework derives
    // from this route's PopScopes: told `canPop: true`, the OS runs the gesture
    // itself and FINISHES THE ACTIVITY — the app is gone with the drawer still
    // open and no callback below ever runs. Hence the watched [drawerOpen],
    // which the compact layout retracts when it unmounts so the claim can never
    // outlive the drawer either.
    final selectionActive = ref.watch(selectionBackHandleProvider);
    // An open inline-rename editor is an app-owned back rung too (G4 #183): a
    // system back mid-rename must commit-and-close the editor, not exit the app
    // (and a root-route back bubbles straight to the OS unless this PopScope
    // blocks it). It sits ABOVE the selection rung — a transient edit is
    // dismissed before a standing selection — but still below the detail (owned
    // by the scaffold's PopScope), so a back with a detail open closes the
    // detail and leaves any Offstage-list rename for the next back.
    final renameActive = ref.watch(renameBackHandleProvider);
    final detailOpen = sel.taskId != null;
    // The rect a row records on its way out (#253) is read one navigation later
    // by the compact detail; the scope spans both, above the scaffold that
    // holds the list and the detail alike.
    return DetailOriginScope(
      controller: ref.watch(detailOriginProvider),
      child: PopScope(
        canPop:
            !(drawerOpen || showOnboarding || selectionActive || renameActive),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          final scaffoldState = scaffoldKey.currentState;
          if (scaffoldState?.isDrawerOpen ?? false) {
            scaffoldState!.closeDrawer();
          } else if (showOnboarding) {
            dismissOnboarding();
          } else if (!detailOpen && renameActive) {
            ref.read(renameBackHandleProvider.notifier).commit();
          } else if (!detailOpen && selectionActive) {
            ref.read(selectionBackHandleProvider.notifier).clear();
          }
        },
        child: shell,
      ),
    );
  }

  /// Persist the newly selected view (survives restart, localStorage parity)
  /// and navigate to it.
  void _selectView(BuildContext context, WidgetRef ref, String viewId) {
    ref.read(prefsControllerProvider.notifier).setView(viewId);
    context.go(viewPath(viewId));
  }
}

/// The effective dark/light of a theme pref: explicit choices win; `system` (or
/// any unknown value) resolves against the platform brightness — so the sidebar
/// sun/moon always shows the CURRENT brightness and flips to its opposite.
bool _resolvedDark(BuildContext context, String themePref) =>
    switch (themePref) {
      'dark' => true,
      'light' => false,
      _ => MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };

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
    // The pane the router hands the shell is the ONE place a view change is
    // visible as a change of widget: go_router keeps the same page (and the
    // same nested Navigator) across views, so the switch is this keyed subtree
    // being replaced. [ViewSwitch] carries it across (#254) — a shared axis
    // along the bottom bar's ordering, a fade-through where there is none.
    return ComposerHost(
      // ABOVE the switch (#274): a view change mounts two panes for the length
      // of the transition, and the composer must stay ONE — one FAB listener,
      // one draft, one live list set — through it.
      viewId: viewId,
      selectedTaskId: selectedTaskId,
      onOpenTask: (id) => context.go(viewPath(viewId, taskId: id)),
      onOpenInView: (v, id) => context.go(viewPath(v, taskId: id)),
      child: ViewSwitch(
        slot: SmartView.byId(viewId)?.index,
        child: TaskListView(
          key: ValueKey('view-$viewId'),
          viewId: viewId,
          selectedTaskId: selectedTaskId,
          onOpenTask: (id) => context.go(viewPath(viewId, taskId: id)),
          onOpenTaskNotes: (id) =>
              context.go(viewPath(viewId, taskId: id, focusNotes: true)),
          // Search may land on a DIFFERENT view (a subtask's parent list —
          // #92), so it navigates by an explicit target view rather than the
          // current one.
          onOpenInView: (v, id) => context.go(viewPath(v, taskId: id)),
        ),
      ),
    );
  }
}
