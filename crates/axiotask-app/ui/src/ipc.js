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

export function friendlyError(name, e) {
  const msg = String(e?.message ?? e);
  if (msg.includes("not authenticated")) return "Not signed in - use Sign in with Google to sync.";
  if (msg.includes("session expired")) return "Google session expired - sign in again to resume sync.";
  if (e instanceof InvokeTimeoutError) return `${name} is taking too long. The app is still responsive; try again or restart if it keeps happening.`;
  return `Failed: ${name} - ${msg}`;
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
