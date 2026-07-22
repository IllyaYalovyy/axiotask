import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import { formatDue } from "../dateFormat.js";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

const today = new Date().toISOString().split("T")[0] + "T00:00:00Z";

function localDate(offsetDays = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function task(id, title, listId = "L1", due = today) {
  return {
    id,
    parent_id: null,
    title,
    notes: null,
    status: "needsAction",
    due,
    position: id,
    sync_state: "clean",
    listId,
    listTitle: lists.find(l => l.id === listId)?.title || "",
  };
}

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const created = task(`new-${nextId++}`, args.title, args.listId, null);
        created.parent_id = args.parentId || null;
        taskStore.unshift(created);
        return created;
      }
      case "set_due": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.due = args.mv.startsWith("raw:") ? args.mv.slice(4) + "T00:00:00Z" : null;
        return null;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("Quick-add input", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("is always visible and creates a titled task without switching away from the current smart view", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([task("t1", "Due today")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Due today")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Capture follow-up" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "create_task",
        expect.objectContaining({ listId: "L1", parentId: null, title: "Capture follow-up" }),
      );
    });
    await waitFor(() => expect(input).toHaveValue(""));
    expect(document.querySelector(".view-title")).toHaveTextContent("Focus");
  });

  it("a task quick-added from Focus is VISIBLE in Focus (due date pre-filled, no view switch)", async () => {
    // The failure mode this pins down: an undated task created from a smart
    // view lands in the default list and silently vanishes — the user types,
    // hits Enter, the input clears, and nothing appears anywhere they look.
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([task("t1", "Due today")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Due today")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Visible immediately" } });
    await fireEvent.submit(input.closest("form"));

    // Still in Focus, and the new task is rendered there.
    await waitFor(() => expect(screen.getByText("Visible immediately")).toBeInTheDocument());
    expect(document.querySelector(".view-title")).toHaveTextContent("Focus");
    // It was made visible by dating it today, not by switching views.
    const dueCall = invoke.mock.calls.find((c) => c[0] === "set_due");
    expect(dueCall?.[1]?.mv).toMatch(/^raw:\d{4}-\d{2}-\d{2}$/);
  });

  it("toasts that a task quick-added from Missed was added to Focus", async () => {
    localStorage.setItem("axiotask:view", "missed");
    mockBackend([task("t1", "Overdue", "L1", `${localDate(-1)}T00:00:00Z`)]);
    render(App);
    await waitFor(() => expect(screen.getByText("Overdue")).toBeInTheDocument());

    const input = screen.getByRole("textbox", { name: /quick add task/i });
    await fireEvent.input(input, { target: { value: "Call vendor" } });
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(screen.getByText('Added "Call vendor" to Focus')).toBeInTheDocument();
    });
    expect(document.querySelector(".view-title")).toHaveTextContent("Missed");
  });

  it("does not create an empty task when submitted blank", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "   " } });
    await fireEvent.submit(input.closest("form"));

    await new Promise(resolve => setTimeout(resolve, 50));
    expect(invoke.mock.calls.filter(call => call[0] === "create_task")).toHaveLength(0);
    expect(input).toHaveValue("   ");
  });

  it("previews a trailing natural-language due date and preserves the typed title", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "Send invoice tomorrow" } });
    // Chip renders the friendly relative form, not the raw ISO date (#78b).
    expect(screen.getByText("Due tomorrow")).toBeInTheDocument();
    expect(screen.queryByText(`Due ${localDate(1)}`)).not.toBeInTheDocument();
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "create_task",
        expect.objectContaining({ listId: "L1", title: "Send invoice tomorrow" }),
      );
    });
    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "set_due",
        expect.objectContaining({ mv: `raw:${localDate(1)}` }),
      );
    });
  });

  it("can keep the parsed date phrase as title text without applying a due date", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "Discuss tomorrow" } });
    await fireEvent.click(screen.getByRole("button", { name: /keep date text in title/i }));
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "create_task",
        expect.objectContaining({ title: "Discuss tomorrow" }),
      );
    });
    expect(invoke.mock.calls.filter(call => call[0] === "set_due")).toHaveLength(0);
  });

  it("previews and applies explicit YYYY-MM-DD quick-add dates without rewriting the title", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "Book dentist on 2026-08-03" } });
    // The chip shows the friendly form; the raw ISO still flows to set_due.
    expect(screen.getByText(`Due ${formatDue("2026-08-03")}`)).toBeInTheDocument();
    expect(screen.queryByText("Due 2026-08-03")).not.toBeInTheDocument();
    await fireEvent.submit(input.closest("form"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith(
        "create_task",
        expect.objectContaining({ title: "Book dentist on 2026-08-03" }),
      );
    });
    expect(invoke).toHaveBeenCalledWith("set_due", expect.objectContaining({ mv: "raw:2026-08-03" }));
  });

  it("renders the preview chip as a friendly relative date, never the raw ISO (#78b)", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend();
    render(App);
    const input = await screen.findByRole("textbox", { name: /quick add task/i });

    await fireEvent.input(input, { target: { value: "Water plants today" } });
    // "today" is its own formatDue branch — the chip must read "Due today",
    // not the raw ISO the value carries into set_due.
    const chip = await screen.findByRole("status");
    expect(chip).toHaveTextContent("Due today");
    expect(chip).not.toHaveTextContent(localDate(0));
  });
});
