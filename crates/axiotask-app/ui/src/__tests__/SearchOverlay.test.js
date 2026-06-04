import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }];

function task(id, title, opts = {}) {
  return {
    id, parent_id: null, title, notes: opts.notes || null,
    status: "needsAction", due: opts.due || null,
    position: "00001", sync_state: "clean",
    listId: opts.listId || "L1", listTitle: opts.listTitle || "Work",
  };
}

function mockBackend(tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "create_task": return { id: "new-1", ...args };
      case "toggle_complete": return null;
      case "delete_task": return null;
      case "rename_task": return null;
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      case "move_to_list": return null;
      default: return null;
    }
  });
}

async function openSearch() {
  await fireEvent.keyDown(document, { key: "/" });
}

describe("GH#17: Search overlay", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  it("opens when / key is pressed", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await openSearch();
    expect(screen.getByPlaceholderText("Search tasks...")).toBeInTheDocument();
  });

  it("closes on Escape", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    expect(input).toBeInTheDocument();

    await fireEvent.keyDown(input, { key: "Escape" });
    expect(screen.queryByPlaceholderText("Search tasks...")).not.toBeInTheDocument();
  });

  it("filters tasks by title", async () => {
    mockBackend([
      task("t1", "Buy milk"),
      task("t2", "Write report"),
      task("t3", "Buy eggs"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "buy" } });

    await waitFor(() => {
      const results = document.querySelectorAll(".result-title");
      const titles = [...results].map(el => el.textContent);
      expect(titles).toContain("Buy milk");
      expect(titles).toContain("Buy eggs");
      expect(titles).not.toContain("Write report");
    });
  });

  it("filters tasks by notes content", async () => {
    mockBackend([
      task("t1", "Meeting", { notes: "discuss budget" }),
      task("t2", "Lunch"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Meeting")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "budget" } });

    await waitFor(() => {
      const results = document.querySelectorAll(".result-title");
      expect(results).toHaveLength(1);
      expect(results[0].textContent).toBe("Meeting");
    });
  });

  it("shows list tag for each result", async () => {
    mockBackend([task("t1", "Buy milk", { listId: "L2", listTitle: "Personal" })]);
    render(App);
    await waitFor(() => expect(screen.queryByText("Loading...")).not.toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "milk" } });

    await waitFor(() => {
      expect(document.querySelector(".result-list").textContent).toBe("Personal");
    });
  });

  it("shows due date for each result", async () => {
    const due = "2026-06-15T12:00:00Z";
    mockBackend([task("t1", "Deadline task", { due })]);
    render(App);
    await waitFor(() => expect(screen.queryByText("Loading...")).not.toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "deadline" } });

    await waitFor(() => {
      const dueEl = document.querySelector(".result-due");
      expect(dueEl).toBeTruthy();
      // Verify the due element contains a date string (locale-dependent)
      expect(dueEl.textContent).toMatch(/\d+\/\d+\/\d+/);
    });
  });

  it("supports arrow key navigation", async () => {
    mockBackend([
      task("t1", "Alpha task"),
      task("t2", "Alpha beta"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha task")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(2));

    // First item is selected by default
    expect(document.querySelectorAll(".result")[0].classList.contains("selected")).toBe(true);

    // ArrowDown moves selection
    await fireEvent.keyDown(input, { key: "ArrowDown" });
    expect(document.querySelectorAll(".result")[1].classList.contains("selected")).toBe(true);

    // ArrowUp moves back
    await fireEvent.keyDown(input, { key: "ArrowUp" });
    expect(document.querySelectorAll(".result")[0].classList.contains("selected")).toBe(true);
  });

  it("selects task on Enter and closes overlay", async () => {
    mockBackend([
      task("t1", "Alpha task"),
      task("t2", "Alpha beta"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha task")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(2));

    // Enter selects first result and closes
    await fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => {
      expect(screen.queryByPlaceholderText("Search tasks...")).not.toBeInTheDocument();
    });
  });

  it("shows 'No tasks found' when no matches", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "zzzzz" } });

    await waitFor(() => {
      expect(screen.getByText("No tasks found")).toBeInTheDocument();
    });
  });

  it("closes when clicking overlay backdrop", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await openSearch();
    expect(screen.getByPlaceholderText("Search tasks...")).toBeInTheDocument();

    const overlay = document.querySelector(".search-overlay");
    await fireEvent.click(overlay);
    expect(screen.queryByPlaceholderText("Search tasks...")).not.toBeInTheDocument();
  });

  it("does not open when input field is focused", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    // Enter edit mode on the task
    await fireEvent.keyDown(window, { key: "e" });
    await waitFor(() => expect(screen.getByDisplayValue("Buy milk")).toBeInTheDocument());
    const editInput = screen.getByDisplayValue("Buy milk");
    await fireEvent.keyDown(editInput, { key: "/" });

    // Search should NOT open since we're in an input
    expect(screen.queryByPlaceholderText("Search tasks...")).not.toBeInTheDocument();
  });
});
