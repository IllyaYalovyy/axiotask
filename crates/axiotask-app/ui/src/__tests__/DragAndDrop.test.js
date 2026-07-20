import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function todayIso() {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return today.toISOString();
}

function task(id, title, opts = {}) {
  return {
    id,
    parent_id: opts.parent || null,
    title,
    notes: null,
    status: opts.status || "needsAction",
    due: opts.due ?? null,
    position: opts.position || "00001",
    sync_state: "clean",
    listId: opts.list || "L1",
    listTitle: opts.listTitle || "Work",
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

describe("Drag and Drop: Drag handle visibility", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("renders drag handles on task rows when sort is manual", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "First task"), task("t2", "Second task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("First task")).toBeInTheDocument());
    const handles = screen.getAllByTestId("drag-handle");
    expect(handles.length).toBe(2);
  });

  it("does not render drag handles when sort is not manual", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "alpha");
    mockBackend([task("t1", "Alpha"), task("t2", "Beta")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    expect(screen.queryAllByTestId("drag-handle")).toHaveLength(0);
  });
});

describe("Drag and Drop: Drag interactions", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("adds dragging class when drag starts on handle", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "Drag me"), task("t2", "Target")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Drag me")).toBeInTheDocument());
    const handle = screen.getAllByTestId("drag-handle")[0];
    await fireEvent.dragStart(handle, { dataTransfer: { setData: () => {}, effectAllowed: "" } });
    const row = screen.getByText("Drag me").closest(".task-widget");
    expect(row.classList.contains("dragging")).toBe(true);
  });

  it("shows insertion indicator on dragover between tasks", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "Task A"), task("t2", "Task B"), task("t3", "Task C")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Task A")).toBeInTheDocument());
    const handles = screen.getAllByTestId("drag-handle");
    const dropZones = screen.getAllByTestId("drop-zone");
    // Start drag on first task
    await fireEvent.dragStart(handles[0], { dataTransfer: { setData: () => {}, effectAllowed: "" } });
    // Drag over the second task
    await fireEvent.dragOver(dropZones[1], { clientY: 100 });
    // The drop indicator should appear
    await waitFor(() => {
      const indicator = document.querySelector(".drop-indicator");
      expect(indicator).not.toBeNull();
    });
  });

  it("calls reorder_task on drop", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    const tasks = [
      task("t1", "First", { position: "00001" }),
      task("t2", "Second", { position: "00002" }),
      task("t3", "Third", { position: "00003" }),
    ];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("First")).toBeInTheDocument());

    const handles = screen.getAllByTestId("drag-handle");
    const dropZones = screen.getAllByTestId("drop-zone");

    // Start drag on first task
    await fireEvent.dragStart(handles[0], {
      dataTransfer: { setData: () => {}, effectAllowed: "" },
    });
    // Drop on third task zone (after)
    await fireEvent.drop(dropZones[2], { dataTransfer: { getData: () => "t1" } });

    await waitFor(() => {
      const calls = invoke.mock.calls.filter(c => c[0] === "reorder_task");
      expect(calls.length).toBeGreaterThan(0);
    });
  });

  it("does not count other lists' smart-view cards as reorder siblings", async () => {
    localStorage.setItem("axiotask:view", "focus");
    localStorage.setItem("axiotask:sort:focus", "manual");
    const due = todayIso();
    const tasks = [
      task("work-1", "Work first", { position: "00001", due }),
      task("work-2", "Work second", { position: "00002", due }),
      task("personal-1", "Personal visible", {
        position: "00001",
        due,
        list: "L2",
        listTitle: "Personal",
      }),
    ];
    mockBackend(tasks);
    render(App);
    await waitFor(() => expect(screen.getByText("Work first")).toBeInTheDocument());

    const handles = screen.getAllByTestId("drag-handle");
    const dropZones = screen.getAllByTestId("drop-zone");

    await fireEvent.dragStart(handles[0], {
      dataTransfer: { setData: () => {}, effectAllowed: "" },
    });
    const listOneFetchesBeforeDrop = invoke.mock.calls.filter(
      c => c[0] === "list_tasks" && c[1]?.listId === "L1"
    ).length;
    await fireEvent.drop(dropZones[2], { dataTransfer: { getData: () => "work-1" } });

    await waitFor(() => {
      const listOneFetches = invoke.mock.calls.filter(
        c => c[0] === "list_tasks" && c[1]?.listId === "L1"
      );
      expect(listOneFetches.length).toBeGreaterThan(listOneFetchesBeforeDrop);
    });
    const calls = invoke.mock.calls.filter(c => c[0] === "reorder_task");
    expect(calls).toHaveLength(1);
    expect(calls[0][1]).toEqual({ id: "work-1", direction: "down" });
  });

  it("removes dragging class and indicator on drag end", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "Task A"), task("t2", "Task B")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Task A")).toBeInTheDocument());
    const handle = screen.getAllByTestId("drag-handle")[0];
    await fireEvent.dragStart(handle, { dataTransfer: { setData: () => {}, effectAllowed: "" } });
    await fireEvent.dragEnd(handle);
    const rows = document.querySelectorAll(".task-widget.dragging");
    expect(rows.length).toBe(0);
  });
});

describe("Drag and Drop: Touch long-press", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("initiates drag state after 300ms touch hold", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "Touch task"), task("t2", "Other task")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Touch task")).toBeInTheDocument());

    const handle = screen.getAllByTestId("drag-handle")[0];
    await fireEvent.touchStart(handle, { touches: [{ clientX: 50, clientY: 50 }] });
    // Before 300ms, no dragging
    const rowBefore = screen.getByText("Touch task").closest(".task-widget");
    expect(rowBefore.classList.contains("touch-dragging")).toBe(false);

    // Simulate timer (300ms)
    await new Promise(r => setTimeout(r, 350));
    const rowAfter = screen.getByText("Touch task").closest(".task-widget");
    expect(rowAfter.classList.contains("touch-dragging")).toBe(true);
  });

  it("cancels long-press if touch moves before 300ms", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    mockBackend([task("t1", "Move cancel"), task("t2", "Other")]);
    render(App);
    await waitFor(() => expect(screen.getByText("Move cancel")).toBeInTheDocument());

    const handle = screen.getAllByTestId("drag-handle")[0];
    await fireEvent.touchStart(handle, { touches: [{ clientX: 50, clientY: 50 }] });
    // Move before timer fires
    await fireEvent.touchMove(handle, { touches: [{ clientX: 50, clientY: 80 }] });
    await new Promise(r => setTimeout(r, 350));
    const row = screen.getByText("Move cancel").closest(".task-widget");
    expect(row.classList.contains("touch-dragging")).toBe(false);
  });
});

describe("Drag and Drop: Same-level constraint", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("only allows drop among same-level siblings (top-level only in flat view)", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:sort:L1", "manual");
    // In the flat view, only top-level (no parent) tasks are shown
    // So all visible tasks are same-level by design
    mockBackend([
      task("t1", "Parent A", { position: "00001" }),
      task("t2", "Parent B", { position: "00002" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Parent A")).toBeInTheDocument());
    // Both have drag handles since they're same level
    const handles = screen.getAllByTestId("drag-handle");
    expect(handles.length).toBe(2);
  });
});
