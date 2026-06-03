import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(initialTasks = [], initialLists = null) {
  const lists = initialLists || [
    { id: "L1", title: "Work" },
    { id: "L2", title: "Personal" },
  ];
  let taskStore = [...initialTasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "delete_task": {
        const t = taskStore.find(x => x.id === args.id);
        const token = t ? { id: t.id, list_id: t.listId, parent_id: t.parent_id, title: t.title, notes: t.notes, status: t.status, due: t.due, position: t.position, had_etag: true } : null;
        taskStore = taskStore.filter(x => x.id !== args.id);
        return token;
      }
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title || "Work" };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "move_to_list": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { taskStore };
}

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due || null,
    position: opts.pos || "00001", sync_state: "clean", listId: opts.listId || "L1", listTitle: opts.listTitle || "Work",
  };
}

async function openContextMenu(container) {
  const widget = container.querySelector(".task-widget");
  await fireEvent.contextMenu(widget);
  await waitFor(() => expect(container.querySelector(".context-menu")).toBeInTheDocument());
}

describe("GH#19: Custom context menu", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  describe("Right-click shows menu with all items", () => {
    it("shows context menu on right-click", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(container.querySelector(".context-menu")).toBeInTheDocument();
    });

    it("displays Edit title option", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Edit title")).toBeInTheDocument();
    });

    it("displays Edit notes option", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Edit notes")).toBeInTheDocument();
    });

    it("displays Set due date submenu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Set due date")).toBeInTheDocument();
    });

    it("displays Move to list submenu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Move to list")).toBeInTheDocument();
    });

    it("displays Add subtask option", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Add subtask")).toBeInTheDocument();
    });

    it("displays Duplicate option", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Duplicate")).toBeInTheDocument();
    });

    it("displays Delete option", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      expect(screen.getByText("Delete")).toBeInTheDocument();
    });
  });

  describe("Due date submenu", () => {
    it("expands due submenu showing date options", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const dueItem = screen.getByText("Set due date").closest(".menu-item");
      await fireEvent.click(dueItem);
      await waitFor(() => {
        expect(screen.getByText("Today")).toBeInTheDocument();
        expect(screen.getByText("Tomorrow")).toBeInTheDocument();
        expect(screen.getByText("Next week")).toBeInTheDocument();
        expect(screen.getByText("Next month")).toBeInTheDocument();
        expect(screen.getByText("Clear")).toBeInTheDocument();
      });
    });

    it("clicking Tomorrow calls set_due", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const dueItem = screen.getByText("Set due date").closest(".menu-item");
      await fireEvent.click(dueItem);
      const submenu = container.querySelector(".submenu");
      await waitFor(() => expect(submenu).toBeInTheDocument());
      const tomorrowItem = [...submenu.querySelectorAll(".menu-item")].find(el => el.textContent.includes("Tomorrow"));
      await fireEvent.click(tomorrowItem);
      expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Tomorrow" });
    });
  });

  describe("Move to list submenu", () => {
    it("expands move submenu showing available lists", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const moveItem = screen.getByText("Move to list").closest(".menu-item");
      await fireEvent.click(moveItem);
      const submenu = container.querySelector(".context-menu .submenu");
      await waitFor(() => {
        expect(submenu).toBeInTheDocument();
        const labels = [...submenu.querySelectorAll(".menu-item")].map(el => el.textContent.trim());
        expect(labels).toContain("Personal");
      });
    });

    it("clicking a list in Move submenu calls move_task", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const moveItem = screen.getByText("Move to list").closest(".menu-item");
      await fireEvent.click(moveItem);
      const submenu = container.querySelector(".context-menu .submenu");
      await waitFor(() => expect(submenu).toBeInTheDocument());
      const personalItem = [...submenu.querySelectorAll(".menu-item")].find(el => el.textContent.includes("Personal"));
      await fireEvent.click(personalItem);
      expect(invoke).toHaveBeenCalledWith("move_to_list", { id: "t1", targetListId: "L2" });
    });
  });

  describe("Add subtask", () => {
    it("clicking Add subtask creates a child task", async () => {
      mockBackend([task("t1", "Parent task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());
      await openContextMenu(container);
      await fireEvent.click(screen.getByText("Add subtask"));
      expect(invoke).toHaveBeenCalledWith("create_task", { listId: "L1", parentId: "t1", title: "" });
    });
  });

  describe("Duplicate", () => {
    it("clicking Duplicate creates a copy of the task", async () => {
      mockBackend([task("t1", "Original task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Original task")).toBeInTheDocument());
      await openContextMenu(container);
      await fireEvent.click(screen.getByText("Duplicate"));
      expect(invoke).toHaveBeenCalledWith("create_task", { listId: "L1", parentId: null, title: "Original task (copy)" });
    });
  });

  describe("Keyboard navigation", () => {
    it("ArrowDown moves focus to next item", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      // First item (Edit title) is focused by default (focusIdx=0)
      await fireEvent.keyDown(menu, { key: "ArrowDown" });
      // Second item (Edit notes) should be focused
      const items = container.querySelectorAll(".menu-item");
      const actionItems = [...items].filter(el => !el.closest(".submenu"));
      expect(actionItems[1]).toHaveClass("focused");
    });

    it("ArrowUp wraps to last item from first", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      await fireEvent.keyDown(menu, { key: "ArrowUp" });
      // Should wrap to last item (Delete)
      const items = container.querySelectorAll(".context-menu > .menu-item");
      const lastItem = items[items.length - 1];
      expect(lastItem).toHaveClass("focused");
    });

    it("Enter triggers focused action", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      // focusIdx=0 = "Edit title" - pressing Enter should trigger edit mode
      await fireEvent.keyDown(menu, { key: "Enter" });
      // Menu should close and edit mode should activate
      await waitFor(() => expect(container.querySelector(".context-menu")).not.toBeInTheDocument());
    });

    it("ArrowRight opens submenu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      // Navigate to "Set due date" (3rd action item after Edit title, Edit notes)
      await fireEvent.keyDown(menu, { key: "ArrowDown" });
      await fireEvent.keyDown(menu, { key: "ArrowDown" });
      await fireEvent.keyDown(menu, { key: "ArrowRight" });
      await waitFor(() => expect(screen.getByText("Tomorrow")).toBeInTheDocument());
    });

    it("ArrowLeft closes submenu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      await fireEvent.keyDown(menu, { key: "ArrowDown" });
      await fireEvent.keyDown(menu, { key: "ArrowDown" });
      await fireEvent.keyDown(menu, { key: "ArrowRight" });
      await waitFor(() => expect(screen.getByText("Tomorrow")).toBeInTheDocument());
      await fireEvent.keyDown(menu, { key: "ArrowLeft" });
      // Submenu items should be gone from inline display
      await waitFor(() => expect(container.querySelector(".submenu")).not.toBeInTheDocument());
    });
  });

  describe("Dismiss behavior", () => {
    it("Escape closes the context menu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      const menu = container.querySelector(".context-menu");
      await fireEvent.keyDown(menu, { key: "Escape" });
      await waitFor(() => expect(container.querySelector(".context-menu")).not.toBeInTheDocument());
    });

    it("clicking outside closes the context menu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      // Click on the body (outside the menu)
      await fireEvent.click(document.body);
      await waitFor(() => expect(container.querySelector(".context-menu")).not.toBeInTheDocument());
    });

    it("selecting an action closes the menu", async () => {
      mockBackend([task("t1", "Test task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Test task")).toBeInTheDocument());
      await openContextMenu(container);
      await fireEvent.click(screen.getByText("Delete"));
      await waitFor(() => expect(container.querySelector(".context-menu")).not.toBeInTheDocument());
    });
  });

  describe("Edit title via context menu", () => {
    it("clicking Edit title enters edit mode on the task", async () => {
      mockBackend([task("t1", "Editable task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Editable task")).toBeInTheDocument());
      await openContextMenu(container);
      await fireEvent.click(screen.getByText("Edit title"));
      await waitFor(() => expect(container.querySelector(".edit-input")).toBeInTheDocument());
    });
  });

  describe("Delete via context menu", () => {
    it("clicking Delete removes the task", async () => {
      mockBackend([task("t1", "Doomed task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Doomed task")).toBeInTheDocument());
      await openContextMenu(container);
      await fireEvent.click(screen.getByText("Delete"));
      await waitFor(() => expect(screen.queryByText("Doomed task")).not.toBeInTheDocument());
    });
  });
});
