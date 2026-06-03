import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const today = new Date().toISOString();

function mockBackend(tasks = [], lists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }]) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `new-${nextId++}`, parent_id: args.parentId || null, title: args.title, notes: null, status: "needsAction", due: null, position: "00000000000000", sync_state: "clean", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title || "" };
        // Prepend — new task is at position 0 (top)
        taskStore.unshift(t);
        return t;
      }
      case "toggle_complete": return null;
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      case "create_list": return { id: "L3", title: args.title };
      case "move_to_list": return null;
      default: return null;
    }
  });
}

function task(id, title, listId = "L1", opts = {}) {
  return { id, parent_id: null, title, notes: null, status: "needsAction", due: opts.due || today, position: opts.pos || id, sync_state: "clean", listId, listTitle: listId === "L1" ? "Work" : "Personal" };
}

describe("GH#1: New task appears at top, in focus, edit mode active", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  describe("QuickAdd in list view", () => {
    it("new task appears at top of list with focus index 0", async () => {
      localStorage.setItem("axiotask:view", "L1");
      mockBackend([task("t1", "Existing task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

      const input = screen.getByPlaceholderText("Add a task... (Enter)");
      await fireEvent.input(input, { target: { value: "Brand new task" } });
      await fireEvent.keyDown(input, { key: "Enter" });

      await waitFor(() => {
        const widgets = container.querySelectorAll(".task-widget");
        expect(widgets.length).toBeGreaterThanOrEqual(2);
        // New task is at top — it's in edit mode so title is in the input value
        const editInput = widgets[0].querySelector(".edit-input");
        expect(editInput).toBeInTheDocument();
        expect(editInput.value).toBe("Brand new task");
        // Second widget is the original task
        expect(widgets[1].textContent).toContain("Existing task");
      });
    });

    it("new task is focused (has .focused class on first widget)", async () => {
      localStorage.setItem("axiotask:view", "L1");
      mockBackend([task("t1", "Existing task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

      const input = screen.getByPlaceholderText("Add a task... (Enter)");
      await fireEvent.input(input, { target: { value: "Focused task" } });
      await fireEvent.keyDown(input, { key: "Enter" });

      await waitFor(() => {
        const widgets = container.querySelectorAll(".task-widget");
        expect(widgets[0]).toHaveClass("focused");
      });
    });

    it("new task enters edit mode immediately", async () => {
      localStorage.setItem("axiotask:view", "L1");
      mockBackend([task("t1", "Existing task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

      const input = screen.getByPlaceholderText("Add a task... (Enter)");
      await fireEvent.input(input, { target: { value: "Editable task" } });
      await fireEvent.keyDown(input, { key: "Enter" });

      await waitFor(() => {
        // First widget should have an active edit input
        const editInput = container.querySelector(".task-widget .edit-input");
        expect(editInput).toBeInTheDocument();
      });
    });
  });

  describe("QuickAdd in smart view switches to target list", () => {
    it("switches view to target list when creating from focus view", async () => {
      localStorage.setItem("axiotask:view", "focus");
      mockBackend([task("t1", "Focus task", "L1", { due: today })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Focus task")).toBeInTheDocument());

      const input = screen.getByPlaceholderText("Add a task... (Enter)");
      await fireEvent.input(input, { target: { value: "New from smart view" } });
      await fireEvent.keyDown(input, { key: "Enter" });

      // Should have called create_task with the first list (L1)
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1", title: "New from smart view" }));
      });
    });
  });

  describe("Enter key creates task at top with edit mode", () => {
    it("Enter key creates empty task at top in edit mode", async () => {
      localStorage.setItem("axiotask:view", "L1");
      mockBackend([task("t1", "Existing task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

      // Press Enter on the window (not in an input) — keyboard shortcut
      await fireEvent.keyDown(window, { key: "Enter" });

      // Should create a task with empty title (for inline editing)
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ title: "", listId: "L1" }));

      await waitFor(() => {
        // Should have an editing input in the first widget
        const editInput = container.querySelector(".task-widget .edit-input");
        expect(editInput).toBeInTheDocument();
      });
    });
  });
});
