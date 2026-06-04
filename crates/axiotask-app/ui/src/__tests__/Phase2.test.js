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
        const t = { id: `t-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14,"0"), sync_state: "clean", listId: args.listId };
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
      default: return null;
    }
  });
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: opts.notes || null, status: opts.status || "needsAction", due: opts.due || today, position: opts.pos || "1", sync_state: "clean", listId: "L1", listTitle: "Work" };
}

describe("Phase 2: Task Lifecycle", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  describe("Inline Edit", () => {
    it("e key enters edit mode with input", async () => {
      mockBackend([task("t1", "Edit me")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Edit me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "e" });
      await waitFor(() => expect(container.querySelector("input.edit-input")).toBeInTheDocument());
    });

    it("Enter in edit saves title", async () => {
      mockBackend([task("t1", "Old")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Old")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "e" });
      await waitFor(() => expect(container.querySelector("input.edit-input")).toBeInTheDocument());
      const input = container.querySelector("input.edit-input");
      await fireEvent.input(input, { target: { value: "New" } });
      await fireEvent.keyDown(input, { key: "Enter" });
      expect(invoke).toHaveBeenCalledWith("rename_task", { id: "t1", title: "New" });
    });

    it("Escape cancels edit", async () => {
      mockBackend([task("t1", "Keep")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Keep")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "e" });
      await waitFor(() => expect(container.querySelector("input.edit-input")).toBeInTheDocument());
      await fireEvent.keyDown(container.querySelector("input.edit-input"), { key: "Escape" });
      await waitFor(() => expect(container.querySelector("input.edit-input")).not.toBeInTheDocument());
    });
  });

  describe("Complete/Delete", () => {
    it("Space toggles complete", async () => {
      mockBackend([task("t1", "Toggle")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Toggle")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });

    it("d deletes with undo toast", async () => {
      mockBackend([task("t1", "Doomed")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Doomed")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "d" });
      expect(invoke).toHaveBeenCalledWith("delete_task", { id: "t1" });
      await waitFor(() => expect(screen.getByText(/Deleted "Doomed"/)).toBeInTheDocument());
    });
  });

  describe("Due Date Moves", () => {
    it("t sets due to Tomorrow", async () => {
      mockBackend([task("t1", "Defer")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Defer")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "t" });
      expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Tomorrow" });
    });

    it("w sets due to NextWeek", async () => {
      mockBackend([task("t1", "Later")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Later")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "w" });
      expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "NextWeek" });
    });

    it("r clears due date", async () => {
      mockBackend([task("t1", "Clear")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Clear")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "r" });
      expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Clear" });
    });
  });

  describe("Notes Panel", () => {
    it("Enter opens detail panel which shows notes", async () => {
      mockBackend([task("t1", "Has notes", { notes: "my note" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Has notes")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Enter" });
      await waitFor(() => expect(screen.getByText("Notes")).toBeInTheDocument());
    });

    it("Escape closes detail panel", async () => {
      mockBackend([task("t1", "Task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Enter" });
      await waitFor(() => expect(screen.getByText("Notes")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Escape" });
      await waitFor(() => expect(screen.queryByPlaceholderText("Add notes...")).not.toBeInTheDocument());
    });
  });

  describe("Subtasks & Indent", () => {
    it("n key creates a new task (not subtask)", async () => {
      mockBackend([task("t1", "Parent")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "n" });
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ parentId: null }));
    });

    it("Enter opens detail panel for focused task", async () => {
      mockBackend([task("t1", "Sibling")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Sibling")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Enter" });
      await waitFor(() => expect(screen.getByText("Notes")).toBeInTheDocument());
    });

    it("Tab indents (calls move_task with parent)", async () => {
      mockBackend([task("t1", "Above", { pos: "1" }), task("t2", "Below", { pos: "2" })]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Below")).toBeInTheDocument());
      // Focus second task
      await fireEvent.keyDown(window, { key: "j" });
      await fireEvent.keyDown(window, { key: "Tab" });
      expect(invoke).toHaveBeenCalledWith("move_task", { id: "t2", parentId: "t1", previousId: null });
    });
  });

  describe("Reorder", () => {
    it("Alt+Down reorders task down", async () => {
      mockBackend([task("t1", "First", { pos: "1" }), task("t2", "Second", { pos: "2" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("First")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "ArrowDown", altKey: true });
      expect(invoke).toHaveBeenCalledWith("reorder_task", { id: "t1", direction: "down" });
    });

    it("Alt+Up reorders task up", async () => {
      mockBackend([task("t1", "First", { pos: "1" }), task("t2", "Second", { pos: "2" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("First")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "j" }); // focus second
      await fireEvent.keyDown(window, { key: "ArrowUp", altKey: true });
      expect(invoke).toHaveBeenCalledWith("reorder_task", { id: "t2", direction: "up" });
    });
  });
});
