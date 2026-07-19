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

  it("refreshes data when a background sync succeeds without scoped list data", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    const before = invoke.mock.calls.filter((c) => c[0] === "list_tasklists").length;
    emitMockEvent("sync-updated", { last_error: null, last_synced: "2026-07-04T10:00:00Z", last_pulled: 1 });

    await waitFor(() => {
      const after = invoke.mock.calls.filter((c) => c[0] === "list_tasklists").length;
      expect(after).toBeGreaterThan(before);
    });
  });

  it("refreshes only changed task lists when sync reports affected lists", async () => {
    localStorage.setItem("axiotask:view", "L1");
    let tasks = {
      L1: [{ id: "a", parent_id: null, title: "Alpha", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean" }],
      L2: [{ id: "b", parent_id: null, title: "Bravo", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean" }],
      L3: [{ id: "c", parent_id: null, title: "Charlie", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean" }],
    };
    mockInvoke("list_tasklists", () => [
      { id: "L1", title: "One" },
      { id: "L2", title: "Two" },
      { id: "L3", title: "Three" },
    ]);
    mockInvoke("list_tasks", ({ listId }) => tasks[listId] ?? []);

    render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    const countFor = (id) =>
      invoke.mock.calls.filter((c) => c[0] === "list_tasks" && c[1]?.listId === id).length;
    const before = { L1: countFor("L1"), L2: countFor("L2"), L3: countFor("L3") };
    const listLoadsBefore = invoke.mock.calls.filter((c) => c[0] === "list_tasklists").length;

    tasks = { ...tasks, L2: [{ ...tasks.L2[0], title: "Bravo pulled" }] };
    emitMockEvent("sync-updated", {
      last_error: null,
      last_synced: "2026-07-04T10:00:00Z",
      last_pulled: 1,
      changed_list_ids: ["L2"],
      lists_changed: false,
    });

    await waitFor(() => expect(countFor("L2")).toBeGreaterThan(before.L2));
    expect(countFor("L1")).toBe(before.L1);
    expect(countFor("L2")).toBe(before.L2 + 1);
    expect(countFor("L3")).toBe(before.L3);
    expect(invoke.mock.calls.filter((c) => c[0] === "list_tasklists")).toHaveLength(listLoadsBefore);
  });
});
