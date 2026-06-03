import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import NotesPanel from "../NotesPanel.svelte";

describe("NotesPanel", () => {
  it("renders with initial notes value", () => {
    render(NotesPanel, { props: { taskId: "t1", notes: "Hello world", onsave: vi.fn(), onclose: vi.fn() } });
    const textarea = screen.getByPlaceholderText("Add notes...");
    expect(textarea).toBeInTheDocument();
    expect(textarea.value).toBe("Hello world");
  });

  it("calls onsave on blur when content changed", async () => {
    const onsave = vi.fn();
    render(NotesPanel, { props: { taskId: "t1", notes: "original", onsave, onclose: vi.fn() } });
    const textarea = screen.getByPlaceholderText("Add notes...");
    await fireEvent.input(textarea, { target: { value: "modified" } });
    await fireEvent.blur(textarea);
    expect(onsave).toHaveBeenCalledWith("t1", "modified");
  });

  it("does not call onsave on blur when content unchanged", async () => {
    const onsave = vi.fn();
    render(NotesPanel, { props: { taskId: "t1", notes: "same", onsave, onclose: vi.fn() } });
    const textarea = screen.getByPlaceholderText("Add notes...");
    await fireEvent.blur(textarea);
    expect(onsave).not.toHaveBeenCalled();
  });

  it("calls onclose when close button clicked", async () => {
    const onclose = vi.fn();
    render(NotesPanel, { props: { taskId: "t1", notes: "", onsave: vi.fn(), onclose } });
    await fireEvent.click(screen.getByText("✕"));
    expect(onclose).toHaveBeenCalled();
  });

  it("calls onclose on Escape key", async () => {
    const onclose = vi.fn();
    render(NotesPanel, { props: { taskId: "t1", notes: "", onsave: vi.fn(), onclose } });
    const section = screen.getByRole("region", { name: /notes/i });
    await fireEvent.keyDown(section, { key: "Escape" });
    expect(onclose).toHaveBeenCalled();
  });
});
