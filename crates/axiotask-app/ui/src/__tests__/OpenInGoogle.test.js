import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import TaskDetail from "../TaskDetail.svelte";

const lists = [{ id: "L1", title: "Work" }];

function baseTask(overrides = {}) {
  return {
    id: "t1",
    parent_id: null,
    title: "Monthly update",
    notes: "",
    status: "needsAction",
    due: null,
    listId: "L1",
    web_view_link: null,
    ...overrides,
  };
}

function props(task) {
  return {
    task,
    parentTask: null,
    lists,
    subtasks: [],
    onsave: vi.fn(),
    onclose: vi.fn(),
    ondelete: vi.fn(),
    onmovelist: vi.fn(),
    ontogglesubtask: vi.fn(),
    onopensubtask: vi.fn(),
    onopenparent: vi.fn(),
    onaddsubtask: vi.fn(),
    onprev: null,
    onnext: null,
  };
}

describe("Open in Google Tasks link", () => {
  beforeEach(() => invoke.mockReset());

  it("is shown when the task has a webViewLink", () => {
    render(TaskDetail, {
      props: props(baseTask({ web_view_link: "https://tasks.google.com/task/xyz" })),
    });
    expect(screen.getByRole("button", { name: /open in google tasks/i })).toBeInTheDocument();
  });

  it("is hidden for a task without a webViewLink (e.g. not yet synced)", () => {
    render(TaskDetail, { props: props(baseTask({ web_view_link: null })) });
    expect(screen.queryByRole("button", { name: /open in google tasks/i })).not.toBeInTheDocument();
  });

  it("opens the task's Google URL via the open_url command", async () => {
    invoke.mockResolvedValue(null);
    render(TaskDetail, {
      props: props(baseTask({ web_view_link: "https://tasks.google.com/task/xyz" })),
    });
    await fireEvent.click(screen.getByRole("button", { name: /open in google tasks/i }));
    expect(invoke).toHaveBeenCalledWith("open_url", { url: "https://tasks.google.com/task/xyz" });
  });
});
