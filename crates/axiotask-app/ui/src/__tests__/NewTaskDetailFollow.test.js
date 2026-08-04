import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Work" }];

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 300;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `new-${nextId++}`, parent_id: args.parentId || null, title: args.title, notes: null, status: "needsAction", due: null, position: "00000000000000", sync_state: "dirty", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title || "" };
        taskStore.unshift(t);
        return t;
      }
      case "set_due": {
        const t = taskStore.find(x => x.id === args.id);
        if (t && args.mv?.startsWith("raw:")) t.due = `${args.mv.slice(4)}T00:00:00.000Z`;
        return null;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function task(id, title, listId = "L1", opts = {}) {
  return { id, parent_id: null, title, notes: null, status: "needsAction", due: opts.due || null, position: opts.pos || id, sync_state: "clean", listId, listTitle: "Work" };
}

describe("New task follows the open detail panel", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("switches the open sidebar to the newly created task", async () => {
    mockBackend([task("t1", "Existing task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    // Open the detail panel on the existing task.
    await fireEvent.click(screen.getByText("Existing task"));
    await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Existing task"));

    // Quick-add a brand new task while the panel is open.
    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Brand new task" } });
    await fireEvent.submit(input.closest("form"));

    // The sidebar switches to the newly created (now focused) task.
    await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Brand new task"));
    expect(screen.getByText("Task Details")).toBeInTheDocument();
  });

  it("leaves the sidebar closed when it was closed before creating (non-happy path)", async () => {
    mockBackend([task("t1", "Existing task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing task")).toBeInTheDocument());

    // Panel is closed — no detail header rendered.
    expect(screen.queryByText("Task Details")).not.toBeInTheDocument();

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Another task" } });
    await fireEvent.submit(input.closest("form"));

    // The new task exists as a row…
    await waitFor(() => expect(screen.getByText("Another task")).toBeInTheDocument());
    // …but the panel does NOT auto-open — creation alone never opens the sidebar.
    expect(screen.queryByText("Task Details")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Title")).not.toBeInTheDocument();
  });

  it("switches even when the panel was showing a different task", async () => {
    mockBackend([task("t1", "First", "L1", { pos: "1" }), task("t2", "Second", "L1", { pos: "2" })]);
    render(App);
    await waitFor(() => expect(screen.getByText("Second")).toBeInTheDocument());

    await fireEvent.click(screen.getByText("Second"));
    await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Second"));

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Freshly added" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Freshly added"));
  });
});
