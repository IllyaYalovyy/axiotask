import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [{ id: "L1", title: "Inbox" }];
const tasks = [
  { id: "t1", parent_id: null, title: "Alpha", notes: null, status: "needsAction", due: null, position: "1", sync_state: "clean", listId: "L1", listTitle: "Inbox" },
];

function mockBackend() {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter((t) => t.listId === args?.listId);
      case "sync_now": return "pulled=1, pushed=0, conflicts=0, deleted=0";
      default: return null;
    }
  });
}

describe("#50: touch app interactions", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  it("mobile FAB focuses the quick-add input", async () => {
    mockBackend();
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());

    const fab = container.querySelector(".mobile-fab");
    expect(fab).toBeInTheDocument();
    await fireEvent.click(fab);

    expect(screen.getByLabelText(/quick add task/i)).toHaveFocus();
  });

  it("pulling down from the top runs a refresh sync", async () => {
    mockBackend();
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    invoke.mockClear();

    const content = container.querySelector(".content");
    await fireEvent.touchStart(content, { touches: [{ clientX: 120, clientY: 16 }] });
    await fireEvent.touchMove(content, { touches: [{ clientX: 122, clientY: 104 }] });
    await fireEvent.touchEnd(content);

    await waitFor(() => {
      expect(invoke.mock.calls.some((c) => c[0] === "sync_now")).toBe(true);
    });
  });

  it("does not refresh when pulling inside a scrolled task list", async () => {
    mockBackend();
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
    const listView = container.querySelector(".list-view");
    Object.defineProperty(listView, "scrollTop", { configurable: true, value: 32 });
    invoke.mockClear();

    await fireEvent.touchStart(listView, { touches: [{ clientX: 120, clientY: 16 }] });
    await fireEvent.touchMove(listView, { touches: [{ clientX: 122, clientY: 104 }] });
    await fireEvent.touchEnd(listView);

    expect(invoke.mock.calls.some((c) => c[0] === "sync_now")).toBe(false);
  });
});
