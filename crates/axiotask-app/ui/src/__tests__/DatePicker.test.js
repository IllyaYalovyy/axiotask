import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import DatePicker from "../DatePicker.svelte";

// #37: calendar popover for picking a specific due date.
describe("DatePicker", () => {
  const base = { value: "2026-06-15", onselect: vi.fn(), onclose: vi.fn() };

  it("opens on the month of the given value", () => {
    render(DatePicker, { props: { ...base, onselect: vi.fn() } });
    expect(screen.getByText("June 2026")).toBeInTheDocument();
  });

  it("emits the chosen day as YYYY-MM-DD", async () => {
    const onselect = vi.fn();
    render(DatePicker, { props: { ...base, onselect } });
    await fireEvent.click(screen.getByLabelText("2026-06-20"));
    expect(onselect).toHaveBeenCalledWith("2026-06-20");
  });

  it("navigates months", async () => {
    render(DatePicker, { props: { ...base, onselect: vi.fn() } });
    await fireEvent.click(screen.getByLabelText("Next month"));
    expect(screen.getByText("July 2026")).toBeInTheDocument();
    await fireEvent.click(screen.getByLabelText("Previous month"));
    await fireEvent.click(screen.getByLabelText("Previous month"));
    expect(screen.getByText("May 2026")).toBeInTheDocument();
  });

  it("Clear emits null", async () => {
    const onselect = vi.fn();
    render(DatePicker, { props: { ...base, onselect } });
    await fireEvent.click(screen.getByText("Clear"));
    expect(onselect).toHaveBeenCalledWith(null);
  });

  it("Enter picks the focused day; Escape closes", async () => {
    const onselect = vi.fn();
    const onclose = vi.fn();
    const { container } = render(DatePicker, { props: { value: "2026-06-15", onselect, onclose } });
    const overlay = container.querySelector(".overlay");
    await fireEvent.keyDown(overlay, { key: "ArrowRight" }); // focus 2026-06-16
    await fireEvent.keyDown(overlay, { key: "Enter" });
    expect(onselect).toHaveBeenCalledWith("2026-06-16");
    await fireEvent.keyDown(overlay, { key: "Escape" });
    expect(onclose).toHaveBeenCalled();
  });
});
