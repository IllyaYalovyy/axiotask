import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const sampleLists = [{ id: "L1", title: "Work" }];

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return sampleLists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `new-${nextId++}`, parent_id: null, title: args.title, notes: null, status: "needsAction", due: null, position: "00000000000000", sync_state: "clean", listId: args.listId, listTitle: "Work" };
        taskStore.unshift(t);
        return t;
      }
      case "set_notes": {
        const t = taskStore.find(t => t.id === args.id);
        if (t) t.notes = args.notes;
        return null;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function pasteText(text) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  event.clipboardData = { getData: () => text };
  event.preventDefault = vi.fn();
  window.dispatchEvent(event);
  return event;
}

describe("Ctrl+V paste creates tasks", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("single line paste creates one task immediately (no dialog)", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Buy groceries");

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1", title: "Buy groceries" }));
    });
    expect(screen.queryByRole("dialog", { name: /add multiple tasks/i })).not.toBeInTheDocument();
  });

  it("multi-line paste opens the bulk-add dialog prefilled (does not create yet)", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Task one\nTask two\nTask three");

    const dialog = await screen.findByRole("dialog", { name: /add multiple tasks/i });
    // Nothing is created until the user confirms in the dialog.
    expect(invoke.mock.calls.filter(c => c[0] === "create_task").length).toBe(0);
    // The pasted text is prefilled.
    expect(within(dialog).getByRole("textbox")).toHaveValue("Task one\nTask two\nTask three");
  });

  it("does not intercept paste when an input/textarea is focused", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([{ id: "t1", parent_id: null, title: "Existing", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" }]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e" });
    await waitFor(() => expect(screen.getByDisplayValue("Existing")).toBeInTheDocument());
    const input = screen.getByDisplayValue("Existing");

    const event = new Event("paste", { bubbles: true, cancelable: true });
    event.clipboardData = { getData: () => "Should not create" };
    event.preventDefault = vi.fn();
    Object.defineProperty(event, "target", { value: input });
    window.dispatchEvent(event);

    await new Promise(r => setTimeout(r, 50));
    const createCalls = invoke.mock.calls.filter(c => c[0] === "create_task" && c[1]?.title === "Should not create");
    expect(createCalls.length).toBe(0);
  });

  it("does nothing when paste text is empty", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    const createBefore = invoke.mock.calls.filter(c => c[0] === "create_task").length;
    pasteText("   ");

    await new Promise(r => setTimeout(r, 50));
    const createAfter = invoke.mock.calls.filter(c => c[0] === "create_task").length;
    expect(createAfter).toBe(createBefore);
    expect(screen.queryByRole("dialog", { name: /add multiple tasks/i })).not.toBeInTheDocument();
  });
});
