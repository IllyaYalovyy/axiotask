import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Work" }];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: null,
    status: opts.status || "needsAction", due: opts.due ?? null,
    position: opts.position || "00001", sync_state: "clean",
    listId: "L1", listTitle: "Work",
  };
}

function mockBackend(tasks) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "sync_now": return "ok";
      case "reorder_task": return null;
      default: return null;
    }
  });
}

describe("Sort: Dropdown and modes", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("defaults to 'My order' sort", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Alpha")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    expect(screen.getByText(/Sort:.*My order/)).toBeInTheDocument();
  });

  it("shows sort options when dropdown is clicked", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "A task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("A task")).toBeInTheDocument());
    const dropdown = screen.getByText(/Sort:.*My order/);
    await fireEvent.click(dropdown);
    expect(screen.getByText(/Due date/)).toBeInTheDocument();
    expect(screen.getByText(/Alphabetical/)).toBeInTheDocument();
    expect(screen.getByText(/Reverse my order/)).toBeInTheDocument();
  });

  it("sorts by due date — earliest first, no-date last", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "due");
    const tasks = [
      task("t1", "No date", { position: "00001" }),
      task("t2", "Later", { due: "2026-06-10T00:00:00Z", position: "00002" }),
      task("t3", "Sooner", { due: "2026-06-05T00:00:00Z", position: "00003" }),
    ];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("Sooner")).toBeInTheDocument());
    const rows = screen.getAllByText(/Sooner|Later|No date/);
    expect(rows[0].textContent).toContain("Sooner");
    expect(rows[1].textContent).toContain("Later");
    expect(rows[2].textContent).toContain("No date");
  });

  it("sorts alphabetically A-Z", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "alpha");
    const tasks = [
      task("t1", "Cherry", { position: "00001" }),
      task("t2", "Apple", { position: "00002" }),
      task("t3", "Banana", { position: "00003" }),
    ];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("Apple")).toBeInTheDocument());
    const rows = screen.getAllByText(/Apple|Banana|Cherry/);
    expect(rows[0].textContent).toContain("Apple");
    expect(rows[1].textContent).toContain("Banana");
    expect(rows[2].textContent).toContain("Cherry");
  });

  it("sorts by reverse manual order — highest position first", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "created");
    const tasks = [
      task("t1", "OldItem", { position: "00001" }),
      task("t2", "MiddleItem", { position: "00005" }),
      task("t3", "NewestItem", { position: "00009" }),
    ];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("NewestItem")).toBeInTheDocument());
    const rows = screen.getAllByText(/OldItem|MiddleItem|NewestItem/);
    expect(rows[0].textContent).toContain("NewestItem");
    expect(rows[1].textContent).toContain("MiddleItem");
    expect(rows[2].textContent).toContain("OldItem");
  });
});

describe("Sort: Completed at bottom", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("moves completed tasks below open tasks regardless of sort", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    const tasks = [
      task("t1", "Done first", { status: "completed", position: "00001" }),
      task("t2", "Open second", { position: "00002" }),
      task("t3", "Open third", { position: "00003" }),
    ];
    mockBackend(tasks);
    render(App);
    // Need showCompleted to see completed tasks
    await waitFor(() => expect(screen.getByText("Open second")).toBeInTheDocument());
    const toggle = screen.getByLabelText(/show completed/i);
    await fireEvent.click(toggle);
    await waitFor(() => expect(screen.getByText("Done first")).toBeInTheDocument());
    const rows = screen.getAllByText(/Done first|Open second|Open third/);
    expect(rows[0].textContent).toContain("Open second");
    expect(rows[1].textContent).toContain("Open third");
    expect(rows[2].textContent).toContain("Done first");
  });
});

describe("Sort: Per-view persistence", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("persists sort mode per view in localStorage", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "A task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("A task")).toBeInTheDocument());
    // Click sort dropdown and select "Due date"
    const dropdown = screen.getByText(/Sort:.*My order/);
    await fireEvent.click(dropdown);
    const dueOption = screen.getByText(/Due date/);
    await fireEvent.click(dueOption);
    expect(localStorage.getItem("axiotask:sort:L1")).toBe("due");
  });

  it("restores sort mode from localStorage on view switch", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "alpha");
    mockBackend([task("t1", "Zulu"), task("t2", "Alpha")]);
    render(App);
    await waitFor(() => expect(screen.getByText(/Sort:.*Alphabetical/)).toBeInTheDocument());
  });
});

describe("Sort: Reorder disabled when sort≠manual", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("shows reorder disabled notice when sort is not manual", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "due");
    mockBackend([task("t1", "A task", { due: "2026-06-05T00:00:00Z" })]);
    render(App);
    await waitFor(() => expect(screen.getByText("A task")).toBeInTheDocument());
    expect(screen.getByText(/Reorder disabled/)).toBeInTheDocument();
  });

  it("does not show reorder disabled notice in manual mode", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "A task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("A task")).toBeInTheDocument());
    expect(screen.queryByText(/Reorder disabled/)).not.toBeInTheDocument();
  });

  it("Alt+↓ does not reorder when sort is not manual", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "alpha");
    const tasks = [task("t1", "Alpha"), task("t2", "Beta")];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    await fireEvent.keyDown(window, { key: "ArrowDown", altKey: true });
    // reorder_task should NOT have been called
    const calls = invoke.mock.calls.filter(c => c[0] === "reorder_task");
    expect(calls).toHaveLength(0);
  });
});
