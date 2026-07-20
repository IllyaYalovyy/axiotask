import { render, screen } from "@testing-library/svelte";
import { describe, it, expect } from "vitest";
import TodayView from "../TodayView.svelte";

describe("TodayView: empty states", () => {
  function daysFromNow(n) {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() + n);
    return d.toISOString();
  }

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

  it("groups overdue Focus tasks under a counted section header", () => {
    const tasks = [
      { id: "t1", title: "Missed invoice", status: "needsAction", due: daysFromNow(-2), position: "1", parent_id: null, notes: null, sync_state: "clean" },
      { id: "t2", title: "Missed follow-up", status: "needsAction", due: daysFromNow(-1), position: "2", parent_id: null, notes: null, sync_state: "clean" },
      { id: "t3", title: "Today review", status: "needsAction", due: daysFromNow(0), position: "3", parent_id: null, notes: null, sync_state: "clean" },
    ];

    render(TodayView, { props: { ...baseProps, tasks, viewType: "focus" } });

    const header = screen.getByRole("heading", { name: "Overdue (2)" });
    const section = header.closest("section");
    expect(section).toContainElement(screen.getByText("Missed invoice"));
    expect(section).toContainElement(screen.getByText("Missed follow-up"));
    expect(section).not.toContainElement(screen.getByText("Today review"));
  });
});
