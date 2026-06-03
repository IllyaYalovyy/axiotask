import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// Override the window mock with a stable setTitle reference
const setTitleMock = vi.fn().mockResolvedValue(undefined);
vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ setTitle: setTitleMock }),
}));

const sampleLists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function mockBackend(lists = sampleLists, tasks = []) {
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

describe("Window title reflects current view", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
    setTitleMock.mockClear();
  });

  it("sets title to 'Focus — axiotask' for focus view", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Focus — axiotask"));
  });

  it("sets title to 'Upcoming — axiotask' when switching to upcoming", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /Upcoming/i }));
    await fireEvent.click(screen.getByRole("button", { name: /Upcoming/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Upcoming — axiotask"));
  });

  it("sets title to 'Missed — axiotask' when switching to missed", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /Missed/i }));
    await fireEvent.click(screen.getByRole("button", { name: /Missed/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Missed — axiotask"));
  });

  it("sets title to list name for a task list view", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /Work/i }));
    await fireEvent.click(screen.getByRole("button", { name: /Work/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Work — axiotask"));
  });

  it("sets title to 'All Tasks — axiotask' when switching to all", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /All Tasks/i }));
    await fireEvent.click(screen.getByRole("button", { name: /All Tasks/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("All Tasks — axiotask"));
  });

  it("sets title to 'Unscheduled — axiotask' when switching to unscheduled", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /Unscheduled/i }));
    await fireEvent.click(screen.getByRole("button", { name: /Unscheduled/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Unscheduled — axiotask"));
  });
});
