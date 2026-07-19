import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// Behavior of the keyboard cheatsheet overlay: it opens on `?`, is a dialog,
// renders its shortcut content, and closes on any key. We intentionally do NOT
// assert every category/label — that's brittle copy-testing, and the source of
// truth for the shortcut list is the component itself.

function mockBackend(lists = [], tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
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
  beforeEach(() => { invoke.mockReset(); });

  it("opens on `?` and renders shortcut content", async () => {
    await renderApp();
    expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument();
    await fireEvent.keyDown(window, { key: "?" });
    await waitFor(() => expect(screen.getByText("Keyboard Shortcuts")).toBeInTheDocument());
    // Not empty: at least one real shortcut is listed.
    expect(screen.getByText("New task")).toBeInTheDocument();
  });

  it("renders as a dialog overlay", async () => {
    await openCheatsheet();
    expect(screen.getByRole("dialog")).toBeInTheDocument();
  });

  it("closes on Escape", async () => {
    await openCheatsheet();
    await fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument());
  });

  it("closes on any other key too", async () => {
    await openCheatsheet();
    await fireEvent.keyDown(window, { key: "a" });
    await waitFor(() => expect(screen.queryByText("Keyboard Shortcuts")).not.toBeInTheDocument());
  });

  it("shows first-launch onboarding once when the workspace is empty", async () => {
    localStorage.clear();
    mockBackend([], []);
    render(App);

    await waitFor(() => expect(screen.getByRole("dialog", { name: /welcome to axiotask/i })).toBeInTheDocument());
    expect(screen.getByText(/Press n or use the quick-add field/i)).toBeInTheDocument();

    await fireEvent.click(screen.getByRole("button", { name: /start using axiotask/i }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: /welcome to axiotask/i })).not.toBeInTheDocument());
    expect(localStorage.getItem("axiotask:onboardingSeen")).toBe("true");
  });
});
