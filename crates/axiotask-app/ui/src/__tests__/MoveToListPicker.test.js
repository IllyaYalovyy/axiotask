import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import MoveToListPicker from "../MoveToListPicker.svelte";

describe("MoveToListPicker", () => {
  const lists = [
    { id: "L1", title: "Work" },
    { id: "L2", title: "Personal" },
    { id: "L3", title: "Someday" },
  ];

  it("renders all lists except current", () => {
    render(MoveToListPicker, { props: { lists, currentListId: "L1", onselect: vi.fn(), onclose: vi.fn() } });
    expect(screen.queryByText("Work")).not.toBeInTheDocument();
    expect(screen.getByText("Personal")).toBeInTheDocument();
    expect(screen.getByText("Someday")).toBeInTheDocument();
  });

  it("calls onselect when a list is clicked", async () => {
    const onselect = vi.fn();
    render(MoveToListPicker, { props: { lists, currentListId: "L1", onselect, onclose: vi.fn() } });
    await fireEvent.click(screen.getByText("Personal"));
    expect(onselect).toHaveBeenCalledWith({ id: "L2", title: "Personal" });
  });

  it("calls onclose on Escape", async () => {
    const onclose = vi.fn();
    render(MoveToListPicker, { props: { lists, currentListId: "L1", onselect: vi.fn(), onclose } });
    const dialog = screen.getByRole("dialog");
    await fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onclose).toHaveBeenCalled();
  });

  it("navigates with arrow keys and selects with Enter", async () => {
    const onselect = vi.fn();
    render(MoveToListPicker, { props: { lists, currentListId: "L1", onselect, onclose: vi.fn() } });
    const dialog = screen.getByRole("dialog");
    // First item is focused by default (Personal, index 0)
    await fireEvent.keyDown(dialog, { key: "ArrowDown" });
    // Now on Someday (index 1)
    await fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onselect).toHaveBeenCalledWith({ id: "L3", title: "Someday" });
  });

  it("calls onclose when overlay is clicked", async () => {
    const onclose = vi.fn();
    render(MoveToListPicker, { props: { lists, currentListId: "L2", onselect: vi.fn(), onclose } });
    // The overlay is the outer div
    const overlay = screen.getByRole("dialog").parentElement;
    await fireEvent.click(overlay);
    expect(onclose).toHaveBeenCalled();
  });
});
