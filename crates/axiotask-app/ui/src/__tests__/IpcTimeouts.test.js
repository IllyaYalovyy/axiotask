import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import {
  invokeWithTimeout,
  timeoutFor,
  DEFAULT_INVOKE_TIMEOUT_MS,
  InvokeTimeoutError,
} from "../ipc.js";
import { mockInvoke, resetMocks } from "../test-setup.js";

// The invoke watchdog must be per-command. A uniform 12s budget breaks
// commands that are legitimately slow: auth_login is paced by the user
// completing the browser OAuth consent (minutes), and sync commands carry
// network retries with exponential backoff. Timing auth_login out mid-consent
// strands the UI signed-out with nothing to correct it afterwards.
describe("per-command invoke timeouts", () => {
  beforeEach(() => {
    resetMocks();
    invoke.mockClear();
    vi.useFakeTimers();
  });
  afterEach(() => vi.useRealTimers());

  const never = () => new Promise(() => {});

  it("gives auth_login minutes, not the 12s default", async () => {
    expect(timeoutFor("auth_login")).toBeGreaterThanOrEqual(5 * 60_000);
    mockInvoke("auth_login", never);
    let settled = null;
    invokeWithTimeout("auth_login").then(() => (settled = "ok"), (e) => (settled = e));
    await vi.advanceTimersByTimeAsync(DEFAULT_INVOKE_TIMEOUT_MS + 1000);
    // Still waiting at the point the old uniform timeout would have fired.
    expect(settled).toBeNull();
    await vi.advanceTimersByTimeAsync(timeoutFor("auth_login"));
    expect(settled).toBeInstanceOf(InvokeTimeoutError);
  });

  it("sync commands get a long network budget", () => {
    expect(timeoutFor("sync_now")).toBeGreaterThanOrEqual(60_000);
    expect(timeoutFor("fresh_sync")).toBeGreaterThanOrEqual(60_000);
  });

  it("ordinary commands still fail fast at the default", async () => {
    expect(timeoutFor("rename_task")).toBe(DEFAULT_INVOKE_TIMEOUT_MS);
    mockInvoke("rename_task", never);
    let settled = null;
    invokeWithTimeout("rename_task").then(() => (settled = "ok"), (e) => (settled = e));
    await vi.advanceTimersByTimeAsync(DEFAULT_INVOKE_TIMEOUT_MS + 1000);
    expect(settled).toBeInstanceOf(InvokeTimeoutError);
  });
});
