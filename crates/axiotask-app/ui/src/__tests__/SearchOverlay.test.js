import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import SearchOverlay from "../SearchOverlay.svelte";

const lists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent_id || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due || null,
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

  it("opens from the toolbar search button for touch users", async () => {
    mockBackend([task("t1", "Buy milk")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());

    await fireEvent.click(screen.getByRole("button", { name: /search/i }));

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

  it("GH#76: shows the correct due date in negative-UTC zones", async () => {
    // Google sends date-only due values as midnight UTC. In a zone west of
    // UTC, `new Date(due).toLocaleDateString()` shifts to the previous day.
    const originalTZ = process.env.TZ;
    process.env.TZ = "America/New_York"; // UTC-5/-4
    try {
      render(SearchOverlay, {
        props: {
          tasks: [task("t1", "Deadline task", { due: "2026-06-15T00:00:00.000Z" })],
          onselect: vi.fn(),
          onclose: vi.fn(),
        },
      });

      const input = screen.getByPlaceholderText("Search tasks...");
      await fireEvent.input(input, { target: { value: "deadline" } });

      await waitFor(() => {
        const dueEl = document.querySelector(".result-due");
        expect(dueEl).toBeTruthy();
        // The user must see June 15, not June 14.
        expect(dueEl.textContent).toBe(new Date(2026, 5, 15).toLocaleDateString());
        expect(dueEl.textContent).toContain("15");
        expect(dueEl.textContent).not.toContain("14");
      });
    } finally {
      process.env.TZ = originalTZ;
    }
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

  it("GH#77: scrolls the keyboard-selected result into view", async () => {
    // jsdom does not implement scrollIntoView; stub it so we can assert the
    // selected row is scrolled into view (mirroring TaskRow's focus behavior).
    const scrollSpy = vi.fn();
    const original = Element.prototype.scrollIntoView;
    Element.prototype.scrollIntoView = scrollSpy;
    try {
      render(SearchOverlay, {
        props: {
          tasks: [
            task("t1", "Alpha one"),
            task("t2", "Alpha two"),
            task("t3", "Alpha three"),
          ],
          onselect: vi.fn(),
          onclose: vi.fn(),
        },
      });

      const input = screen.getByPlaceholderText("Search tasks...");
      await fireEvent.input(input, { target: { value: "alpha" } });
      await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(3));

      scrollSpy.mockClear();

      // Arrowing down to a lower result must scroll that row into view.
      await fireEvent.keyDown(input, { key: "ArrowDown" });
      await fireEvent.keyDown(input, { key: "ArrowDown" });

      const rows = document.querySelectorAll(".result");
      expect(rows[2].classList.contains("selected")).toBe(true);
      expect(scrollSpy).toHaveBeenCalledWith({ block: "nearest" });
      // The last invocation must target the currently-selected row.
      const lastCallThis = scrollSpy.mock.contexts[scrollSpy.mock.contexts.length - 1];
      expect(lastCallThis).toBe(rows[2]);
    } finally {
      Element.prototype.scrollIntoView = original;
    }
  });

  it("resets selection to the first result when the query narrows results", async () => {
    render(SearchOverlay, {
      props: {
        tasks: [
          task("t1", "Alpha one"),
          task("t2", "Alpha two"),
          task("t3", "Alpha three beta"),
        ],
        onselect: vi.fn(),
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });
    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(3));

    // Move selection down to the last row.
    await fireEvent.keyDown(input, { key: "ArrowDown" });
    await fireEvent.keyDown(input, { key: "ArrowDown" });
    expect(document.querySelectorAll(".result")[2].classList.contains("selected")).toBe(true);

    // Narrow the query so the previously-selected index is out of range.
    await fireEvent.input(input, { target: { value: "beta" } });
    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(1));

    const results = document.querySelectorAll(".result");
    expect(results[0].classList.contains("selected")).toBe(true);
  });

  it("selects the sole narrowed result on Enter after selection was out of range", async () => {
    const onselect = vi.fn();
    render(SearchOverlay, {
      props: {
        tasks: [
          task("t1", "Alpha one"),
          task("t2", "Alpha two"),
          task("t3", "Alpha three beta"),
        ],
        onselect,
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });
    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(3));

    await fireEvent.keyDown(input, { key: "ArrowDown" });
    await fireEvent.keyDown(input, { key: "ArrowDown" });

    await fireEvent.input(input, { target: { value: "beta" } });
    await waitFor(() => expect(document.querySelectorAll(".result")).toHaveLength(1));

    await fireEvent.keyDown(input, { key: "Enter" });
    expect(onselect).toHaveBeenCalledTimes(1);
    expect(onselect.mock.calls[0][0].id).toBe("t3");
  });

  it("ranks open results before completed results", async () => {
    render(SearchOverlay, {
      props: {
        tasks: [
          task("done", "Alpha done", { status: "completed" }),
          task("open", "Alpha open"),
        ],
        onselect: vi.fn(),
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => {
      const titles = [...document.querySelectorAll(".result-title")].map(el => el.textContent);
      expect(titles).toEqual(["Alpha open", "Alpha done"]);
    });
  });

  it("strikes through completed search result titles", async () => {
    render(SearchOverlay, {
      props: {
        tasks: [task("done", "Alpha done", { status: "completed" })],
        onselect: vi.fn(),
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => {
      const title = screen.getByText("Alpha done");
      expect(title).toHaveClass("completed");
    });
  });

  it("marks subtask search results", async () => {
    render(SearchOverlay, {
      props: {
        tasks: [task("sub", "Alpha child", { parent_id: "parent" })],
        onselect: vi.fn(),
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => {
      expect(screen.getByText("Subtask")).toBeInTheDocument();
      expect(screen.getByText("Subtask").closest(".result")).toHaveTextContent("Alpha child");
    });
  });

  it("shows parent title for subtask search results", async () => {
    render(SearchOverlay, {
      props: {
        tasks: [
          task("parent", "Launch plan"),
          task("sub", "Alpha child", { parent_id: "parent" }),
        ],
        onselect: vi.fn(),
        onclose: vi.fn(),
      },
    });

    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });

    await waitFor(() => {
      const result = screen.getByText("Alpha child").closest(".result");
      expect(result).toHaveTextContent("Parent: Launch plan");
    });
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

  it("selecting a search result opens it without reloading every list", async () => {
    mockBackend([
      task("t1", "Work task", { listId: "L1", listTitle: "Work" }),
      task("t2", "Personal alpha", { listId: "L2", listTitle: "Personal" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Work task")).toBeInTheDocument());

    await openSearch();
    const input = screen.getByPlaceholderText("Search tasks...");
    await fireEvent.input(input, { target: { value: "alpha" } });
    await waitFor(() => expect(screen.getByText("Personal alpha")).toBeInTheDocument());
    const listCallsBeforeSelect = invoke.mock.calls.filter(([cmd]) => cmd === "list_tasks").length;

    await fireEvent.keyDown(input, { key: "Enter" });

    await waitFor(() => expect(screen.getByText("Personal alpha")).toBeInTheDocument());
    const listCallsAfterSelect = invoke.mock.calls.filter(([cmd]) => cmd === "list_tasks").length;
    expect(listCallsAfterSelect).toBe(listCallsBeforeSelect);
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
