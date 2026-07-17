import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import SortDropdown from "../SortDropdown.svelte";

describe("SortDropdown", () => {
  it("displays current sort mode label", () => {
    render(SortDropdown, { props: { value: "due", onchange: vi.fn() } });
    expect(screen.getByText(/Sort:.*Due date/)).toBeInTheDocument();
  });

  it("shows My order as default label", () => {
    render(SortDropdown, { props: { value: "manual", onchange: vi.fn() } });
    expect(screen.getByText(/Sort:.*My order/)).toBeInTheDocument();
  });

  it("opens menu on click and shows all options", async () => {
    const { container } = render(SortDropdown, { props: { value: "manual", onchange: vi.fn() } });
    const dropdown = container.querySelector(".sort-dropdown");
    await fireEvent.click(dropdown);
    expect(screen.getByText(/Alphabetical/)).toBeInTheDocument();
    expect(screen.getByText(/Reverse my order/)).toBeInTheDocument();
    expect(screen.getByText(/Due date/)).toBeInTheDocument();
  });

  it("calls onchange when option selected", async () => {
    const onchange = vi.fn();
    const { container } = render(SortDropdown, { props: { value: "manual", onchange } });
    const dropdown = container.querySelector(".sort-dropdown");
    await fireEvent.click(dropdown);
    const alphaOption = screen.getByText(/Alphabetical/);
    await fireEvent.click(alphaOption);
    expect(onchange).toHaveBeenCalledWith("alpha");
  });

  it("closes menu after selection", async () => {
    const { container } = render(SortDropdown, { props: { value: "manual", onchange: vi.fn() } });
    const dropdown = container.querySelector(".sort-dropdown");
    await fireEvent.click(dropdown);
    expect(screen.getByText(/Alphabetical/)).toBeInTheDocument();
    await fireEvent.click(screen.getByText(/Alphabetical/));
    expect(screen.queryByText(/Recently created/)).not.toBeInTheDocument();
  });
});
