import { invoke } from "@tauri-apps/api/core";

export const DEFAULT_INVOKE_TIMEOUT_MS = 12_000;

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

export async function invokeWithTimeout(name, args = {}, timeoutMs = DEFAULT_INVOKE_TIMEOUT_MS) {
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
