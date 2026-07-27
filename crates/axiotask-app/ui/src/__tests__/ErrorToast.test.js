import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/svelte";
import App from "../App.svelte";
import { invoke } from "@tauri-apps/api/core";

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: null,
    status: "needsAction", due: opts.due || new Date().toISOString(),
    position: opts.pos || "00001", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

function mockBackend(tasks, failCmd = null, failMsg = "Network error") {
  invoke.mockImplementation(async (cmd, args) => {
    if (cmd === failCmd) throw new Error(failMsg);
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return [{ id: "L1", title: "Work" }];
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "toggle_complete": return null;
      case "delete_task": return null;
      case "rename_task": return null;
      case "set_due": return null;
      case "sync_now": return "ok";
      case "create_task": return { id: "new-1", parent_id: null, title: args?.title || "", status: "needsAction", due: null, position: "99999", listId: args?.listId };
      default: return null;
    }
  });
}

describe("GH#23: Error feedback toast", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows red error toast when a command fails", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Network error");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast).toHaveClass("toast-error");
  });

  it("redacts an unrecognized backend error to a calm family message (#135)", async () => {
    // #135: the guard is an ALLOWLIST. "Server timeout" carries no authored
    // marker, so it is NOT passed through verbatim — the user sees a calm
    // sentence for the action they were doing, pointing at the log.
    mockBackend([task("t1", "My Task")], "toggle_complete", "Server timeout");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).not.toContain("Server timeout");
    expect(toast.textContent.toLowerCase()).toContain("save your change");
    expect(toast.textContent.toLowerCase()).toContain("log");
  });

  it("auto-dismisses error toast after 5 seconds", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Oops");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    vi.advanceTimersByTime(5000);
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
  });

  it("shows dismiss button that removes error toast on click", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Fail");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const dismissBtn = screen.getByRole("alert").querySelector(".dismiss-btn");
    expect(dismissBtn).toBeInTheDocument();
    await fireEvent.click(dismissBtn);
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
  });

  it("shows a calm redacted toast for a delete_task failure (#135)", async () => {
    // An unrecognized error from delete_task is redacted, not shown verbatim.
    mockBackend([task("t1", "Delete me")], "delete_task", "Permission denied");
    render(App);
    await waitFor(() => expect(screen.getByText("Delete me")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "d" });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).not.toContain("Permission denied");
    expect(toast.textContent.toLowerCase()).toContain("log");
  });

  it("hides a raw SQL/sqlx error from the toast, showing a human message (#128)", async () => {
    // A store failure reaches the frontend as `sql: <sqlx text>`. The user must
    // never see the SQL — only a calm, actionable sentence.
    mockBackend(
      [task("t1", "My Task")],
      "toggle_complete",
      "sql: UNIQUE constraint failed: tasks.id, tasks.list_id",
    );
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).not.toMatch(/sql:/i);
    expect(toast.textContent).not.toMatch(/constraint/i);
    expect(toast.textContent).not.toMatch(/tasks\.id/i);
    // Still tells the user something happened and where the detail lives.
    expect(toast.textContent.toLowerCase()).toContain("log");
  });

  it("never renders a synthetic no-marker error raw in the toast (#135)", async () => {
    // The allowlist's whole point: a brand-new error string we never taught
    // the guard about — no SQL prefix, so the old denylist waved it through —
    // must be redacted, not leaked. Red against the denylist.
    mockBackend(
      [task("t1", "My Task")],
      "toggle_complete",
      "kaboom widget 42: the frobnicator overheated",
    );
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).not.toMatch(/kaboom/i);
    expect(toast.textContent).not.toMatch(/frobnicator/i);
    expect(toast.textContent.toLowerCase()).toContain("log");
  });

  it("never renders raw reqwest network text (with a URL) in the toast (#135)", async () => {
    // A transport failure reaches the frontend as raw reqwest text that can
    // embed the full request URL. It carries no authored marker, so it is
    // redacted to a calm sentence.
    mockBackend(
      [task("t1", "My Task")],
      "toggle_complete",
      "network: error sending request for url (https://tasks.googleapis.com/tasks/v1/lists?key=SECRET): reset",
    );
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).not.toMatch(/https:\/\//);
    expect(toast.textContent).not.toMatch(/googleapis/i);
    expect(toast.textContent).not.toMatch(/SECRET/);
    expect(toast.textContent.toLowerCase()).toContain("log");
  });

  it("still shows a deliberate validation message verbatim (#128)", async () => {
    // Non-internal messages we author (a refusal the user must understand) are
    // NOT redacted — only raw SQL/sqlx detail is.
    mockBackend(
      [task("t1", "My Task")],
      "toggle_complete",
      "cannot nest under a subtask: subtasks are one level deep",
    );
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    expect(screen.getByRole("alert").textContent).toContain(
      "cannot nest under a subtask",
    );
  });

  it("times out a hung startup command and returns control to the UI", async () => {
    invoke.mockImplementation(async (cmd) => {
      if (cmd === "auth_status") return true;
      if (cmd === "list_tasklists") return new Promise(() => {});
      return null;
    });

    render(App);

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    await vi.advanceTimersByTimeAsync(12_000);

    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    expect(screen.getByRole("alert").textContent).toContain("list_tasklists is taking too long");
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
  });
});
