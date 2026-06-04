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

describe("GH#1: New task appears at top, in focus, edit mode active", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("+ New task button creates task at top in edit mode", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("+ New task"));

    await waitFor(() => {
      const widgets = container.querySelectorAll(".task-widget");
      expect(widgets.length).toBeGreaterThanOrEqual(2);
      expect(widgets[0].querySelector(".edit-input")).toBeInTheDocument();
    });
  });

  it("n key creates task at top in edit mode", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "n" });

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ title: "", listId: "L1" }));
      const editInput = container.querySelector(".task-widget .edit-input");
      expect(editInput).toBeInTheDocument();
    });
  });

  it("new task is focused (first widget has .focused class)", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Existing task")]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("+ New task"));

    await waitFor(() => {
      const widgets = container.querySelectorAll(".task-widget");
      expect(widgets[0]).toHaveClass("focused");
    });
  });

  it("in smart view, switches to target list", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([task("t1", "Focus task", "L1", { due: today })]);
    render(App);
    await waitFor(() => expect(screen.getByText("Focus task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("+ New task"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1" }));
    });
  });
});
