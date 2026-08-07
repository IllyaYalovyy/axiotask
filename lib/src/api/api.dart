// Google Tasks API layer — the Dart port of `api/mod.rs`.
//
// [TasksApi] is the only abstraction between the rest of the app and Google's
// API (per VISION). [HttpTasksApi] is the real implementation; the in-memory
// fake (T3.2/T3.3) is a fully-behaving test double kept in step with it, so the
// two never drift. [AuthedClient] is the auth seam the HTTP client layers
// refresh-on-401 on top of.

export 'api_error.dart';
export 'authed_client.dart';
export 'http_tasks_api.dart';
export 'tasks_api.dart';
