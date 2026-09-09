// go_router wiring — one ShellRoute keeping the adaptive shell mounted while the
// URL selects the view and (optionally) a task detail (RFC-011 §7).
//
// Route shape:
//   /view/:viewId                    → a view's list (the ShellRoute child)
//   /view/:viewId?task=<id>          → same view, with a task selected
//   /view/:viewId?task=<id>&from=<p> → …opened FROM another task's panel (#310)
//
// The `from` parameter is the panel the detail was opened from — a subtask
// opened out of its parent's checklist records the parent, so Back re-opens it
// instead of dropping to the list. It lives in the URL for the same reason the
// selection does: a restored route has to walk the same way back (#310).
//
// The view id lives in the PATH (it changes the list content — the swappable
// ShellRoute child); the selected task lives in a QUERY parameter (it only
// toggles the detail pane, the list stays put). Both are derived from the URL by
// [parseShellLocation], a pure function unit-tested without pumping a router.
//
// Any redirect policy is likewise a pure function ([initialRedirect]) adapted
// into GoRouter.redirect, per the research note.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import 'views.dart';

/// The parsed shell selection: which view, and which task (if any).
class ShellLocation {
  const ShellLocation({
    required this.viewId,
    this.taskId,
    this.fromTaskId,
    this.focusNotes = false,
  });

  /// The active view id (smart-view id or list id).
  final String viewId;

  /// The selected task id, or `null` when the detail pane is closed.
  final String? taskId;

  /// The task whose panel this one was opened from (`from=<id>`), or `null` for
  /// an open with no origin — a list row, a search jump, a restored URL that
  /// names none. Back returns to it before it closes to the list (#310).
  final String? fromTaskId;

  /// Whether the detail pane should open with its Notes field focused (the
  /// context menu's "Edit notes"); carried in the `focus=notes` query param.
  final bool focusNotes;
}

/// Parse a shell [uri] into its [ShellLocation]. Falls back to the "all" view
/// for any URL that does not name one, so a malformed location never crashes the
/// shell. An empty `?task=` counts as no selection.
ShellLocation parseShellLocation(Uri uri) {
  final segs = uri.pathSegments;
  final viewId = (segs.length >= 2 && segs[0] == 'view')
      ? segs[1]
      : SmartView.all.id;
  final task = uri.queryParameters['task'];
  final from = uri.queryParameters['from'];
  return ShellLocation(
    viewId: viewId,
    taskId: (task != null && task.isNotEmpty) ? task : null,
    fromTaskId: (from != null && from.isNotEmpty) ? from : null,
    focusNotes: uri.queryParameters['focus'] == 'notes',
  );
}

/// The path for a view, with an optional selected task, the panel that task was
/// opened from ([fromTaskId], #310), and a Notes-focus request. With no selected
/// task there is no panel to come back from, so an origin is dropped.
String viewPath(
  String viewId, {
  String? taskId,
  String? fromTaskId,
  bool focusNotes = false,
}) {
  if (taskId == null) return '/view/$viewId';
  final from = fromTaskId == null ? '' : '&from=$fromTaskId';
  final notes = focusNotes ? '&focus=notes' : '';
  return '/view/$viewId?task=$taskId$from$notes';
}

/// Redirect the bare root to the given [defaultViewId]; leave every other
/// location untouched. Pure — unit-tested directly.
String? initialRedirect(String location, {required String defaultViewId}) {
  if (location == '/') return '/view/$defaultViewId';
  return null;
}

/// Build the app router. [initialViewId] is the view restored from prefs at
/// launch; [navigatorKey] is exposed for tests that need to drive navigation.
GoRouter buildAppRouter({
  String initialViewId = 'all',
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: viewPath(initialViewId),
    redirect: (context, state) =>
        initialRedirect(state.uri.toString(), defaultViewId: initialViewId),
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri, child: child),
        routes: [
          GoRoute(
            path: '/view/:viewId',
            builder: (context, state) {
              final task = state.uri.queryParameters['task'];
              return ViewListPane(
                viewId: state.pathParameters['viewId'] ?? SmartView.all.id,
                selectedTaskId: (task != null && task.isNotEmpty) ? task : null,
              );
            },
          ),
        ],
      ),
    ],
  );
}
