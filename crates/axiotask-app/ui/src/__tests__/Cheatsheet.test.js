import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(lists = [], tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

const lists = [{ id: "L1", title: "Work" }];
const today = new Date().toISOString().split("T")[0] + "T00:00:00Z";
const tasks = [
  { id: "t1", parent_id: null, title: "Task 1", notes: null, status: "needsAction", due: today, position: "00000000000001", sync_state: "clean", listId: "L1", listTitle: "Work" },
];

async function renderApp() {
  mockBackend(lists, tasks);
  render(App);
  await waitFor(() => expect(screen.getByText("Task 1")).toBeInTheDocument());
}

async function openCheatsheet() {
  await renderApp();
  await fireEvent.keyDown(window, { key: "?" });
  await waitFor(() => expect(screen.getByText("Keyboard Shortcuts")).toBeInTheDocument());
}

describe("Keyboard Cheatsheet", () => {
  beforeEach(() => {
    invoke.mockReset();
  });

  describe("opening", () => {
    it("? key opens the cheatsheet overlay", async () => {
      await renderApp();
      expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
      await fireEvent.keyDown(window, { key: "?" });
      await waitFor(() => {
        expect(screen.getByText("Keyboard Shortcuts")).toBeInTheDocument();
      });
    });

    it("renders as a dialog overlay", async () => {
      await openCheatsheet();
      expect(screen.getByRole("dialog")).toBeInTheDocument();
    });
  });

  describe("categories", () => {
    it("shows Navigation category", async () => {
      await openCheatsheet();
      expect(screen.getByText("Navigation")).toBeInTheDocument();
    });

    it("shows Tasks category", async () => {
      await openCheatsheet();
      expect(screen.getByText("Tasks")).toBeInTheDocument();
    });

    it("shows Due dates category", async () => {
      await openCheatsheet();
      expect(screen.getByText("Due dates")).toBeInTheDocument();
    });

    it("shows Organize category", async () => {
      await openCheatsheet();
      expect(screen.getByText("Organize")).toBeInTheDocument();
    });

    it("shows App category", async () => {
      await openCheatsheet();
      expect(screen.getByText("App")).toBeInTheDocument();
    });
  });

  describe("dismiss on any key", () => {
    it("dismisses on Escape", async () => {
      await openCheatsheet();
      await fireEvent.keyDown(window, { key: "Escape" });
      await waitFor(() => {
        expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
      });
    });

    it("dismisses on letter key", async () => {
      await openCheatsheet();
      await fireEvent.keyDown(window, { key: "a" });
      await waitFor(() => {
        expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
      });
    });

    it("dismisses on Enter", async () => {
      await openCheatsheet();
      await fireEvent.keyDown(window, { key: "Enter" });
      await waitFor(() => {
        expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
      });
    });

    it("dismisses on Space", async () => {
      await openCheatsheet();
      await fireEvent.keyDown(window, { key: " " });
      await waitFor(() => {
        expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
      });
    });
  });

  describe("content", () => {
    it("shows navigation shortcuts", async () => {
      await openCheatsheet();
      expect(screen.getByText("Next task")).toBeInTheDocument();
      expect(screen.getByText("Previous task")).toBeInTheDocument();
    });

    it("shows action shortcuts", async () => {
      await openCheatsheet();
      expect(screen.getByText("New task")).toBeInTheDocument();
      expect(screen.getByText("Toggle complete")).toBeInTheDocument();
      expect(screen.getByText("Delete")).toBeInTheDocument();
    });

    it("shows date shortcuts", async () => {
      await openCheatsheet();
      expect(screen.getByText("Tomorrow")).toBeInTheDocument();
      expect(screen.getByText("Next week")).toBeInTheDocument();
      expect(screen.getByText("Next month")).toBeInTheDocument();
    });

    it("shows organization shortcuts", async () => {
      await openCheatsheet();
      expect(screen.getByText(/indent/i)).toBeInTheDocument();
      expect(screen.getByText(/outdent/i)).toBeInTheDocument();
    });

    it("shows hint to press any key to close", async () => {
      await openCheatsheet();
      expect(screen.getByText(/press any key to close/i)).toBeInTheDocument();
    });
  });
});
