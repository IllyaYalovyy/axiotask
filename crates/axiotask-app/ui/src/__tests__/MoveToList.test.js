import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(initialTasks = [], lists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }, { id: "L3", title: "Shopping" }]) {
  let taskStore = [...initialTasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "move_to_list": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.listId = args.targetListId;
        return null;
      }
      case "delete_task": { taskStore = taskStore.filter(x => x.id !== args.id); return { id: args.id, list_id: "L1", title: "x" }; }
      case "create_task": {
        const t = { id: `t-new`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: "00001", sync_state: "clean", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function task(id, title, listId = "L1") {
  return {
    id, parent_id: null, title, notes: null,
    status: "needsAction", due: new Date().toISOString(),
    position: "00001", sync_state: "clean", listId, listTitle: listId === "L1" ? "Work" : "Personal",
  };
}

describe("GH#16: Move task between lists", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  describe("Ctrl+M keyboard shortcut", () => {
    it("opens move-to-list picker when Ctrl+M is pressed with a focused task", async () => {
      mockBackend([task("t1", "Move me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Move me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "m", ctrlKey: true });
      await waitFor(() => expect(screen.getByRole("dialog", { name: /move to list/i })).toBeInTheDocument());
    });

    it("picker shows all available lists except the current one", async () => {
      mockBackend([task("t1", "Move me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Move me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "m", ctrlKey: true });
      const dialog = await waitFor(() => screen.getByRole("dialog", { name: /move to list/i }));
      // Should show Personal and Shopping but not Work (current list)
      expect(dialog.textContent).toContain("Personal");
      expect(dialog.textContent).toContain("Shopping");
      expect(dialog.textContent).not.toContain("Work");
    });

    it("selecting a list calls move_to_list and closes picker", async () => {
      mockBackend([task("t1", "Move me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Move me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "m", ctrlKey: true });
      const dialog = await waitFor(() => screen.getByRole("dialog", { name: /move to list/i }));
      const personalOption = [...dialog.querySelectorAll(".list-option")].find(el => el.textContent === "Personal");
      await fireEvent.click(personalOption);
      expect(invoke).toHaveBeenCalledWith("move_to_list", { id: "t1", targetListId: "L2" });
      await waitFor(() => expect(screen.queryByRole("dialog", { name: /move to list/i })).not.toBeInTheDocument());
    });

    it("Escape closes the picker without moving", async () => {
      mockBackend([task("t1", "Stay here")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Stay here")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "m", ctrlKey: true });
      await waitFor(() => expect(screen.getByRole("dialog", { name: /move to list/i })).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "Escape" });
      await waitFor(() => expect(screen.queryByRole("dialog", { name: /move to list/i })).not.toBeInTheDocument());
    });
  });

  describe("Toast confirmation", () => {
    it("shows toast after moving task via Ctrl+M", async () => {
      mockBackend([task("t1", "Move me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Move me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: "m", ctrlKey: true });
      const dialog = await waitFor(() => screen.getByRole("dialog", { name: /move to list/i }));
      const personalOption = [...dialog.querySelectorAll(".list-option")].find(el => el.textContent === "Personal");
      await fireEvent.click(personalOption);
      await waitFor(() => expect(screen.getByText(/Moved "Move me" to Personal/)).toBeInTheDocument());
    });

    it("shows toast after moving task via context menu", async () => {
      mockBackend([task("t1", "Ctx move")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Ctx move")).toBeInTheDocument());
      const widget = container.querySelector(".task-widget");
      await fireEvent.contextMenu(widget);
      await waitFor(() => expect(screen.getByText("Move to list")).toBeInTheDocument());
      // Hover to open submenu
      const moveItem = screen.getByText("Move to list").closest(".menu-item");
      await fireEvent.mouseEnter(moveItem);
      // Find "Personal" inside the context menu's submenu
      const ctxMenu = container.querySelector(".context-menu");
      await waitFor(() => {
        const submenu = ctxMenu.querySelector(".submenu");
        expect(submenu).not.toBeNull();
      });
      const submenu = ctxMenu.querySelector(".submenu");
      const personalItem = [...submenu.querySelectorAll(".menu-item")].find(el => el.textContent.trim() === "Personal");
      await fireEvent.click(personalItem);
      await waitFor(() => expect(screen.getByText(/Moved "Ctx move" to Personal/)).toBeInTheDocument());
    });
  });

  describe("Context menu submenu", () => {
    it("context menu has Move to list submenu with available lists", async () => {
      mockBackend([task("t1", "Task one")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Task one")).toBeInTheDocument());
      const widget = container.querySelector(".task-widget");
      await fireEvent.contextMenu(widget);
      await waitFor(() => expect(screen.getByText("Move to list")).toBeInTheDocument());
    });

    it("clicking a list in submenu calls move_to_list", async () => {
      mockBackend([task("t1", "Sub move")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Sub move")).toBeInTheDocument());
      const widget = container.querySelector(".task-widget");
      await fireEvent.contextMenu(widget);
      await waitFor(() => expect(screen.getByText("Move to list")).toBeInTheDocument());
      const moveItem = screen.getByText("Move to list").closest(".menu-item");
      await fireEvent.mouseEnter(moveItem);
      const ctxMenu = container.querySelector(".context-menu");
      await waitFor(() => {
        const submenu = ctxMenu.querySelector(".submenu");
        expect(submenu).not.toBeNull();
      });
      const submenu = ctxMenu.querySelector(".submenu");
      const personalItem = [...submenu.querySelectorAll(".menu-item")].find(el => el.textContent.trim() === "Personal");
      await fireEvent.click(personalItem);
      expect(invoke).toHaveBeenCalledWith("move_to_list", { id: "t1", targetListId: "L2" });
    });
  });
});
