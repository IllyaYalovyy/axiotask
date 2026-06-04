import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
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

describe("GH#20: Ctrl+V paste creates tasks", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("single line paste creates one task", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Buy groceries");

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1", title: "Buy groceries" }));
    });
  });

  it("multi-line paste creates multiple tasks", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Task one\nTask two\nTask three");

    await waitFor(() => {
      const createCalls = invoke.mock.calls.filter(c => c[0] === "create_task");
      expect(createCalls.length).toBe(3);
      expect(createCalls[0][1].title).toBe("Task one");
      expect(createCalls[1][1].title).toBe("Task two");
      expect(createCalls[2][1].title).toBe("Task three");
    });
  });

  it("skips empty lines in multi-line paste", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Task one\n\n  \nTask two\n");

    await waitFor(() => {
      const createCalls = invoke.mock.calls.filter(c => c[0] === "create_task");
      expect(createCalls.length).toBe(2);
    });
  });

  it("long text truncates title and stores full text in notes", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    const longText = "A".repeat(600);
    pasteText(longText);

    await waitFor(() => {
      const createCalls = invoke.mock.calls.filter(c => c[0] === "create_task");
      expect(createCalls.length).toBe(1);
      expect(createCalls[0][1].title).toBe("A".repeat(500));
    });

    await waitFor(() => {
      const notesCalls = invoke.mock.calls.filter(c => c[0] === "set_notes");
      expect(notesCalls.length).toBe(1);
      expect(notesCalls[0][1].notes).toBe(longText);
    });
  });

  it("shows toast confirming task creation count", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Task A\nTask B");

    await waitFor(() => {
      expect(screen.getByText(/2 tasks from clipboard/)).toBeInTheDocument();
    });
  });

  it("shows singular toast for one task", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());

    pasteText("Single task");

    await waitFor(() => {
      expect(screen.getByText(/1 task from clipboard/)).toBeInTheDocument();
    });
  });

  it("does not intercept paste when input is focused", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([{ id: "t1", parent_id: null, title: "Existing", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" }]);
    render(App);
    await waitFor(() => expect(screen.getByText("Existing")).toBeInTheDocument());

    // Enter edit mode
    await fireEvent.keyDown(window, { key: "e" });
    await waitFor(() => expect(screen.getByDisplayValue("Existing")).toBeInTheDocument());
    const input = screen.getByDisplayValue("Existing");

    // Simulate paste on the input element — should NOT create task
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
  });
});
