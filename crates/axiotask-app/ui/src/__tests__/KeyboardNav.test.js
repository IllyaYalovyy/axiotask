import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import { formatDue } from "../dateFormat.js";

const pad = (v) => String(v).padStart(2, "0");
function isoDay(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T00:00:00.000Z`;
}

// Mirror of the backend's apply_date_move (axiotask-core/src/dates.rs) so a
// stateful set_due updates a task's due to exactly what the real command would
// produce — the row can then be asserted on its RENDERED date label.
function dueFromMove(mv) {
  if (mv === "Clear") return null;
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  if (mv === "Tomorrow") d.setDate(d.getDate() + 1);
  else if (mv === "NextWeek") d.setDate(d.getDate() + 7);
  else if (mv === "NextMonth") {
    const day = d.getDate();
    d.setDate(1);
    d.setMonth(d.getMonth() + 1);
    const lastDay = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
    d.setDate(Math.min(day, lastDay));
  }
  return isoDay(d);
}
// The human label a row will render for a given date shortcut.
const dueLabelFor = (mv) => formatDue(dueFromMove(mv));

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
      case "set_due": { const t = taskStore.find(x => x.id === args.id); if (t) t.due = dueFromMove(args.mv); return null; }
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": {
        // Swap the task with its top-level sibling in the given direction so
        // list_tasks (which preserves store order) reflects the new order.
        const t = taskStore.find(x => x.id === args.id);
        if (t) {
          const sibs = taskStore.filter(x => x.listId === t.listId && x.parent_id === t.parent_id);
          const si = sibs.indexOf(t);
          const neighbor = args.direction === "down" ? sibs[si + 1] : sibs[si - 1];
          if (neighbor) {
            const ai = taskStore.indexOf(t), bi = taskStore.indexOf(neighbor);
            [taskStore[ai], taskStore[bi]] = [taskStore[bi], taskStore[ai]];
          }
        }
        return null;
      }
      case "move_to_list": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

const lists = [{ id: "L1", title: "Work" }];
function localIsoDaysFromNow(n) {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() + n);
  const pad = (v) => String(v).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T00:00:00Z`;
}
const today = localIsoDaysFromNow(0);
const yesterday = localIsoDaysFromNow(-1);

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
  const result = render(App);
  await waitFor(() => expect(screen.getByText(tasks[0]?.title || "Task 1")).toBeInTheDocument());
  return result;
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

    it("Focus j follows the visual overdue-first order (top-level cards only)", async () => {
      mockBackend(lists, [
        { id: "today", parent_id: null, title: "Today card", notes: null, status: "needsAction", due: today, position: "00000000000001", sync_state: "clean", listId: "L1", listTitle: "Work" },
        { id: "parent", parent_id: null, title: "Inherited overdue parent", notes: null, status: "needsAction", due: null, position: "00000000000002", sync_state: "clean", listId: "L1", listTitle: "Work" },
        { id: "child", parent_id: "parent", title: "Overdue child", notes: null, status: "needsAction", due: yesterday, position: "00000000000003", sync_state: "clean", listId: "L1", listTitle: "Work" },
      ]);
      localStorage.setItem("axiotask:view", "focus");
      render(App);

      await waitFor(() => expect(screen.getByText("Inherited overdue parent")).toBeInTheDocument());

      // The subtask is not a row (#82); only the two top-level cards render.
      // The parent is overdue via its subtask's inherited date, so it sorts
      // above the Today card.
      expect(screen.queryByText("Overdue child")).not.toBeInTheDocument();
      let widgets = document.querySelectorAll(".task-widget");
      expect(widgets).toHaveLength(2);
      expect(widgets[0].querySelector(".title")).toHaveTextContent("Inherited overdue parent");
      expect(widgets[1].querySelector(".title")).toHaveTextContent("Today card");
      expect(widgets[0]).toHaveClass("focused");

      await pressKey("j");
      await waitFor(() => {
        widgets = document.querySelectorAll(".task-widget");
        expect(widgets[1]).toHaveClass("focused");
      });
    });
  });

  describe("Space — toggle complete", () => {
    it("pressing Space completes the focused task (it leaves the open list)", async () => {
      await renderWithTasks();
      expect(screen.getByText("Task 1")).toBeInTheDocument();
      await pressKey(" ");
      // Completed tasks are hidden by default, so the row leaves the list and
      // an Undo toast appears — the user-visible result of the completion.
      await waitFor(() => expect(screen.queryByText("Task 1")).not.toBeInTheDocument());
      expect(screen.getByText(/Completed "Task 1"/)).toBeInTheDocument();
      // The other cards stay put.
      expect(screen.getByText("Task 2")).toBeInTheDocument();
    });
  });

  describe("Enter — open detail panel", () => {
    it("pressing Enter opens detail panel for focused task", async () => {
      await renderWithTasks();
      await pressKey("Enter");
      await waitFor(() => {
        expect(screen.getByText(/notes/i)).toBeInTheDocument();
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
    it("pressing d removes the focused task's row from the list", async () => {
      await renderWithTasks();
      expect(screen.getByText("Task 1")).toBeInTheDocument();
      await pressKey("d");
      await waitFor(() => expect(screen.queryByText("Task 1")).not.toBeInTheDocument());
      // Only the focused task goes; the rest remain rendered.
      expect(screen.getByText("Task 2")).toBeInTheDocument();
      expect(screen.getByText("Task 3")).toBeInTheDocument();
    });
  });

  describe("n — new task", () => {
    it("pressing n focuses quick-add without creating an empty task", async () => {
      await renderWithTasks();
      await pressKey("n");
      expect(screen.getByRole("textbox", { name: /quick add task/i })).toHaveFocus();
      expect(invoke.mock.calls.filter(c => c[0] === "create_task")).toHaveLength(0);
    });
  });

  describe("s — no longer a subtask shortcut (#91)", () => {
    it("pressing s over the focused task adds no new row", async () => {
      const { container } = await renderWithTasks();
      const before = container.querySelectorAll(".task-widget").length;
      await pressKey("s");
      // Subtasks are added only from the detail panel; the list-level 's'
      // shortcut was removed, so no new card appears in the list.
      await new Promise((resolve) => setTimeout(resolve, 30));
      expect(container.querySelectorAll(".task-widget")).toHaveLength(before);
      expect(screen.queryByText("Untitled")).not.toBeInTheDocument();
    });
  });

  describe("t/w/m/r — date shortcuts", () => {
    // The focused row (Task 1) starts due today; each shortcut re-labels its
    // rendered date badge to what the move actually produces.
    const focusedDue = (container) =>
      container.querySelector(".task-widget.focused .due")?.textContent?.trim();

    it("t re-dates the focused row to tomorrow", async () => {
      const { container } = await renderWithTasks();
      expect(focusedDue(container)).toBe("today");
      await pressKey("t");
      await waitFor(() => expect(focusedDue(container)).toBe(dueLabelFor("Tomorrow")));
      expect(dueLabelFor("Tomorrow")).toBe("tomorrow");
    });

    it("w re-dates the focused row a week out", async () => {
      const { container } = await renderWithTasks();
      await pressKey("w");
      await waitFor(() => expect(focusedDue(container)).toBe(dueLabelFor("NextWeek")));
    });

    it("m re-dates the focused row a month out", async () => {
      const { container } = await renderWithTasks();
      await pressKey("m");
      await waitFor(() => expect(focusedDue(container)).toBe(dueLabelFor("NextMonth")));
    });

    it("r clears the focused row's date (row shows 'no date')", async () => {
      const { container } = await renderWithTasks();
      await pressKey("r");
      await waitFor(() => {
        const focused = container.querySelector(".task-widget.focused");
        expect(focused.querySelector(".due")).toBeNull();
        expect(focused.querySelector(".no-due")).toHaveTextContent("no date");
      });
    });
  });

  describe("Tab — no tree-editing gesture in the list (#86)", () => {
    it("Tab leaves every task a top-level row (no indent, no nesting)", async () => {
      // The main list is flat and top-level only; there are no tree-editing
      // gestures. Subtasks are created solely from the detail panel, so Tab
      // must leave the list exactly as it was — all three cards still rows.
      const { container } = await renderWithTasks();
      await pressKey("j"); // focus Task 2
      await pressKey("Tab");
      await new Promise((resolve) => setTimeout(resolve, 30));
      const titles = [...container.querySelectorAll(".task-widget .title")].map(el => el.textContent);
      expect(titles).toEqual(["Task 1", "Task 2", "Task 3"]);
    });

    it("Shift+Tab leaves the flat list unchanged too", async () => {
      const { container } = await renderWithTasks();
      await pressKey("Tab", { shiftKey: true });
      await new Promise((resolve) => setTimeout(resolve, 30));
      const titles = [...container.querySelectorAll(".task-widget .title")].map(el => el.textContent);
      expect(titles).toEqual(["Task 1", "Task 2", "Task 3"]);
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
    const titles = (container) =>
      [...container.querySelectorAll(".task-widget .title")].map(el => el.textContent);

    it("Alt+Down moves the focused card below its neighbor", async () => {
      const { container } = await renderWithTasks();
      expect(titles(container)).toEqual(["Task 1", "Task 2", "Task 3"]);
      await pressKey("ArrowDown", { altKey: true });
      await waitFor(() => expect(titles(container)).toEqual(["Task 2", "Task 1", "Task 3"]));
    });

    it("Alt+Up moves the focused card above its neighbor", async () => {
      const { container } = await renderWithTasks();
      await pressKey("j"); // focus Task 2
      await pressKey("ArrowUp", { altKey: true });
      await waitFor(() => expect(titles(container)).toEqual(["Task 2", "Task 1", "Task 3"]));
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
    it("does not trigger shortcuts when editing a task title", async () => {
      await renderWithTasks();
      await pressKey("e"); // enter edit mode
      await waitFor(() => expect(screen.getByDisplayValue("Task 1")).toBeInTheDocument());
      const editInput = screen.getByDisplayValue("Task 1");
      await fireEvent.keyDown(editInput, { key: "d" });
      const deleteCalls = invoke.mock.calls.filter(c => c[0] === "delete_task");
      expect(deleteCalls).toHaveLength(0);
    });
  });
});
