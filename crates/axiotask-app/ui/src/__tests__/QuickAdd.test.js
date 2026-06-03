import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const sampleLists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }];
const today = new Date().toISOString();

function mockBackend(lists = sampleLists, tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `new-${nextId++}`, parent_id: null, title: args.title, notes: null, status: "needsAction", due: null, position: "00000000000000", sync_state: "clean", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title || "" };
        taskStore.unshift(t);
        return t;
      }
      case "toggle_complete": return null;
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": return null;
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

describe("GH#8: Quick-add input", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("is always visible at top of content area", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByPlaceholderText("Add a task... (Enter)")).toBeInTheDocument());
  });

  it("shows target list hint when viewing a specific list", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend(sampleLists, [{ id: "t1", parent_id: null, title: "Task", notes: null, status: "needsAction", due: today, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" }]);
    render(App);
    await waitFor(() => expect(screen.getByText(/→ Work/)).toBeInTheDocument());
  });

  it("shows target list hint (first list) in smart views", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend(sampleLists, [{ id: "t1", parent_id: null, title: "Task", notes: null, status: "needsAction", due: today, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" }]);
    render(App);
    await waitFor(() => expect(screen.getByText(/→ Work/)).toBeInTheDocument());
  });

  it("clears input after Enter creates task", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByPlaceholderText("Add a task... (Enter)")).toBeInTheDocument());
    const input = screen.getByPlaceholderText("Add a task... (Enter)");
    await fireEvent.input(input, { target: { value: "New task" } });
    await fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(input.value).toBe(""));
  });

  it("creates task in current list on Enter", async () => {
    localStorage.setItem("axiotask:view", "L2");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByPlaceholderText("Add a task... (Enter)")).toBeInTheDocument());
    const input = screen.getByPlaceholderText("Add a task... (Enter)");
    await fireEvent.input(input, { target: { value: "Personal task" } });
    await fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L2", title: "Personal task" }));
    });
  });

  it("updates hint when switching lists", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend(sampleLists, [
      { id: "t1", parent_id: null, title: "Task", notes: null, status: "needsAction", due: today, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
      { id: "t2", parent_id: null, title: "Task2", notes: null, status: "needsAction", due: today, position: "2", sync_state: "clean", listId: "L2", listTitle: "Personal" },
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText(/→ Work/)).toBeInTheDocument());
    // Switch to Personal list
    await fireEvent.click(screen.getByText("Personal"));
    await waitFor(() => expect(screen.getByText(/→ Personal/)).toBeInTheDocument());
  });
});
