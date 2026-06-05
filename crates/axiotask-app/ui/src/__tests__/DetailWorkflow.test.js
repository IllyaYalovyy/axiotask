import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Work" }];

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 200;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `sub-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: "1", sync_state: "dirty", listId: args.listId, listTitle: "Work" };
        taskStore.push(t);
        return t;
      }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_notes": { const t = taskStore.find(x => x.id === args.id); if (t) t.notes = args.notes; return null; }
      case "set_due": return null;
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "move_to_list": return null;
      case "sync_now": return "ok";
      case "fresh_sync": { taskStore = []; return "fresh sync: pulled=0"; }
      case "auth_logout": return null;
      default: return null;
    }
  });
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: opts.notes || null, status: "needsAction", due: opts.due || null, position: opts.pos || "1", sync_state: "clean", listId: "L1", listTitle: "Work" };
}

describe("Detail Panel Workflows", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  describe("UT-14: Create subtask from detail panel", () => {
    it("clicking + in subtasks section calls create_task with parentId", async () => {
      mockBackend([task("t1", "Parent task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      // Open detail panel
      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      // Click + button in subtasks section
      const addBtn = container.querySelector(".add-subtask-btn");
      expect(addBtn).toBeInTheDocument();
      await fireEvent.click(addBtn);

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ parentId: "t1" }));
      });
    });
  });

  describe("UT-36: Auto-save on close", () => {
    it("closing panel with Escape saves edited title", async () => {
      mockBackend([task("t1", "Original title")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Original title")).toBeInTheDocument());

      // Open detail panel
      await fireEvent.click(screen.getByText("Original title"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      // Edit title
      const titleInput = screen.getByLabelText("Title");
      await fireEvent.input(titleInput, { target: { value: "New title" } });

      // Press Escape to close
      const panel = container.querySelector(".detail-panel");
      await fireEvent.keyDown(panel, { key: "Escape" });

      // Should have called rename_task
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("rename_task", { id: "t1", title: "New title" });
      });
    });
  });

  describe("UT-38: Reschedule to today (o key)", () => {
    it("pressing o on focused task calls set_due with Today", async () => {
      mockBackend([task("t1", "My task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("My task")).toBeInTheDocument());

      await fireEvent.keyDown(window, { key: "o" });

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Today" });
      });
    });
  });
});

describe("UT-04: Sign out", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("clicking Sign out calls auth_logout and shows Sign in button", async () => {
    mockBackend([task("t1", "Test")]);
    render(App);
    await waitFor(() => expect(screen.getByText("↻ Sync now")).toBeInTheDocument());

    // Click sign out
    await fireEvent.click(screen.getByText("Sign out"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("auth_logout", {});
    });
    // Should show sign-in button again
    await waitFor(() => expect(screen.getByText(/Sign in with Google/)).toBeInTheDocument());
  });
});

describe("UT-03: Fresh sync", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("clicking Fresh sync calls fresh_sync after confirmation", async () => {
    mockBackend([task("t1", "Local task")]);
    vi.spyOn(window, "confirm").mockReturnValue(true);
    render(App);
    await waitFor(() => expect(screen.getByText("Local task")).toBeInTheDocument());

    // Wait for sync to finish (button enabled)
    await waitFor(() => {
      const btn = screen.getByText("⟳ Fresh sync");
      expect(btn.disabled).toBe(false);
    });

    await fireEvent.click(screen.getByText("⟳ Fresh sync"));

    await waitFor(() => {
      const freshCalls = invoke.mock.calls.filter(c => c[0] === "fresh_sync");
      expect(freshCalls.length).toBe(1);
    });
    window.confirm.mockRestore();
  });

  it("does not call fresh_sync if user cancels confirmation", async () => {
    mockBackend([task("t1", "Local task")]);
    vi.spyOn(window, "confirm").mockReturnValue(false);
    render(App);
    await waitFor(() => expect(screen.getByText("Local task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("⟳ Fresh sync"));

    const freshCalls = invoke.mock.calls.filter(c => c[0] === "fresh_sync");
    expect(freshCalls).toHaveLength(0);
    window.confirm.mockRestore();
  });
});
