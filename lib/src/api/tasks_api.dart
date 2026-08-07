// The sole abstraction layer between the app and Google's Tasks API — the Dart
// port of `api/traits.rs`'s `GoogleTasksClient`.
//
// The MVP needs exactly these ten operations; adding methods here is the
// canonical extension point. Two contracts on this surface are load-bearing
// and must survive every implementation:
//
//  - [patchTask] carries `If-Match` when [etag] is non-null and returns
//    [PreconditionFailed] on a stale-etag conflict; a `null` etag is an
//    unconditional patch.
//  - [listTasks] is paginated: pass the previous page's [Page.nextPageToken]
//    to continue, `null` to start.
//
// Two implementations stay in step: [HttpTasksApi] (real, reqwest-analog) and
// the in-memory fake (T3.2/T3.3), which mirrors verified Google semantics.

import '../model/page.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'api_error.dart';

/// Operations against Google Tasks v1. Every method throws an [ApiError]
/// subtype on failure.
abstract interface class TasksApi {
  /// List all task lists the authenticated user can see. Paginates to
  /// completion — the result is treated as the COMPLETE remote set.
  Future<List<TaskList>> listTasklists();

  /// Create a task list. Returns the server's view (id, etag, updated).
  Future<TaskList> insertTasklist(String title);

  /// Rename a task list. Returns the server's view after the change.
  Future<TaskList> patchTasklist(String id, String title);

  /// Delete a task list (and, server-side, its tasks).
  Future<void> deleteTasklist(String id);

  /// List one page of tasks in [listId]. Pass the previous page's
  /// `nextPageToken` as [pageToken] to continue; omit it to start.
  Future<Page<Task>> listTasks(String listId, {String? pageToken});

  /// Insert a task. Returns the server's view (etag, position filled in).
  Future<Task> insertTask(String listId, NewTask task);

  /// Fetch a single task's current server state. Throws [NotFound] if it no
  /// longer exists.
  Future<Task> getTask(String listId, String id);

  /// Sparse update by id. When [etag] is non-null the request is sent with
  /// `If-Match` and throws [PreconditionFailed] on conflict.
  Future<Task> patchTask(
    String listId,
    String id,
    TaskPatch patch, {
    String? etag,
  });

  /// Delete a task by id. Deliberately unconditional (no `If-Match`).
  Future<void> deleteTask(String listId, String id);

  /// Reparent / reorder a task. Either [parent] or [previous] may be null.
  /// Returns the server's view after the move.
  Future<Task> moveTask(
    String listId,
    String id, {
    String? parent,
    String? previous,
  });
}
