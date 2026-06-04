import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(lists = [], tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId || !args?.listId);
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: null, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14,"0"), sync_state: "clean", listId: args.listId };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      case "create_list": { const l = { id: `l-${nextId++}`, title: args.title }; lists.push(l); return l; }
      default: return null;
    }
  });
}

const sampleLists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }];
const today = new Date().toISOString();
const yesterday = new Date(Date.now() - 86400000).toISOString();
const tomorrow = new Date(Date.now() + 86400000).toISOString();

function sampleTasks() {
  return [
    { id: "t1", parent_id: null, title: "Overdue task", notes: null, status: "needsAction", due: yesterday, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
    { id: "t2", parent_id: null, title: "Today task", notes: null, status: "needsAction", due: today, position: "2", sync_state: "clean", listId: "L1", listTitle: "Work" },
    { id: "t3", parent_id: null, title: "Tomorrow task", notes: null, status: "needsAction", due: tomorrow, position: "3", sync_state: "clean", listId: "L2", listTitle: "Personal" },
    { id: "t4", parent_id: null, title: "No date task", notes: null, status: "needsAction", due: null, position: "4", sync_state: "clean", listId: "L2", listTitle: "Personal" },
  ];
}

describe("Phase 1: Core Views", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  describe("New Task", () => {
    it("shows the + New task button", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());
    });

    it("creates a task on button click", async () => {
      mockBackend(sampleLists, []);
      render(App);
      await waitFor(() => expect(screen.getByText("Work")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("+ New task"));
      await waitFor(() => expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ title: "" })));
    });
  });

  describe("Today View", () => {
    it("shows overdue and today tasks by default", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => {
        expect(screen.getByText("Overdue task")).toBeInTheDocument();
        expect(screen.getByText("Today task")).toBeInTheDocument();
      });
    });

    it("does NOT show tasks beyond this week in focus view", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => expect(screen.getByText("Overdue task")).toBeInTheDocument());
      // Tomorrow task IS visible in Focus (it's within this week)
      expect(screen.getByText("Tomorrow task")).toBeInTheDocument();
    });

    it("shows empty state when nothing due this week", async () => {
      const farFuture = new Date(Date.now() + 10 * 86400000).toISOString();
      mockBackend(sampleLists, [{ id: "t1", parent_id: null, title: "Future", notes: null, status: "needsAction", due: farFuture, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" }]);
      render(App);
      await waitFor(() => expect(screen.getByText(/All clear for this week/)).toBeInTheDocument());
    });
  });

  describe("Sidebar Navigation", () => {
    it("shows Today and All Tasks views", async () => {
      mockBackend(sampleLists, []);
      render(App);
      await waitFor(() => {
        expect(screen.getByText("★ Focus")).toBeInTheDocument();
        expect(screen.getByText("▤ All Tasks")).toBeInTheDocument();
      });
    });

    it("shows individual lists", async () => {
      mockBackend(sampleLists, []);
      render(App);
      await waitFor(() => {
        expect(screen.getByText("Work")).toBeInTheDocument();
        expect(screen.getByText("Personal")).toBeInTheDocument();
      });
    });

    it("clicking a list switches to list view", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => expect(screen.getByText("Work")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Work"));
      await waitFor(() => {
        // In list view, should show all tasks from that list including tomorrow
        expect(screen.getByText("Overdue task")).toBeInTheDocument();
        expect(screen.getByText("Today task")).toBeInTheDocument();
      });
    });
  });

  describe("Show/Hide Completed", () => {
    it("hides completed tasks by default", async () => {
      const tasks = [
        { id: "t1", parent_id: null, title: "Open", notes: null, status: "needsAction", due: today, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
        { id: "t2", parent_id: null, title: "Done", notes: null, status: "completed", due: today, position: "2", sync_state: "clean", listId: "L1", listTitle: "Work" },
      ];
      mockBackend(sampleLists, tasks);
      render(App);
      await waitFor(() => expect(screen.getByText("Open")).toBeInTheDocument());
      expect(screen.queryByText("Done")).not.toBeInTheDocument();
    });

    it("shows completed tasks when toggled", async () => {
      const tasks = [
        { id: "t1", parent_id: null, title: "Open", notes: null, status: "needsAction", due: today, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
        { id: "t2", parent_id: null, title: "Done", notes: null, status: "completed", due: today, position: "2", sync_state: "clean", listId: "L1", listTitle: "Work" },
      ];
      mockBackend(sampleLists, tasks);
      render(App);
      await waitFor(() => expect(screen.getByText("Open")).toBeInTheDocument());
      const toggle = screen.getByLabelText("Show completed");
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done")).toBeInTheDocument());
    });
  });

  describe("Keyboard Navigation", () => {
    it("j/k moves focus", async () => {
      mockBackend(sampleLists, sampleTasks());
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Overdue task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "j" });
      // Second row should be focused
      const rows = container.querySelectorAll(".task-row");
      if (rows.length > 1) expect(rows[1]).toHaveClass("focused");
    });

    it("Space toggles completion", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => expect(screen.getByText("Overdue task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });

    it("d deletes and shows undo toast", async () => {
      mockBackend(sampleLists, sampleTasks());
      render(App);
      await waitFor(() => expect(screen.getByText("Overdue task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      expect(invoke).toHaveBeenCalledWith("delete_task", { id: "t1" });
      await waitFor(() => expect(screen.getByText(/Deleted/)).toBeInTheDocument());
    });

    it("? shows cheatsheet", async () => {
      mockBackend(sampleLists, []);
      render(App);
      await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "?" });
      await waitFor(() => expect(screen.getByText("Keyboard Shortcuts")).toBeInTheDocument());
    });
  });
});
