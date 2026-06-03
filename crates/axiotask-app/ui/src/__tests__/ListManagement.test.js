import { render, screen, fireEvent, waitFor, cleanup } from "@testing-library/svelte";
import { describe, it, expect, vi, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import Sidebar from "../Sidebar.svelte";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function renderSidebar(overrides = {}) {
  return render(Sidebar, {
    props: {
      lists,
      selectedView: "focus",
      onselect: vi.fn(),
      onlogin: vi.fn(),
      onsync: vi.fn(),
      oncreateList: vi.fn(),
      onlistaction: vi.fn(),
      authenticated: true,
      syncStatus: "idle",
      lastSynced: null,
      excludedLists: [],
      counts: {},
      ...overrides,
    },
  });
}

function mockBackend() {
  let listStore = lists.map(l => ({ ...l }));
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return listStore;
      case "list_tasks": return [];
      case "create_list": {
        const l = { id: "L-new", title: args.title };
        listStore.push(l);
        return l;
      }
      case "rename_list": {
        const l = listStore.find(x => x.id === args.id);
        if (l) l.title = args.title;
        return null;
      }
      case "delete_list": {
        listStore = listStore.filter(x => x.id !== args.id);
        return null;
      }
      case "sync_now": return "pulled=0, pushed=0, conflicts=0, deleted=0";
      default: return null;
    }
  });
}

describe("GH#14: List Management", () => {
  afterEach(() => { cleanup(); });

  describe("Create list (+ button)", () => {
    it("renders + button with 'New list' title", () => {
      renderSidebar();
      const btn = screen.getByTitle("New list");
      expect(btn).toBeInTheDocument();
      expect(btn.textContent).toBe("+");
    });

    it("calls oncreateList with trimmed title from prompt", async () => {
      const oncreateList = vi.fn();
      vi.spyOn(window, "prompt").mockReturnValue("  Shopping  ");
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New list"));
      expect(oncreateList).toHaveBeenCalledWith("Shopping");
    });

    it("does not call oncreateList when prompt returns empty string", async () => {
      const oncreateList = vi.fn();
      vi.spyOn(window, "prompt").mockReturnValue("   ");
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New list"));
      expect(oncreateList).not.toHaveBeenCalled();
    });

    it("does not call oncreateList when prompt is cancelled", async () => {
      const oncreateList = vi.fn();
      vi.spyOn(window, "prompt").mockReturnValue(null);
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New list"));
      expect(oncreateList).not.toHaveBeenCalled();
    });
  });

  describe("Rename list (right-click context menu)", () => {
    it("fires onlistaction with list object and coordinates on right-click", async () => {
      const onlistaction = vi.fn();
      renderSidebar({ onlistaction });
      const workBtn = screen.getByRole("button", { name: /Work/i });
      await fireEvent.contextMenu(workBtn, { clientX: 100, clientY: 200 });
      expect(onlistaction).toHaveBeenCalledWith(
        { id: "L1", title: "Work" },
        100,
        200
      );
    });

    it("right-click on different list passes correct list object", async () => {
      const onlistaction = vi.fn();
      renderSidebar({ onlistaction });
      const personalBtn = screen.getByRole("button", { name: /Personal/i });
      await fireEvent.contextMenu(personalBtn, { clientX: 50, clientY: 150 });
      expect(onlistaction).toHaveBeenCalledWith(
        { id: "L2", title: "Personal" },
        50,
        150
      );
    });
  });

  describe("Delete list (right-click context menu)", () => {
    it("right-click triggers onlistaction enabling delete flow", async () => {
      const onlistaction = vi.fn();
      renderSidebar({ onlistaction });
      const workBtn = screen.getByRole("button", { name: /Work/i });
      await fireEvent.contextMenu(workBtn, { clientX: 10, clientY: 20 });
      expect(onlistaction).toHaveBeenCalledTimes(1);
    });
  });

  describe("Context menu prevents browser default", () => {
    it("preventDefault is called on contextmenu event", async () => {
      const onlistaction = vi.fn();
      renderSidebar({ onlistaction });
      const workBtn = screen.getByRole("button", { name: /Work/i });
      const event = new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 100,
        clientY: 200,
      });
      const prevented = !workBtn.dispatchEvent(event);
      expect(prevented).toBe(true);
    });
  });

  describe("App integration: create list", () => {
    it("creates a new list via + button and shows it in sidebar", async () => {
      mockBackend();
      const promptSpy = vi.spyOn(window, "prompt").mockReturnValue("Shopping");
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument());
      await fireEvent.click(screen.getByTitle("New list"));
      await waitFor(() => expect(screen.getByRole("button", { name: /Shopping/i })).toBeInTheDocument());
      expect(invoke).toHaveBeenCalledWith("create_list", { title: "Shopping" });
      promptSpy.mockRestore();
    });
  });

  describe("App integration: rename list via context menu", () => {
    it("renames a list after right-click → Rename", async () => {
      mockBackend();
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument());

      // Right-click to open context menu
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Work/i }), { clientX: 100, clientY: 100 });

      // Context menu should appear with Rename option
      await waitFor(() => expect(screen.getByText("Rename")).toBeInTheDocument());

      // Click Rename — it will prompt for new name
      const promptSpy = vi.spyOn(window, "prompt").mockReturnValue("Projects");
      await fireEvent.click(screen.getByText("Rename"));

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("rename_list", { id: "L1", title: "Projects" });
      });
      await waitFor(() => expect(screen.getByRole("button", { name: /Projects/i })).toBeInTheDocument());
      promptSpy.mockRestore();
    });
  });

  describe("App integration: delete list via context menu", () => {
    it("deletes a list after right-click → Delete with confirmation", async () => {
      mockBackend();
      vi.spyOn(window, "confirm").mockReturnValue(true);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument());

      // Right-click to open context menu
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Work/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Delete list")).toBeInTheDocument());

      // Click Delete — confirm dialog
      await fireEvent.click(screen.getByText("Delete list"));

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("delete_list", { id: "L1" });
      });
      await waitFor(() => expect(screen.queryByRole("button", { name: /^Work$/i })).not.toBeInTheDocument());
    });

    it("does not delete list if confirmation is cancelled", async () => {
      mockBackend();
      vi.spyOn(window, "confirm").mockReturnValue(false);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument());

      await fireEvent.contextMenu(screen.getByRole("button", { name: /Work/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Delete list")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Delete list"));

      // List should still be present — confirm was cancelled
      await waitFor(() => expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument());
    });
  });
});
