import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Work" }, { id: "L2", title: "Personal" }];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: null,
    status: opts.status || "needsAction", due: opts.due ?? null,
    position: opts.position || "00001", sync_state: "clean",
    listId: opts.listId || "L1", listTitle: opts.listTitle || "Work",
  };
}

function mockBackend(tasks = []) {
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

describe("UI State Persistence: showCompleted", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("defaults showCompleted to false when no saved value", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([
      task("t1", "Open task"),
      task("t2", "Done task", { status: "completed" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
    expect(screen.queryByText("Done task")).not.toBeInTheDocument();
  });

  it("restores showCompleted=true from localStorage", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:showCompleted", "true");
    mockBackend([
      task("t1", "Open task"),
      task("t2", "Done task", { status: "completed" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
    expect(screen.getByText("Done task")).toBeInTheDocument();
  });

  it("persists showCompleted to localStorage when toggled", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([
      task("t1", "Open task"),
      task("t2", "Done task", { status: "completed" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
    const checkbox = screen.getByLabelText(/show completed/i);
    await fireEvent.click(checkbox);
    expect(localStorage.getItem("axiotask:showCompleted")).toBe("true");
    await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
  });

  it("persists showCompleted=false when unchecked", async () => {
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:showCompleted", "true");
    mockBackend([
      task("t1", "Open task"),
      task("t2", "Done task", { status: "completed" }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
    const checkbox = screen.getByLabelText(/show completed/i);
    await fireEvent.click(checkbox);
    expect(localStorage.getItem("axiotask:showCompleted")).toBe("false");
  });
});

describe("UI State Persistence: window size and position", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("saves window geometry to localStorage on beforeunload", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([task("t1", "Task")]);

    // Mock getCurrentWindow to return size/position
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    const win = getCurrentWindow();
    win.outerSize = vi.fn().mockResolvedValue({ width: 1024, height: 768 });
    win.outerPosition = vi.fn().mockResolvedValue({ x: 100, y: 50 });

    render(App);
    await waitFor(() => expect(screen.getByText("Task")).toBeInTheDocument());

    // Trigger beforeunload
    window.dispatchEvent(new Event("beforeunload"));

    await waitFor(() => {
      const saved = JSON.parse(localStorage.getItem("axiotask:windowGeometry") || "null");
      expect(saved).toEqual({ width: 1024, height: 768, x: 100, y: 50 });
    });
  });

  it("does NOT resize/move the window on mount, even with a saved geometry", async () => {
    // Programmatic geometry restore is intentionally disabled: driving the
    // window through setSize/setPosition as the webview starts up wedged
    // WebKitGTK's IPC and left the app stuck forever on "Loading...". The saved
    // geometry must be ignored on startup and the app must still render.
    localStorage.setItem("axiotask:view", "L1");
    localStorage.setItem("axiotask:windowGeometry", JSON.stringify({ width: 800, height: 600, x: 200, y: 150 }));
    mockBackend([task("t1", "Task")]);

    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    const win = getCurrentWindow();
    win.setSize = vi.fn().mockResolvedValue(undefined);
    win.setPosition = vi.fn().mockResolvedValue(undefined);

    render(App);
    await waitFor(() => expect(screen.getByText("Task")).toBeInTheDocument());

    expect(win.setSize).not.toHaveBeenCalled();
    expect(win.setPosition).not.toHaveBeenCalled();
  });
});
