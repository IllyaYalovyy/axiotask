import { render, screen, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { emitMockEvent } from "../test-setup.js";
import App from "../App.svelte";

/**
 * GH#33 / GH#62 — Backend-owned auto-sync on startup when authenticated.
 * - Frontend does not invoke sync_now during initial render
 * - Backend startup sync events update status and refresh data
 * - Failure events show toast but app remains usable
 * - No auto-sync when not authenticated
 */

function mockBackend({ authenticated = true, syncDelay = 50, syncFail = false, tasks = [] } = {}) {
  const lists = [{ id: "L1", title: "Inbox" }];

  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status":
        return authenticated;
      case "list_tasklists":
        return lists;
      case "list_tasks":
        return tasks;
      case "sync_now":
        if (syncDelay > 0) await new Promise((r) => setTimeout(r, syncDelay));
        if (syncFail) throw new Error("network error");
        return "pulled=2, pushed=0, conflicts=0, deleted=0";
      default:
        return null;
    }
  });
}

describe("GH#33/GH#62: Backend-owned auto-sync on startup", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("does not call sync_now on launch when authenticated", async () => {
    mockBackend({ syncDelay: 150 });
    render(App);

    await waitFor(() => {
      expect(screen.getByText("Ready")).toBeInTheDocument();
    });

    const syncCalls = invoke.mock.calls.filter(([cmd]) => cmd === "sync_now");
    expect(syncCalls).toHaveLength(0);
  });

  it("shows synced state after backend startup sync event", async () => {
    mockBackend();
    render(App);

    await waitFor(() => expect(screen.getByText("Ready")).toBeInTheDocument());
    emitMockEvent("sync-updated", {
      last_synced: "2026-07-17T12:00:00Z",
      last_error: null,
      last_conflicts: 0,
      needs_reauth: false,
    });

    await waitFor(() => {
      expect(screen.getByText(/Synced/)).toBeInTheDocument();
    });
  });

  it("does not auto-sync when not authenticated", async () => {
    mockBackend({ authenticated: false });
    render(App);

    await waitFor(() => {
      expect(screen.getByText("Offline")).toBeInTheDocument();
    });

    // sync_now should not have been called
    const syncCalls = invoke.mock.calls.filter(([cmd]) => cmd === "sync_now");
    expect(syncCalls).toHaveLength(0);
  });

  it("shows toast on backend startup sync failure but app remains usable", async () => {
    mockBackend();
    render(App);

    await waitFor(() => expect(screen.getByText("Ready")).toBeInTheDocument());
    emitMockEvent("sync-updated", {
      last_synced: null,
      last_error: "network error",
      last_conflicts: 0,
      needs_reauth: false,
    });

    await waitFor(() => {
      expect(screen.getByText(/Sync failed: network error/)).toBeInTheDocument();
    });

    // App is still usable — lists are loaded and visible
    expect(screen.getByText("Inbox")).toBeInTheDocument();
  });

  it("app loads cached data immediately without waiting for sync", async () => {
    const tasks = [
      { id: "T1", parent_id: null, title: "Cached task", notes: null, status: "needsAction", due: null, position: "00000000000001", sync_state: "clean" },
    ];
    mockBackend({ syncDelay: 500, tasks });
    render(App);

    // Navigate to Inbox
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());
    const { fireEvent } = await import("@testing-library/svelte");
    await fireEvent.click(screen.getByText("Inbox"));

    // Cached task visible while sync is still running
    await waitFor(() => {
      expect(screen.getByText("Cached task")).toBeInTheDocument();
    });
    const syncCalls = invoke.mock.calls.filter(([cmd]) => cmd === "sync_now");
    expect(syncCalls).toHaveLength(0);
  });
});
