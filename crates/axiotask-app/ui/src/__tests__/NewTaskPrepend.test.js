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
        taskStore.unshift(t);
        return t;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function task(id, title, listId = "L1", opts = {}) {
  return { id, parent_id: null, title, notes: null, status: "needsAction", due: opts.due || today, position: opts.pos || id, sync_state: "clean", listId, listTitle: "Work" };
}

describe("Quick-add task creation", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("+ New task button focuses the quick-add input without creating an empty task", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("+ New task"));

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    expect(input).toHaveFocus();
    expect(invoke.mock.calls.filter(c => c[0] === "create_task")).toHaveLength(0);
  });

  it("n key focuses the quick-add input without creating an empty task", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "n" });

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    expect(input).toHaveFocus();
    expect(invoke.mock.calls.filter(c => c[0] === "create_task")).toHaveLength(0);
  });

  it("submitting quick-add creates a titled task at the top", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "New titled task" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      const widgets = container.querySelectorAll(".task-widget");
      expect(widgets.length).toBeGreaterThanOrEqual(2);
      expect(widgets[0]).toHaveTextContent("New titled task");
    });
  });

  it("submitting in a smart view creates in the target list without switching views", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([task("t1", "Focus task", "L1", { due: today })]);
    render(App);
    await waitFor(() => expect(screen.getByText("Focus task")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Smart capture" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1", title: "Smart capture" }));
    });
    expect(screen.getByText("Focus")).toBeInTheDocument();
  });
});
