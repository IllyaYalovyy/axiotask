import { render, screen } from "@testing-library/svelte";
import { describe, it, expect } from "vitest";
import TodayView from "../TodayView.svelte";

describe("TodayView: empty states", () => {
  const baseProps = {
    tasks: [],
    focusIndex: 0,
    editingId: null,
    completingIds: new Set(),
    showCompleted: false,
    sortMode: "manual",
  };

  it("shows Focus empty state", () => {
    render(TodayView, { props: { ...baseProps, viewType: "focus" } });
    expect(screen.getByText("All clear for this week")).toBeInTheDocument();
  });

  it("shows Upcoming empty state", () => {
    render(TodayView, { props: { ...baseProps, viewType: "upcoming" } });
    expect(screen.getByText("Nothing upcoming")).toBeInTheDocument();
  });

  it("shows Missed empty state", () => {
    render(TodayView, { props: { ...baseProps, viewType: "missed" } });
    expect(screen.getByText("Nothing overdue")).toBeInTheDocument();
  });

  it("shows Unscheduled empty state", () => {
    render(TodayView, { props: { ...baseProps, viewType: "unscheduled" } });
    expect(screen.getByText("Everything is scheduled")).toBeInTheDocument();
  });

  it("renders tasks when provided", () => {
    const tasks = [
      { id: "t1", title: "Buy milk", status: "needsAction", due: null, position: "1", parent_id: null, notes: null, sync_state: "clean" },
    ];
    render(TodayView, { props: { ...baseProps, tasks, viewType: "focus" } });
    expect(screen.getByText("Buy milk")).toBeInTheDocument();
  });
});
