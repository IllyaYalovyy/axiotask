import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import TaskDetail from "../TaskDetail.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function baseTask(overrides = {}) {
  return {
    id: "T1",
    title: "Standup",
    notes: "",
    due: null,
    listId: "L1",
    status: "needsAction",
    ...overrides,
  };
}

describe("TaskDetail recurrence integration", () => {
  it("renders the recurrence editor", () => {
    render(TaskDetail, {
      props: { task: baseTask(), parentTask: null, lists, onsave: vi.fn(), onclose: vi.fn(), ondelete: vi.fn(), onmovelist: vi.fn() },
    });
    expect(screen.getByTestId("recurrence-editor")).toBeInTheDocument();
    expect(screen.getByTestId("recurrence-preview")).toHaveTextContent("Does not repeat");
  });

  it("prefills the editor from a notes trailer and shows visible notes separately", () => {
    render(TaskDetail, {
      props: {
        task: baseTask({ notes: "Bring coffee\n[[recur:FREQ=DAILY]]" }),
        parentTask: null,
        lists,
        onsave: vi.fn(),
        onclose: vi.fn(),
        ondelete: vi.fn(),
        onmovelist: vi.fn(),
      },
    });
    // Notes textarea shows only the human-visible text, not the rule trailer.
    expect(screen.getByLabelText("Notes")).toHaveValue("Bring coffee");
    expect(screen.getByLabelText("Repeat")).toHaveValue("DAILY");
  });

  it("embeds the rule into notes on save", async () => {
    const onsave = vi.fn();
    render(TaskDetail, {
      props: { task: baseTask({ notes: "Daily report" }), parentTask: null, lists, onsave, onclose: vi.fn(), ondelete: vi.fn(), onmovelist: vi.fn() },
    });
    await fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "DAILY" } });
    await fireEvent.click(screen.getByText("Save"));
    expect(onsave).toHaveBeenLastCalledWith(
      "T1",
      expect.objectContaining({ notes: "Daily report\n[[recur:FREQ=DAILY]]" }),
    );
  });

  it("strips the rule from notes when repeat is turned off", async () => {
    const onsave = vi.fn();
    render(TaskDetail, {
      props: {
        task: baseTask({ notes: "Daily report\n[[recur:FREQ=DAILY]]" }),
        parentTask: null,
        lists,
        onsave,
        onclose: vi.fn(),
        ondelete: vi.fn(),
        onmovelist: vi.fn(),
      },
    });
    await fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "" } });
    await fireEvent.click(screen.getByText("Save"));
    expect(onsave).toHaveBeenLastCalledWith(
      "T1",
      expect.objectContaining({ notes: "Daily report" }),
    );
  });
});
