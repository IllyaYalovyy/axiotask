// Composition of the authenticated Google Tasks client — the Dart port of
// `state.rs`'s `build_http_client` (desktop) and `build_provider_client`
// (Android). Each assembles an [HttpTasksApi] over a [ProductionAuthedClient]
// so the 401→refresh-once→retry seam is live in production.
//
// These are the seam F5's composition root mounts: on (re)login it builds a
// fresh client for the new session and hands it to the scheduler through its
// `TasksApi Function()` getter, so a re-login swaps the client without
// reconstructing the scheduler.

import 'package:http/http.dart' as http;

import '../api/http_tasks_api.dart';
import '../api/tasks_api.dart';
import '../auth/auth_error.dart';
import '../auth/desktop_auth.dart';
import '../auth/production_authed_client.dart';
import '../auth/token_provider.dart';
import '../auth/token_store.dart';

/// Build the desktop Tasks client for a live session. The refresh token in
/// [tokens] is exchanged for fresh access tokens at the token endpoint (through
/// googleapis_auth), and any refresh is persisted back to [store]. [apiClient]
/// carries the Tasks requests; [refreshClient] talks to the token endpoint —
/// both default to a fresh [http.Client] and are injected in tests.
TasksApi buildDesktopTasksApi({
  required StoredTokens tokens,
  required OAuthConfig config,
  required TokenStore store,
  http.Client? apiClient,
  http.Client? refreshClient,
}) {
  final client = ProductionAuthedClient(
    transport: apiClient ?? http.Client(),
    initialTokens: tokens,
    store: store,
    refresh: desktopRefreshFn(
      config: config,
      refreshClient: refreshClient ?? http.Client(),
    ),
  );
  return HttpTasksApi(client);
}

/// Rebuild the desktop Tasks client from the persisted session, reading the
/// full bundle safely rather than force-unwrapping a fresh disk read.
///
/// The desktop client needs the whole [StoredTokens] bundle (the refresh token
/// drives the 401→refresh seam), which the bare access token the composition
/// root carries does not hold — so the bundle is read back from [store]. But a
/// tokens.json that was DELETED or CORRUPTED between session establishment and
/// this rebuild is not a crash: it returns null, and the composition root
/// treats a null client as a dead session (needs-reauth) rather than letting a
/// `TypeError` (missing file) or a [TokenStoreException] (malformed file) kill
/// the detached startup task or strand a signed-in-without-client state (G2 /
/// #203).
TasksApi? buildDesktopTasksApiFromStore({
  required TokenStore store,
  required OAuthConfig config,
  http.Client? apiClient,
  http.Client? refreshClient,
}) {
  final StoredTokens? tokens;
  try {
    tokens = store.load();
  } on TokenStoreException {
    return null;
  }
  if (tokens == null) return null;
  return buildDesktopTasksApi(
    tokens: tokens,
    config: config,
    store: store,
    apiClient: apiClient,
    refreshClient: refreshClient,
  );
}

/// Build the Android Tasks client for a live session. Play Services owns the
/// grant, so there is no refresh token and nothing is persisted: a 401 triggers
/// a silent re-authorize through [provider]. [accessToken] is the token the
/// interactive sign-in just produced; [apiClient] carries the Tasks requests.
TasksApi buildAndroidTasksApi({
  required String accessToken,
  required TokenProvider provider,
  http.Client? apiClient,
}) {
  final client = ProductionAuthedClient.android(
    transport: apiClient ?? http.Client(),
    accessToken: accessToken,
    provider: provider,
  );
  return HttpTasksApi(client);
}
