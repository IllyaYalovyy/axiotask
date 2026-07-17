import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const DAY = 86400000;
const now = new Date(); now.setHours(0, 0, 0, 0);
const iso = (n) => new Date(now.getTime() + n * DAY).toISOString();
const ymd = (n) => iso(n).slice(0, 10);

const lists = [{ id: "L1", title: "Work" }];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: null,
    status: opts.status || "needsAction", due: opts.due ?? null,
    position: opts.pos || "1", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

function mockBackend(tasks = []) {
  let store = [...tasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return store.filter((t) => t.listId === args?.listId);
      case "toggle_complete": { const t = store.find((x) => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "set_due": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("Subtask date propagation → effective date", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("a parent with no date but an unfinished subtask due soon lands in Focus (count matches)", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([
      task("p1", "Parent undated"),
      task("s1", "Sub due tomorrow", { parent: "p1", due: iso(1) }),
      task("other", "Unrelated undated"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Parent undated")).toBeInTheDocument());
    // The subtask appears as a NESTED row under its parent (expandable tree),
    // never as a standalone card; the undated unrelated task is out.
    const subRow = screen.getByText("Sub due tomorrow").closest(".task-widget");
    expect(subRow.querySelector(".tree-icon.sub")).not.toBeNull();
    expect(screen.queryByText("Unrelated undated")).not.toBeInTheDocument();
    // Badge counts the one parent card.
    expect(screen.getByText("★ Focus").closest("button")).toHaveTextContent("1");
  });

  it("the parent row shows the inherited date, marked with ↳", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([
      task("p1", "Parent undated"),
      task("s1", "Sub", { parent: "p1", due: iso(1) }),
    ]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Parent undated")).toBeInTheDocument());
    const inherited = container.querySelector(".due.inherited");
    expect(inherited).toBeTruthy();
    expect(inherited.textContent).toContain("↳");
    expect(inherited.textContent).toContain("tomorrow");
  });

  it("a completed subtask's date does NOT propagate — parent stays unscheduled", async () => {
    localStorage.setItem("axiotask:view", "unscheduled");
    mockBackend([
      task("p1", "Parent undated"),
      task("s1", "Done sub", { parent: "p1", due: iso(1), status: "completed" }),
    ]);
    render(App);
    // Parent has no effective date (only a completed subtask carried one).
    await waitFor(() => expect(screen.getByText("Parent undated")).toBeInTheDocument());
    expect(screen.getByText("○ Unscheduled").closest("button")).toHaveTextContent("1");
  });

  it("an explicit parent date LATER than the subtask still filters by the earlier effective date", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([
      task("p1", "Parent far", { due: iso(30) }),          // own date is out of Focus
      task("s1", "Sub soon", { parent: "p1", due: iso(1) }), // subtask pulls it in
    ]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Parent far")).toBeInTheDocument());
    // Effective date (tomorrow) puts it in Focus even though its own date is far off.
    expect(screen.getByText("★ Focus").closest("button")).toHaveTextContent("1");
    // It has its OWN due date, so the row shows that — no inherited (↳) marker.
    expect(container.querySelector(".due")).toBeTruthy();
    expect(container.querySelector(".due.inherited")).toBeNull();
  });

  it("unscheduled view excludes a parent whose subtask is dated", async () => {
    localStorage.setItem("axiotask:view", "unscheduled");
    mockBackend([
      task("p1", "Has dated sub"),
      task("s1", "Sub", { parent: "p1", due: iso(3) }),
      task("p2", "Truly undated"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Truly undated")).toBeInTheDocument());
    expect(screen.queryByText("Has dated sub")).not.toBeInTheDocument();
  });

  it("the detail panel shows the read-only 'From subtasks' date only when it exists", async () => {
    localStorage.setItem("axiotask:view", "L1");
    mockBackend([
      task("p1", "Parent undated"),
      task("s1", "Sub", { parent: "p1", due: iso(2) }),
      task("p2", "No subs"),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Parent undated")).toBeInTheDocument());

    // Parent WITH a dated subtask → the propagated field appears, read-only.
    await fireEvent.click(screen.getByText("Parent undated"));
    await waitFor(() => expect(screen.getByText("From subtasks")).toBeInTheDocument());
    const field = screen.getByText("From subtasks").closest(".field");
    expect(field.querySelector(".inherited-due").textContent).toContain(ymd(2).slice(5)); // month-day
    // No editable control in that field.
    expect(field.querySelector("input, button, select")).toBeNull();

    // Task WITHOUT dated subtasks → the field is absent.
    await fireEvent.click(screen.getByText("No subs"));
    await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("No subs"));
    expect(screen.queryByText("From subtasks")).not.toBeInTheDocument();
  });

  it("recursion: a grandchild's date propagates up through an unfinished middle", async () => {
    localStorage.setItem("axiotask:view", "focus");
    mockBackend([
      task("root", "Root"),
      task("mid", "Mid", { parent: "root" }),                 // undated middle
      task("leaf", "Leaf", { parent: "mid", due: iso(1) }),   // grandchild dated
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Root")).toBeInTheDocument());
    expect(screen.getByText("★ Focus").closest("button")).toHaveTextContent("1");
  });

  it("recursion: a COMPLETED middle cuts off its subtree", async () => {
    localStorage.setItem("axiotask:view", "unscheduled");
    mockBackend([
      task("root", "Root"),
      task("mid", "Mid done", { parent: "root", status: "completed" }),
      task("leaf", "Leaf", { parent: "mid", due: iso(1) }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Root")).toBeInTheDocument());
    // Root's only dated descendant sits under a completed middle → no effective date.
    expect(screen.getByText("○ Unscheduled").closest("button")).toHaveTextContent("1");
  });
});
