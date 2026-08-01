import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// #159 — the Android hardware back button (routed through the WebView's
// history by wry) must close the topmost open surface in the precedence
//   drawer > dialog > panel > selection
// before it is allowed to background the app. We simulate a back press by
// dispatching the `popstate` event wry emits when it calls webView.goBack().

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: "needsAction", due: opts.due ?? null,
    position: opts.pos || "1", sync_state: "clean",
    listId: opts.list || "L1", listTitle: "Work",
  };
}

function mockBackend(tasks) {
  let store = [...tasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return store.filter(t => t.listId === args?.listId);
      case "get_settings":
        return {
          version: "0.1.0", instance: null, push_enabled: false,
          auto_sync_on_start: true, authenticated: true,
          scopes: ["https://www.googleapis.com/auth/tasks"],
          db_path: "/tmp/a.sqlite", config_path: "/tmp/c.toml",
          needs_reauth: false, pending_pushes: 0,
          sync: { last_synced: null, last_pulled: 0, last_pushed: 0, last_conflicts: 0, last_deleted: 0, total_syncs: 0, last_error: null },
        };
      case "delete_task": store = store.filter(t => t.id !== args.id); return null;
      default: return null;
    }
  });
}

// Simulate the Android back button: wry navigates the WebView history back,
// which fires `popstate` in the page.
function pressBack() {
  return fireEvent(window, new PopStateEvent("popstate", { state: null }));
}

// The drawer backdrop button only renders while the drawer is open.
const drawer = () => screen.queryByRole("button", { name: /close navigation/i });
const panel = () => screen.queryByPlaceholderText("Task title");
const selectionBar = () => screen.queryByRole("toolbar", { name: /bulk actions/i });
const moveDialog = () => screen.queryByRole("dialog", { name: /move to list/i });

describe("Android back button (#159)", () => {
  beforeEach(() => {
    invoke.mockReset();
    localStorage.clear();
    localStorage.setItem("axiotask:onboardingSeen", "true"); // no first-run overlay
    localStorage.setItem("axiotask:view", "L1"); // a list view so a due-less task renders
    // Clear any sentinel a previous test left in the shared jsdom history.
    history.replaceState(null, "");
  });

  it("arms a history sentinel while a surface is open so back is intercepted, not backgrounded", async () => {
    mockBackend([task("t1", "Alpha")]);
    render(App);
    await screen.findByText("Alpha");

    // Nothing open: no sentinel, so the back button falls through to the OS
    // and backgrounds the app.
    expect(history.state?.axiotaskBackSentinel).toBeFalsy();

    await fireEvent.click(screen.getByRole("button", { name: /open navigation/i }));
    // A surface is open: a sentinel is armed so the next back press is caught.
    await waitFor(() => expect(history.state?.axiotaskBackSentinel).toBe(true));
  });

  it("closes the drawer before it clears an active selection (drawer > selection)", async () => {
    mockBackend([task("t1", "Alpha")]);
    render(App);
    await screen.findByText("Alpha");

    // Select a task, then open the drawer over it.
    await fireEvent.keyDown(window, { key: "x" });
    expect(selectionBar()).toBeInTheDocument();
    await fireEvent.click(screen.getByRole("button", { name: /open navigation/i }));
    expect(drawer()).toBeInTheDocument();

    // First back closes only the drawer; the selection survives.
    await pressBack();
    await waitFor(() => expect(drawer()).not.toBeInTheDocument());
    expect(selectionBar()).toBeInTheDocument();

    // Second back clears the selection.
    await pressBack();
    await waitFor(() => expect(selectionBar()).not.toBeInTheDocument());
  });

  it("closes dialog, then panel, then selection in that order", async () => {
    mockBackend([task("t1", "Alpha")]);
    render(App);
    await screen.findByText("Alpha");

    // Selection (lowest) + panel + a move-to-list dialog (highest) all open.
    await fireEvent.keyDown(window, { key: "x" });
    expect(selectionBar()).toBeInTheDocument();
    await fireEvent.click(screen.getByText("Alpha")); // opens the detail panel
    await waitFor(() => expect(panel()).toBeInTheDocument());
    await fireEvent.click(screen.getByRole("button", { name: /^move$/i })); // bulk move picker
    await waitFor(() => expect(moveDialog()).toBeInTheDocument());

    // Back closes the dialog first; panel and selection remain.
    await pressBack();
    await waitFor(() => expect(moveDialog()).not.toBeInTheDocument());
    expect(panel()).toBeInTheDocument();
    expect(selectionBar()).toBeInTheDocument();

    // Back closes the panel next; selection remains.
    await pressBack();
    await waitFor(() => expect(panel()).not.toBeInTheDocument());
    expect(selectionBar()).toBeInTheDocument();

    // Back clears the selection last.
    await pressBack();
    await waitFor(() => expect(selectionBar()).not.toBeInTheDocument());
  });

  it("closes an open surface in a smart view (selection with no list view)", async () => {
    localStorage.setItem("axiotask:view", "focus"); // smart view, not a list
    const now = new Date(); now.setHours(0, 0, 0, 0);
    mockBackend([task("t1", "Alpha", { due: now.toISOString() })]);
    render(App);
    await screen.findByText("Alpha");

    await fireEvent.keyDown(window, { key: "x" });
    expect(selectionBar()).toBeInTheDocument();

    await pressBack();
    await waitFor(() => expect(selectionBar()).not.toBeInTheDocument());
  });

  it("with nothing open, back leaves the app untouched (it will background)", async () => {
    mockBackend([task("t1", "Alpha")]);
    render(App);
    await screen.findByText("Alpha");

    // No surface open — the handler closes nothing and the app is free to
    // background. The view must remain intact (no crash, nothing spuriously
    // opened or closed).
    await pressBack();
    expect(screen.getByText("Alpha")).toBeInTheDocument();
    expect(drawer()).not.toBeInTheDocument();
    expect(panel()).not.toBeInTheDocument();
    expect(selectionBar()).not.toBeInTheDocument();
  });
});
