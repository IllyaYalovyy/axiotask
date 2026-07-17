import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const today = new Date().toISOString();

function mockBackend(tasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId || null, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId, listTitle: "Work" };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.parent_id = args.parentId; return null; }
      case "reorder_task": return null;
      case "sync_now": return "ok";
      case "create_list": return { id: "L2", title: args.title };
      case "move_to_list": return null;
      default: return null;
    }
  });
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: opts.notes || null, status: opts.status || "needsAction", due: opts.due || today, position: opts.pos || id, sync_state: "clean", listId: "L1", listTitle: "Work" };
}

describe("Inline expandable task tree", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  describe("Main list shows the task hierarchy inline", () => {
    it("renders subtasks directly under their parent", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Subtask one", { parent: "t1" }),
        task("t3", "Subtask two", { parent: "t1" }),
        task("t4", "Another top-level"),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      expect(screen.getByText("Another top-level")).toBeInTheDocument();
      expect(screen.getByText("Subtask one")).toBeInTheDocument();
      expect(screen.getByText("Subtask two")).toBeInTheDocument();
    });

    it("indents subtasks in the main list", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Child task", { parent: "t1" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      const widgets = container.querySelectorAll(".task-widget");
      expect(widgets[0].style.paddingLeft).toBe("0.5rem");
      expect(widgets[1].style.paddingLeft).toBe("2rem");
    });

    it("collapses and expands subtasks from the inline tree button without opening detail", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Child task", { parent: "t1" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Child task")).toBeInTheDocument());

      await fireEvent.click(screen.getByRole("button", { name: "Collapse Parent task" }));
      await waitFor(() => expect(screen.queryByText("Child task")).not.toBeInTheDocument());
      expect(screen.queryByText("Task Details")).not.toBeInTheDocument();

      await fireEvent.click(screen.getByRole("button", { name: "Expand Parent task" }));
      await waitFor(() => expect(screen.getByText("Child task")).toBeInTheDocument());
    });
  });

  describe("Parent shows subtask badge", () => {
    it("shows subtask progress badge (completed/total) on parent", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Sub A", { parent: "t1", status: "completed" }),
        task("t3", "Sub B", { parent: "t1" }),
        task("t4", "Sub C", { parent: "t1" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      // Should show "1/3" progress text
      expect(container.querySelector(".progress-text")).toBeInTheDocument();
      expect(container.querySelector(".progress-text").textContent).toBe("1/3");
    });

    it("does not show badge on tasks without subtasks", async () => {
      mockBackend([
        task("t1", "No children"),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("No children")).toBeInTheDocument());
      expect(container.querySelector(".progress-text")).not.toBeInTheDocument();
    });
  });

  describe("Subtasks visible in detail panel", () => {
    it("shows subtask checklist when detail panel opens for a parent task", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Sub A", { parent: "t1" }),
        task("t3", "Sub B", { parent: "t1", status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      // Click the task to open detail panel
      await fireEvent.click(screen.getByText("Parent task"));
      // Detail panel should show subtasks
      await waitFor(() => expect(screen.getByText("Subtasks")).toBeInTheDocument());
      expect(screen.getAllByText("Sub A").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Sub B").length).toBeGreaterThanOrEqual(1);
    });

    it("subtask checklist shows completed state", async () => {
      mockBackend([
        task("t1", "Parent task"),
        task("t2", "Done sub", { parent: "t1", status: "completed" }),
        task("t3", "Open sub", { parent: "t1" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Subtasks")).toBeInTheDocument());
      // Completed subtask should have a checked checkbox
      const subtaskItems = container.querySelectorAll(".subtask-item");
      expect(subtaskItems.length).toBe(2);
    });
  });

  describe("Enter opens detail panel", () => {
    it("Enter opens detail panel for focused task", async () => {
      mockBackend([
        task("t1", "Parent task"),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Enter" });
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());
    });
  });
});
