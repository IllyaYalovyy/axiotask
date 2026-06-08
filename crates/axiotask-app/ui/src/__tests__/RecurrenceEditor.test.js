import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import RecurrenceEditor from "../RecurrenceEditor.svelte";

describe("RecurrenceEditor", () => {
  it("shows 'Does not repeat' by default and hides detail fields", () => {
    render(RecurrenceEditor, { props: { rule: null, onchange: vi.fn() } });
    expect(screen.getByLabelText("Repeat")).toHaveValue("");
    expect(screen.getByTestId("recurrence-preview")).toHaveTextContent("Does not repeat");
    expect(screen.queryByLabelText("Every")).not.toBeInTheDocument();
  });

  it("emits a rule when a frequency is selected", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, { props: { rule: null, onchange } });
    await fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "WEEKLY" } });
    expect(onchange).toHaveBeenLastCalledWith(
      expect.objectContaining({ freq: "WEEKLY", interval: 1 }),
    );
  });

  it("emits null when set back to 'Does not repeat'", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, {
      props: { rule: { freq: "DAILY", interval: 1, byday: [], end: { kind: "never" } }, onchange },
    });
    await fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "" } });
    expect(onchange).toHaveBeenLastCalledWith(null);
  });

  it("shows weekday toggles only for weekly", async () => {
    render(RecurrenceEditor, {
      props: { rule: { freq: "MONTHLY", interval: 1, byday: [], end: { kind: "never" } }, onchange: vi.fn() },
    });
    expect(screen.queryByRole("group", { name: "Weekdays" })).not.toBeInTheDocument();
    await fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "WEEKLY" } });
    expect(screen.getByRole("group", { name: "Weekdays" })).toBeInTheDocument();
  });

  it("toggles weekdays in calendar order", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, {
      props: { rule: { freq: "WEEKLY", interval: 1, byday: [], end: { kind: "never" } }, onchange },
    });
    await fireEvent.click(screen.getByRole("button", { name: "Fri" }));
    await fireEvent.click(screen.getByRole("button", { name: "Mon" }));
    expect(onchange).toHaveBeenLastCalledWith(
      expect.objectContaining({ byday: ["MO", "FR"] }),
    );
  });

  it("reflects interval in the preview", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, {
      props: { rule: { freq: "WEEKLY", interval: 1, byday: [], end: { kind: "never" } }, onchange },
    });
    await fireEvent.input(screen.getByLabelText("Every"), { target: { value: "2" } });
    expect(screen.getByTestId("recurrence-preview")).toHaveTextContent("Every 2 weeks");
    expect(onchange).toHaveBeenLastCalledWith(expect.objectContaining({ interval: 2 }));
  });

  it("supports an end-on-date condition", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, {
      props: { rule: { freq: "DAILY", interval: 1, byday: [], end: { kind: "never" } }, onchange },
    });
    await fireEvent.change(screen.getByLabelText("Ends"), { target: { value: "onDate" } });
    await fireEvent.change(screen.getByLabelText("End date"), { target: { value: "2026-12-31" } });
    expect(onchange).toHaveBeenLastCalledWith(
      expect.objectContaining({ end: { kind: "onDate", date: "2026-12-31" } }),
    );
  });

  it("supports an after-N-times condition", async () => {
    const onchange = vi.fn();
    render(RecurrenceEditor, {
      props: { rule: { freq: "DAILY", interval: 1, byday: [], end: { kind: "never" } }, onchange },
    });
    await fireEvent.change(screen.getByLabelText("Ends"), { target: { value: "count" } });
    await fireEvent.input(screen.getByLabelText("Occurrences"), { target: { value: "5" } });
    expect(onchange).toHaveBeenLastCalledWith(
      expect.objectContaining({ end: { kind: "count", count: 5 } }),
    );
  });

  it("prefills fields from an existing rule", () => {
    render(RecurrenceEditor, {
      props: {
        rule: { freq: "WEEKLY", interval: 2, byday: ["MO", "WE"], end: { kind: "count", count: 4 } },
        onchange: vi.fn(),
      },
    });
    expect(screen.getByLabelText("Repeat")).toHaveValue("WEEKLY");
    expect(screen.getByLabelText("Every")).toHaveValue(2);
    expect(screen.getByRole("button", { name: "Mon" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Wed" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Tue" })).toHaveAttribute("aria-pressed", "false");
    expect(screen.getByTestId("recurrence-preview")).toHaveTextContent(
      "Every 2 weeks on Mon, Wed, 4 times",
    );
  });
});
