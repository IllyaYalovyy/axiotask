import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

/**
 * GH#26 — Offline-first: app works fully without Google account.
 * - All CRUD operations work locally
 * - Sign-in is optional
 * - Sync never called when not authenticated
 */

const lists = [{ id: "L1", title: "My Tasks" }];

function mockOfflineBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  let syncCalled = false;

  const mock = invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return false; // NOT authenticated
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = {
          id: `t-${nextId++}`, parent_id: args.parentId || null,
          title: args.title, notes: null, status: "needsAction",
          due: null, position: String(nextId).padStart(14, "0"),
          sync_state: "dirty", listId: args.listId, listTitle: "My Tasks",
        };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": { syncCalled = true; return null; }
      case "create_list": return { id: `l-${nextId++}`, title: args.title };
      default: return null;
    }
  });

  return { wasSyncCalled: () => syncCalled };
}

describe("GH#26: Offline-First", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("shows sign-in button when not authenticated", async () => {
    mockOfflineBackend();
    render(App);
    await waitFor(() => {
      expect(screen.getByText("Sign in with Google")).toBeInTheDocument();
    });
  });

  it("does not show sync button when not authenticated", async () => {
    mockOfflineBackend();
    render(App);
    await waitFor(() => {
      expect(screen.getByText("Sign in with Google")).toBeInTheDocument();
    });
    expect(screen.queryByText(/Sync now/)).not.toBeInTheDocument();
  });

  it("shows Offline status when not authenticated", async () => {
    mockOfflineBackend();
    render(App);
    await waitFor(() => {
      expect(screen.getByText("Offline")).toBeInTheDocument();
    });
  });

  it("can create tasks without authentication", async () => {
    mockOfflineBackend();
    render(App);

    // Navigate to My Tasks list
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());
    await fireEvent.click(screen.getByText("My Tasks"));

    // Create a task via + New task button
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());
    await fireEvent.click(screen.getByText("+ New task"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ title: "" }));
    });
  });

  it("never calls sync_now when not authenticated", async () => {
    const { wasSyncCalled } = mockOfflineBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Sign in with Google")).toBeInTheDocument());

    // Wait for lists to load, then navigate to My Tasks list
    await waitFor(() => expect(screen.getByRole("button", { name: /My Tasks/ })).toBeInTheDocument());
    await fireEvent.click(screen.getByRole("button", { name: /My Tasks/ }));

    // Perform create operation via button
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());
    await fireEvent.click(screen.getByText("+ New task"));

    // Wait for create_task to be called
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ title: "" })));

    // sync_now should never have been called
    expect(wasSyncCalled()).toBe(false);
  });

  it("displays tasks from local store without authentication", async () => {
    const existingTasks = [
      { id: "t1", parent_id: null, title: "Existing offline task", notes: null, status: "needsAction", due: null, position: "00000000000001", sync_state: "dirty", listId: "L1", listTitle: "My Tasks" },
    ];
    mockOfflineBackend(existingTasks);
    render(App);

    // Navigate to list view
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());
    await fireEvent.click(screen.getByText("My Tasks"));

    await waitFor(() => {
      expect(screen.getByText("Existing offline task")).toBeInTheDocument();
    });
  });
});
