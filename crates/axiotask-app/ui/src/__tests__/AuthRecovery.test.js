import { render, screen, waitFor, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import { mockInvoke, resetMocks, emitMockEvent } from "../test-setup.js";

// Auth failure and recovery in the MAIN window. A dead session (expired /
// revoked refresh token) or a signed-out backend must always surface a
// working re-auth action — never a Sync button that can only fail, and never
// a blanked task list.
describe("Auth recovery UX", () => {
  beforeEach(() => {
    resetMocks();
    invoke.mockClear();
    localStorage.clear();
    mockInvoke("list_tasklists", () => [{ id: "L1", title: "My Tasks" }]);
    // Overdue task → visible in the default Focus view.
    mockInvoke("list_tasks", () => [
      {
        id: "T1", parent_id: null, title: "local task", notes: null,
        status: "needsAction", due: "2026-01-01T00:00:00.000Z", position: "1", sync_state: "clean",
      },
    ]);
  });

  it("dead session: sidebar swaps Sync now for a Sign in again action", async () => {
    mockInvoke("auth_status", () => true);
    render(App);
    await waitFor(() => expect(screen.getByText("local task")).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText(/↻ Sync now/)).toBeInTheDocument());

    // Background sync reports the session is dead (invalid_grant).
    emitMockEvent("sync-updated", {
      last_error: "Google session expired — sign in again to resume sync",
      needs_reauth: true,
    });

    await waitFor(() => expect(screen.getByText(/Sign in again/)).toBeInTheDocument());
    expect(screen.queryByText(/↻ Sync now/)).not.toBeInTheDocument();
    expect(screen.getByText("Session expired")).toBeInTheDocument();

    // The action actually starts the OAuth flow.
    await fireEvent.click(screen.getByText(/Sign in again/));
    await waitFor(() =>
      expect(invoke.mock.calls.some((c) => c[0] === "auth_login")).toBe(true),
    );
  });

  it("#45: a successful login flips the UI to signed-in without a restart", async () => {
    // auth_login resolving `null` is the worst case (Tauri returns null for a
    // unit Ok) — the UI must not read the outcome from that value, it must
    // re-ask auth_status.
    let signedIn = false;
    mockInvoke("auth_status", () => signedIn);
    mockInvoke("auth_login", () => { signedIn = true; return null; });

    render(App);
    await waitFor(() => expect(screen.getByText(/Sign in with Google/)).toBeInTheDocument());

    await fireEvent.click(screen.getByText(/Sign in with Google/));

    await waitFor(() => expect(screen.getByText(/↻ Sync now/)).toBeInTheDocument());
    expect(screen.queryByText(/Sign in with Google/)).not.toBeInTheDocument();
  });

  it("a failed manual sync never hides the task list", async () => {
    mockInvoke("auth_status", () => true);
    mockInvoke("sync_now", () => { throw "not authenticated"; });

    render(App);
    await waitFor(() => expect(screen.getByText("local task")).toBeInTheDocument());

    // The startup auto-sync already hits the failure; exercise the manual
    // button as well once it settles.
    const syncBtn = await screen.findByText(/↻ Sync now/);
    await fireEvent.click(syncBtn);

    // Friendly toast, and the local data stays on screen.
    await waitFor(() => expect(screen.getByText(/Not signed in/)).toBeInTheDocument());
    expect(screen.getByText("local task")).toBeInTheDocument();
    expect(screen.queryByText("Sync failed")).not.toBeInTheDocument();
  });

  it("recovered session: sync-updated clears the re-auth state", async () => {
    mockInvoke("auth_status", () => true);
    render(App);
    await waitFor(() => expect(screen.getByText("local task")).toBeInTheDocument());

    emitMockEvent("sync-updated", { last_error: "Google session expired — sign in again to resume sync", needs_reauth: true });
    await waitFor(() => expect(screen.getByText(/Sign in again/)).toBeInTheDocument());

    emitMockEvent("sync-updated", { last_error: null, last_synced: "2026-07-17T10:00:00Z", needs_reauth: false });
    await waitFor(() => expect(screen.getByText(/↻ Sync now/)).toBeInTheDocument());
    expect(screen.queryByText(/Sign in again/)).not.toBeInTheDocument();
  });
});
