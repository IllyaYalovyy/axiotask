import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(initialTasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...initialTasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "delete_task": {
        const t = taskStore.find(x => x.id === args.id);
        const token = t ? {
          id: t.id, list_id: t.listId, parent_id: t.parent_id,
          title: t.title, notes: t.notes, status: t.status,
          due: t.due, position: t.position, had_etag: true,
        } : null;
        taskStore = taskStore.filter(x => x.id !== args.id);
        return token;
      }
      case "undo_delete": {
        const t = {
          id: args.token.id, parent_id: args.token.parent_id,
          title: args.token.title, notes: args.token.notes,
          status: args.token.status, due: args.token.due,
          position: args.token.position, sync_state: "dirty",
          listId: args.token.list_id, listTitle: "Work",
        };
        taskStore.push(t);
        return null;
      }
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId, listTitle: "Work" };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { taskStore };
}

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due || new Date().toISOString(),
    position: opts.pos || "00001", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

describe("GH#12: Delete task with undo", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("Delete via keyboard (d key)", () => {
    it("pressing d on focused task calls delete_task", async () => {
      mockBackend([task("t1", "Delete me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Delete me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      expect(invoke).toHaveBeenCalledWith("delete_task", { id: "t1" });
    });

    it("task disappears from list after pressing d", async () => {
      mockBackend([task("t1", "Gone task"), task("t2", "Remaining")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Gone task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.queryByText("Gone task")).not.toBeInTheDocument());
      expect(screen.getByText("Remaining")).toBeInTheDocument();
    });
  });

  describe("Delete via context menu", () => {
    it("context menu has Delete option", async () => {
      mockBackend([task("t1", "Context task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Context task")).toBeInTheDocument());
      const widget = container.querySelector(".task-widget");
      await fireEvent.contextMenu(widget);
      await waitFor(() => expect(screen.getByText("Delete")).toBeInTheDocument());
    });

    it("clicking Delete in context menu removes the task", async () => {
      mockBackend([task("t1", "Ctx delete")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Ctx delete")).toBeInTheDocument());
      const widget = container.querySelector(".task-widget");
      await fireEvent.contextMenu(widget);
      await waitFor(() => expect(screen.getByText("Delete")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Delete"));
      await waitFor(() => expect(screen.queryByText("Ctx delete")).not.toBeInTheDocument());
    });
  });

  describe("Undo toast (30s)", () => {
    it("shows undo toast after deleting a task", async () => {
      mockBackend([task("t1", "Undo me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Undo me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.getByText(/Deleted "Undo me"/)).toBeInTheDocument());
      expect(screen.getByText("Undo")).toBeInTheDocument();
    });

    it("undo toast disappears after 30 seconds", async () => {
      mockBackend([task("t1", "Timeout task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Timeout task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.getByText(/Deleted "Timeout task"/)).toBeInTheDocument());
      vi.advanceTimersByTime(30001);
      await waitFor(() => expect(screen.queryByText(/Deleted "Timeout task"/)).not.toBeInTheDocument());
    });

    it("clicking Undo calls undo_delete with the token", async () => {
      mockBackend([task("t1", "Restore me", { notes: "my notes", due: "2026-06-01T00:00:00Z" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Restore me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.getByText("Undo")).toBeInTheDocument());
      invoke.mockClear();
      // Re-mock so undo_delete works
      invoke.mockImplementation(async (cmd, args) => {
        if (cmd === "undo_delete") return null;
        if (cmd === "auth_status") return true;
        if (cmd === "list_tasklists") return [{ id: "L1", title: "Work" }];
        if (cmd === "list_tasks") return [task("t1", "Restore me", { notes: "my notes", due: "2026-06-01T00:00:00Z" })];
        if (cmd === "sync_now") return "ok";
        return null;
      });
      await fireEvent.click(screen.getByText("Undo"));
      expect(invoke).toHaveBeenCalledWith("undo_delete", expect.objectContaining({
        token: expect.objectContaining({
          id: "t1",
          title: "Restore me",
          notes: "my notes",
          due: "2026-06-01T00:00:00Z",
        }),
      }));
    });

    it("task reappears after clicking Undo", async () => {
      mockBackend([task("t1", "Reappear")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Reappear")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.queryByText("Reappear")).not.toBeInTheDocument());
      await fireEvent.click(screen.getByText("Undo"));
      await waitFor(() => expect(screen.getByText("Reappear")).toBeInTheDocument());
    });

    it("dismiss button removes undo toast immediately", async () => {
      mockBackend([task("t1", "Dismiss me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Dismiss me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      await waitFor(() => expect(screen.getByText(/Deleted "Dismiss me"/)).toBeInTheDocument());
      await fireEvent.click(screen.getByText("✕"));
      await waitFor(() => expect(screen.queryByText(/Deleted "Dismiss me"/)).not.toBeInTheDocument());
    });
  });
});
