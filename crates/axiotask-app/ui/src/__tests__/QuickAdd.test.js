import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

const today = new Date().toISOString().split("T")[0] + "T00:00:00Z";

function task(id, title, listId = "L1", due = today) {
  return {
    id,
    parent_id: null,
    title,
    notes: null,
    status: "needsAction",
    due,
    position: id,
    sync_state: "clean",
    listId,
    listTitle: lists.find(l => l.id === listId)?.title || "",
  };
}

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const created = task(`new-${nextId++}`, args.title, args.listId, null);
        created.parent_id = args.parentId || null;
        taskStore.unshift(created);
        return created;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("Quick-add input", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("is always visible and creates a titled task without switching away from the current smart view", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([task("t1", "Due today")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Due today")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Capture follow-up" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "create_task",
        expect.objectContaining({ listId: "L1", parentId: null, title: "Capture follow-up" }),
      );
    });
    await waitFor(() => expect(input).toHaveValue(""));
    expect(screen.getByText("Focus")).toBeInTheDocument();
  });

  it("does not create an empty task when submitted blank", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "   " } });
    await fireEvent.submit(input.closest("form"));

    await new Promise(resolve => setTimeout(resolve, 50));
    expect(invoke.mock.calls.filter(call => call[0] === "create_task")).toHaveLength(0);
    expect(input).toHaveValue("   ");
  });
});
