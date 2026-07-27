import { invoke } from "@tauri-apps/api/core";

export const DEFAULT_INVOKE_TIMEOUT_MS = 12_000;

// Commands that legitimately outlive the default watchdog. A uniform 12s
// budget breaks them: auth_login is paced by the USER completing the browser
// OAuth consent (minutes are normal — timing out mid-consent strands the UI
// signed-out with nothing to correct it later), and sync commands are
// network-bound with exponential rate-limit backoff.
export const INVOKE_TIMEOUT_OVERRIDES_MS = {
  auth_login: 10 * 60_000,
  sync_now: 5 * 60_000,
  fresh_sync: 5 * 60_000,
  import_backup: 60_000,
  export_backup: 60_000,
};

export function timeoutFor(name) {
  return INVOKE_TIMEOUT_OVERRIDES_MS[name] ?? DEFAULT_INVOKE_TIMEOUT_MS;
}

export class InvokeTimeoutError extends Error {
  constructor(name, timeoutMs) {
    super(`${name} timed out after ${Math.round(timeoutMs / 1000)}s`);
    this.name = "InvokeTimeoutError";
    this.command = name;
    this.timeoutMs = timeoutMs;
  }
}

// Fragments of the messages WE author to explain a refusal to the user — the
// only strings (besides the auth signals handled in friendlyError) allowed to
// reach a toast verbatim (#135). This is an ALLOWLIST, the inverse of the old
// marker denylist: the backend already sanitizes command errors before they
// cross IPC, and this last-line guard now DEFAULTS to redacting, so a future
// internal Display or raw reqwest/network text (which can embed the request
// URL) never reaches the user verbatim from any path. Each fragment is
// distinctive to an authored message, never a generic word a raw error could
// also contain.
const USER_AUTHORED_MARKERS = [
  "invalid due date", "unknown date move",
  "cannot nest under a subtask", "cannot make a task with subtasks",
  "not found in siblings", "no backup file found",
  "invalid backup file", "newer than this app supports",
];

function isUserAuthored(msg) {
  const m = msg.toLowerCase();
  if (USER_AUTHORED_MARKERS.some((marker) => m.includes(marker))) return true;
  // "task {id} not found" from the backend — pinned to that exact shape so a
  // network error that merely contains "not found" cannot slip through.
  return /^task .+ not found$/.test(m.trim());
}

// A human clause per command family, so a redacted error reads naturally for
// what the user was doing.
const FAMILY_ACTION = {
  list_tasklists: "update your lists", create_list: "update your lists",
  rename_list: "update your lists", delete_list: "update your lists",
  sync_now: "sync with Google", fresh_sync: "sync with Google",
  auth_login: "update your Google sign-in", auth_logout: "update your Google sign-in",
  get_settings: "update your settings", set_push_enabled: "update your settings",
  set_auto_sync: "update your settings", set_editing: "update your settings",
  export_backup: "export your backup", import_backup: "restore your backup",
};

function familyAction(name) {
  // Everything else is task-shaped (create/rename/complete/delete/move/…).
  return FAMILY_ACTION[name] ?? "save your change";
}

export function friendlyError(name, e) {
  const msg = String(e?.message ?? e);
  if (msg.includes("not authenticated")) return "Not signed in - use Sign in with Google to sync.";
  if (msg.includes("session expired")) return "Google session expired - sign in again to resume sync.";
  if (e instanceof InvokeTimeoutError) return `${name} is taking too long. The app is still responsive; try again or restart if it keeps happening.`;
  if (isUserAuthored(msg)) return msg;
  return `Couldn't ${familyAction(name)} — a local error occurred. The details are in the log.`;
}

export async function invokeWithTimeout(name, args = {}, timeoutMs = timeoutFor(name)) {
  let timer;
  try {
    return await Promise.race([
      invoke(name, args),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new InvokeTimeoutError(name, timeoutMs)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
