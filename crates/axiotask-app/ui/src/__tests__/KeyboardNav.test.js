import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(lists = [], tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId || null, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId };
        taskStore.unshift(t);
        return t;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return "token-1"; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "move_to_list": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

const lists = [{ id: "L1", title: "Work" }];
const today = new Date().toISOString().split("T")[0] + "T00:00:00Z";

function makeTasks(n = 3) {
  return Array.from({ length: n }, (_, i) => ({
    id: `t${i + 1}`, parent_id: null, title: `Task ${i + 1}`, notes: null,
    status: "needsAction", due: today, position: String(i).padStart(14, "0"),
    sync_state: "clean", listId: "L1", listTitle: "Work",
  }));
}

async function renderWithTasks(tasks = makeTasks()) {
  mockBackend(lists, tasks);
  localStorage.setItem("axiotask:view", "L1");
  render(App);
  await waitFor(() => expect(screen.getByText("Task 1")).toBeInTheDocument());
}

function pressKey(key, opts = {}) {
  return fireEvent.keyDown(window, { key, ...opts });
}

function getFocusedWidget(container) {
  return container.querySelector(".task-widget.focused");
}

describe("Keyboard Navigation", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  describe("j/k navigation", () => {
    it("j moves focus down", async () => {
      await renderWithTasks();
      const widgets = document.querySelectorAll(".task-widget");
      expect(widgets[0]).toHaveClass("focused");
      await pressKey("j");
      await waitFor(() => {
        const ws = document.querySelectorAll(".task-widget");
        expect(ws[0]).not.toHaveClass("focused");
        expect(ws[1]).toHaveClass("focused");
      });
    });

    it("k moves focus up", async () => {
      await renderWithTasks();
      await pressKey("j");
      await waitFor(() => expect(document.querySelectorAll(".task-widget")[1]).toHaveClass("focused"));
      await pressKey("k");
      await waitFor(() => {
        const ws = document.querySelectorAll(".task-widget");
        expect(ws[0]).toHaveClass("focused");
        expect(ws[1]).not.toHaveClass("focused");
      });
    });

    it("j does not go past the last item", async () => {
      await renderWithTasks(makeTasks(2));
      await pressKey("j"); // index 1
      await pressKey("j"); // should stay at 1
      await waitFor(() => {
        const ws = document.querySelectorAll(".task-widget");
        expect(ws[1]).toHaveClass("focused");
      });
    });

    it("k does not go above the first item", async () => {
      await renderWithTasks();
      await pressKey("k"); // already at 0
      await waitFor(() => {
        expect(document.querySelectorAll(".task-widget")[0]).toHaveClass("focused");
      });
    });
  });

  describe("Space — toggle complete", () => {
    it("pressing Space completes the focused task", async () => {
      await renderWithTasks();
      await pressKey(" ");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
      });
    });
  });

  describe("Enter — create task", () => {
    it("pressing Enter creates a new sibling task", async () => {
      await renderWithTasks();
      await pressKey("Enter");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ listId: "L1" }));
      });
    });
  });

  describe("e — edit title", () => {
    it("pressing e enters edit mode for focused task", async () => {
      await renderWithTasks();
      await pressKey("e");
      await waitFor(() => {
        expect(screen.getByDisplayValue("Task 1")).toBeInTheDocument();
      });
    });
  });

  describe("d — delete task", () => {
    it("pressing d deletes the focused task", async () => {
      await renderWithTasks();
      await pressKey("d");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("delete_task", { id: "t1" });
      });
    });
  });

  describe("n — open notes", () => {
    it("pressing n opens the notes panel", async () => {
      await renderWithTasks();
      await pressKey("n");
      await waitFor(() => {
        expect(screen.getByPlaceholderText("Add notes...")).toBeInTheDocument();
      });
    });
  });

  describe("t/w/m/r — date shortcuts", () => {
    it("t sets due to Tomorrow", async () => {
      await renderWithTasks();
      await pressKey("t");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Tomorrow" });
      });
    });

    it("w sets due to NextWeek", async () => {
      await renderWithTasks();
      await pressKey("w");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "NextWeek" });
      });
    });

    it("m sets due to NextMonth", async () => {
      await renderWithTasks();
      await pressKey("m");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "NextMonth" });
      });
    });

    it("r clears due date", async () => {
      await renderWithTasks();
      await pressKey("r");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Clear" });
      });
    });
  });

  describe("Tab — indent/outdent", () => {
    it("Tab indents under previous sibling", async () => {
      await renderWithTasks();
      await pressKey("j"); // focus Task 2
      await pressKey("Tab");
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("move_task", { id: "t2", parentId: "t1", previousId: null });
      });
    });

    it("Shift+Tab on root task does nothing", async () => {
      await renderWithTasks();
      await pressKey("Tab", { shiftKey: true });
      const moveCalls = invoke.mock.calls.filter(c => c[0] === "move_task");
      expect(moveCalls).toHaveLength(0);
    });
  });

  describe("Ctrl+M — move to list picker", () => {
    it("Ctrl+M opens the move-to-list picker", async () => {
      await renderWithTasks();
      await pressKey("m", { ctrlKey: true });
      await waitFor(() => {
        expect(screen.getByText(/move to/i)).toBeInTheDocument();
      });
    });
  });

  describe("Alt+↑↓ — reorder", () => {
    it("Alt+Down reorders task down", async () => {
      await renderWithTasks();
      await pressKey("ArrowDown", { altKey: true });
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("reorder_task", { id: "t1", direction: "down" });
      });
    });

    it("Alt+Up reorders task up", async () => {
      await renderWithTasks();
      await pressKey("j"); // move to index 1
      await pressKey("ArrowUp", { altKey: true });
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("reorder_task", { id: "t2", direction: "up" });
      });
    });
  });

  describe("/ — search", () => {
    it("pressing / opens the search overlay", async () => {
      await renderWithTasks();
      await pressKey("/");
      await waitFor(() => {
        expect(screen.getByPlaceholderText(/search/i)).toBeInTheDocument();
      });
    });
  });

  describe("? — cheatsheet", () => {
    it("pressing ? shows the keyboard cheatsheet", async () => {
      await renderWithTasks();
      await pressKey("?");
      await waitFor(() => {
        expect(screen.getByText(/keyboard shortcuts/i)).toBeInTheDocument();
      });
    });
  });

  describe("No fire when in inputs", () => {
    it("does not trigger shortcuts when typing in QuickAdd input", async () => {
      await renderWithTasks();
      const input = screen.getByPlaceholderText("Add a task... (Enter)");
      input.focus();
      await fireEvent.keyDown(input, { key: "d" });
      const deleteCalls = invoke.mock.calls.filter(c => c[0] === "delete_task");
      expect(deleteCalls).toHaveLength(0);
    });

    it("does not trigger shortcuts when editing a task title", async () => {
      await renderWithTasks();
      await pressKey("e"); // enter edit mode
      await waitFor(() => expect(screen.getByDisplayValue("Task 1")).toBeInTheDocument());
      const editInput = screen.getByDisplayValue("Task 1");
      await fireEvent.keyDown(editInput, { key: "d" });
      const deleteCalls = invoke.mock.calls.filter(c => c[0] === "delete_task");
      expect(deleteCalls).toHaveLength(0);
    });

    it("does not trigger shortcuts when typing in notes textarea", async () => {
      await renderWithTasks();
      await pressKey("n"); // open notes
      await waitFor(() => expect(screen.getByPlaceholderText("Add notes...")).toBeInTheDocument());
      const textarea = screen.getByPlaceholderText("Add notes...");
      await fireEvent.keyDown(textarea, { key: "d" });
      const deleteCalls = invoke.mock.calls.filter(c => c[0] === "delete_task");
      expect(deleteCalls).toHaveLength(0);
    });
  });
});
