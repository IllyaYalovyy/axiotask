import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { emitMockEvent } from "../test-setup.js";
import App from "../App.svelte";

/**
 * GH#3 — Sync: pull all task lists and tasks from Google.
 * - On-demand via Sync Now button
 * - Status indicator shows syncing/synced/error states
 * - Pulled tasks appear in UI after sync
 */

function mockAuthenticatedBackend({ syncResult, syncDelay = 0, tasks = {} } = {}) {
  const lists = [
    { id: "L1", title: "Inbox" },
    { id: "L2", title: "Work" },
  ];

  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status":
        return true;
      case "list_tasklists":
        return lists;
      case "list_tasks":
        return tasks[args?.listId] || [];
      case "sync_now":
        if (syncDelay > 0) {
          await new Promise((r) => setTimeout(r, syncDelay));
        }
        if (syncResult === "error") throw new Error("network timeout");
        return syncResult || "pulled=3, pushed=0, conflicts=0, deleted=0";
      default:
        return null;
    }
  });
}

describe("GH#3: Sync Pull", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("shows Sync Now button when authenticated", async () => {
    mockAuthenticatedBackend();
    render(App);
    await waitFor(() => {
      expect(screen.getByText(/Sync now/)).toBeInTheDocument();
    });
  });

  it("shows Ready status when authenticated and not yet synced", async () => {
    mockAuthenticatedBackend();
    render(App);
    await waitFor(() => {
      expect(screen.getByText("Ready")).toBeInTheDocument();
    });
  });

  it("shows Syncing... state during sync", async () => {
    mockAuthenticatedBackend({ syncDelay: 100 });
    render(App);

    await waitFor(() => expect(screen.getByText(/Sync now/)).toBeInTheDocument());
    fireEvent.click(screen.getByText(/Sync now/));

    await waitFor(() => {
      expect(screen.getByText("Syncing...")).toBeInTheDocument();
    });
  });

  it("shows Synced timestamp after successful sync", async () => {
    mockAuthenticatedBackend();
    render(App);

    await waitFor(() => expect(screen.getByText(/Sync now/)).toBeInTheDocument());
    await fireEvent.click(screen.getByText(/Sync now/));

    await waitFor(() => {
      expect(screen.getByText(/Synced just now/)).toBeInTheDocument();
    });
  });

  it("shows Sync error on failure", async () => {
    mockAuthenticatedBackend({ syncResult: "error" });
    render(App);

    await waitFor(() => expect(screen.getByText(/Sync now/)).toBeInTheDocument());
    await fireEvent.click(screen.getByText(/Sync now/));

    await waitFor(() => {
      expect(screen.getByText("Sync error")).toBeInTheDocument();
    });
  });

  it("disables Sync Now button while syncing", async () => {
    mockAuthenticatedBackend({ syncDelay: 100 });
    render(App);

    await waitFor(() => expect(screen.getByText(/Sync now/)).toBeInTheDocument());
    fireEvent.click(screen.getByText(/Sync now/));

    await waitFor(() => {
      const btn = screen.getByText("Syncing...");
      expect(btn).toBeDisabled();
    });
  });

  it("reloads tasks after sync completes", async () => {
    let syncDone = false;
    const tasksAfterSync = [
      {
        id: "T1",
        parent_id: null,
        title: "Synced task",
        notes: null,
        status: "needsAction",
        due: "2026-06-05T00:00:00Z",
        position: "00000000000001",
        sync_state: "clean",
      },
    ];

    invoke.mockImplementation(async (cmd, args) => {
      switch (cmd) {
        case "auth_status":
          return true;
        case "list_tasklists":
          return [{ id: "L1", title: "Inbox" }];
        case "list_tasks":
          return syncDone ? tasksAfterSync : [];
        case "sync_now":
          syncDone = true;
          return "pulled=1, pushed=0, conflicts=0, deleted=0";
        default:
          return null;
      }
    });

    render(App);

    // Navigate to Inbox
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());
    await fireEvent.click(screen.getByText("Inbox"));

    syncDone = true;
    emitMockEvent("sync-updated", {
      last_synced: "2026-07-17T12:00:00Z",
      last_error: null,
      last_conflicts: 0,
      needs_reauth: false,
    });

    // Backend startup sync events reload tasks.
    await waitFor(() => {
      expect(screen.getByText("Synced task")).toBeInTheDocument();
    });
  });
});
