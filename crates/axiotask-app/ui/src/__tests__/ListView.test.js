import { render, screen } from "@testing-library/svelte";
import { describe, it, expect } from "vitest";
import ListView from "../ListView.svelte";

describe("ListView", () => {
  const baseProps = {
    tasks: [],
    focusIndex: 0,
    editingId: null,
    completingIds: new Set(),
    isCrossList: false,
    sortMode: "manual",
  };

  it("shows empty state when no tasks", () => {
    render(ListView, { props: baseProps });
    expect(screen.getByText("No tasks")).toBeInTheDocument();
    expect(screen.getByText("Use quick add or press n to create one.")).toBeInTheDocument();
    expect(screen.queryByText(/box above/i)).not.toBeInTheDocument();
  });

  it("renders tasks when provided", () => {
    const tasks = [
      { id: "t1", title: "First task", status: "needsAction", due: null, position: "1", parent_id: null, notes: null, sync_state: "clean" },
      { id: "t2", title: "Second task", status: "needsAction", due: null, position: "2", parent_id: null, notes: null, sync_state: "clean" },
    ];
    render(ListView, { props: { ...baseProps, tasks } });
    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(screen.getByText("Second task")).toBeInTheDocument();
  });

  it("does not show empty state when tasks exist", () => {
    const tasks = [
      { id: "t1", title: "Only task", status: "needsAction", due: null, position: "1", parent_id: null, notes: null, sync_state: "clean" },
    ];
    render(ListView, { props: { ...baseProps, tasks } });
    expect(screen.queryByText("No tasks")).not.toBeInTheDocument();
  });
});
