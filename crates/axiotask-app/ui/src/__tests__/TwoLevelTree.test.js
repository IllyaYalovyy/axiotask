import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// #87: the task tree is STRICTLY two levels. A top-level task may have a flat
// list of subtasks; a subtask may never gain one, and a task with subtasks can
// never become a subtask. These tests assert what the USER sees at the two
// surfaces where subtasks are touched: the detail panel and the context menu.

const lists = [{ id: "L1", title: "Work" }];

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 500;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter((t) => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId ?? null, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId, listTitle: "Work" };
        taskStore.push(t);
        return t;
      }
      case "rename_task": { const t = taskStore.find((x) => x.id === args.id); if (t) t.title = args.title; return null; }
      case "toggle_complete": { const t = taskStore.find((x) => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "move_task": { const t = taskStore.find((x) => x.id === args.id); if (t) t.parent_id = args.parentId; return null; }
      case "delete_task": { taskStore = taskStore.filter((t) => t.id !== args.id); return null; }
      case "set_due": case "set_notes": case "move_to_list": case "reorder_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { get: () => taskStore };
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: null, status: opts.status || "needsAction", due: null, position: opts.pos || id, sync_state: "clean", listId: "L1", listTitle: "Work", web_view_link: null };
}

describe("#87 strict two-level tree", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("a subtask's detail panel offers no way to add a sub-subtask", async () => {
    mockBackend([task("t1", "Parent task"), task("s1", "A subtask", { parent: "t1" })]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

    // Open the parent — its checklist has the "Add a subtask" field.
    await fireEvent.click(screen.getByText("Parent task"));
    await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());
    expect(screen.getByLabelText("New subtask")).toBeInTheDocument();

    // Drill into the subtask. Its panel is a "Subtask" and — because a subtask
    // can't gain a subtask — shows NO checklist and NO add-subtask affordance.
    await fireEvent.click(container.querySelector(".detail-panel .subtask-title"));
    await waitFor(() => expect(screen.getByText("Subtask", { exact: true })).toBeInTheDocument());
    expect(screen.queryByLabelText("New subtask")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add subtask" })).not.toBeInTheDocument();
    expect(screen.queryByText("Subtasks")).not.toBeInTheDocument();
  });

  it("a top-level task that has subtasks can still gain more (Add subtask offered)", async () => {
    mockBackend([task("t1", "Parent task"), task("s1", "A subtask", { parent: "t1" })]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

    await fireEvent.contextMenu(container.querySelector(".task-widget"));
    await waitFor(() => expect(container.querySelector(".context-menu")).toBeInTheDocument());
    expect(screen.getByText("Add subtask")).toBeInTheDocument();
    // It is top-level, so there is nothing to detach from.
    expect(screen.queryByText("Detach subtask")).not.toBeInTheDocument();
  });

  it("adding a subtask from the parent panel keeps it exactly one level deep", async () => {
    const backend = mockBackend([task("t1", "Parent task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("Parent task"));
    await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

    const input = screen.getByLabelText("New subtask");
    await fireEvent.input(input, { target: { value: "Buy milk" } });
    await fireEvent.keyDown(input, { key: "Enter" });

    // The subtask was created under the top-level parent (one level), never a
    // deeper level, and appears in the parent's checklist.
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());
    const created = backend.get().find((t) => t.title === "Buy milk");
    expect(created.parent_id).toBe("t1");
  });
});
