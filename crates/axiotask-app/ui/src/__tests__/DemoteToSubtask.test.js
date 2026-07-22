import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// #88: a top-level task is demoted into a subtask through a SEARCHABLE parent
// picker (replacing the removed Tab-indent gesture, #86). Only a top-level task
// with no subtasks of its own can be demoted, and the parent it picks must be
// another top-level task in the same list. These tests assert what the USER
// sees: the context-menu affordance, the searchable picker, and the row leaving
// the flat list once it becomes a subtask.

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
      case "set_due": case "set_notes": case "move_to_list": case "reorder_task": case "record_move": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { get: () => taskStore };
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: null, status: opts.status || "needsAction", due: null, position: opts.pos || id, sync_state: "clean", listId: opts.listId || "L1", listTitle: "Work", web_view_link: null };
}

async function openMenu(container, title) {
  const row = screen.getByText(title).closest(".task-widget");
  await fireEvent.contextMenu(row);
  await waitFor(() => expect(container.querySelector(".context-menu")).toBeInTheDocument());
}

describe("#88 demote a top-level task into a subtask via a parent picker", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("offers 'Make subtask of…' on a childless top-level task and demotes it via the searchable picker", async () => {
    const backend = mockBackend([
      task("t1", "Write report"),
      task("t2", "Project Alpha"),
      task("t3", "Project Beta"),
      task("s1", "Alpha step one", { parent: "t2" }),
    ]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Write report")).toBeInTheDocument());

    await openMenu(container, "Write report");
    const menuItem = screen.getByText("Make subtask of…");
    await fireEvent.click(menuItem);

    // The searchable picker opens and lists candidate parents — the OTHER
    // top-level tasks in the list, never the task itself and never a subtask.
    const dialog = await screen.findByRole("dialog", { name: /make subtask of/i });
    expect(within(dialog).getByText("Project Alpha")).toBeInTheDocument();
    expect(within(dialog).getByText("Project Beta")).toBeInTheDocument();
    expect(within(dialog).queryByText("Write report")).not.toBeInTheDocument();
    expect(within(dialog).queryByText("Alpha step one")).not.toBeInTheDocument();

    // The picker is searchable: typing narrows the candidate list.
    const input = within(dialog).getByRole("textbox");
    await fireEvent.input(input, { target: { value: "beta" } });
    await waitFor(() => expect(within(dialog).queryByText("Project Alpha")).not.toBeInTheDocument());
    expect(within(dialog).getByText("Project Beta")).toBeInTheDocument();

    await fireEvent.click(within(dialog).getByText("Project Beta"));

    // What the user sees: the demoted task is now a subtask, so it leaves the
    // flat top-level list entirely.
    await waitFor(() => expect(screen.queryByText("Write report")).not.toBeInTheDocument());
    expect(backend.get().find((t) => t.id === "t1").parent_id).toBe("t3");
  });

  it("does NOT offer demotion for a task that already has subtasks of its own", async () => {
    const { container } = (() => {
      mockBackend([
        task("t1", "Has children"),
        task("s1", "A child", { parent: "t1" }),
        task("t2", "Another top-level"),
      ]);
      return render(App);
    })();
    await waitFor(() => expect(screen.getByText("Has children")).toBeInTheDocument());

    await openMenu(container, "Has children");
    // It can gain subtasks but can never itself become one (would be 3 levels).
    expect(screen.getByText("Add subtask")).toBeInTheDocument();
    expect(screen.queryByText("Make subtask of…")).not.toBeInTheDocument();
  });

  it("does NOT offer demotion when there is no other top-level task to nest under", async () => {
    const { container } = (() => {
      mockBackend([task("t1", "Lonely task")]);
      return render(App);
    })();
    await waitFor(() => expect(screen.getByText("Lonely task")).toBeInTheDocument());

    await openMenu(container, "Lonely task");
    expect(screen.queryByText("Make subtask of…")).not.toBeInTheDocument();
  });
});
