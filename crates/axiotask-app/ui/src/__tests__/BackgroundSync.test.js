import { render, screen, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import { mockInvoke, resetMocks, emitMockEvent } from "../test-setup.js";

// The backend emits a `sync-updated` event after every sync run (#4). The app
// must reflect background syncs — surface failures and refresh data — not just
// manual "Sync now" clicks.
describe("Background sync observability (sync-updated event)", () => {
  beforeEach(() => {
    resetMocks();
    invoke.mockClear();
    localStorage.clear();
    mockInvoke("auth_status", () => true);
    mockInvoke("list_tasklists", () => [{ id: "L1", title: "My Tasks" }]);
    mockInvoke("list_tasks", () => []);
    mockInvoke("sync_now", () => "ok");
  });

  it("surfaces a failed background sync as an error toast", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    emitMockEvent("sync-updated", { last_error: "network: timeout", last_synced: null });

    await waitFor(() =>
      expect(screen.getByText(/Sync failed: network: timeout/)).toBeInTheDocument(),
    );
  });

  it("does not repeat the toast for the same persistent error", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    const payload = { last_error: "network: timeout", last_synced: null };
    emitMockEvent("sync-updated", payload);
    await waitFor(() => expect(screen.getByText(/Sync failed/)).toBeInTheDocument());

    emitMockEvent("sync-updated", payload); // identical error again
    expect(screen.getAllByText(/Sync failed/)).toHaveLength(1);
  });

  it("explains a conflicted copy when a sync reports conflicts", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    emitMockEvent("sync-updated", { last_error: null, last_synced: "2026-07-04T10:00:00Z", last_conflicts: 1 });

    await waitFor(() =>
      expect(screen.getByText(/conflicted copy/)).toBeInTheDocument(),
    );
  });

  it("refreshes data when a background sync succeeds", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    const before = invoke.mock.calls.filter((c) => c[0] === "list_tasklists").length;
    emitMockEvent("sync-updated", { last_error: null, last_synced: "2026-07-04T10:00:00Z", last_pulled: 1 });

    await waitFor(() => {
      const after = invoke.mock.calls.filter((c) => c[0] === "list_tasklists").length;
      expect(after).toBeGreaterThan(before);
    });
  });
});
