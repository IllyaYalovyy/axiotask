import { describe, it, expect } from "vitest";
import { isSubtask, hasSubtasks, canAddSubtask, canNestUnder } from "../taskTree.js";

// Strict two-level tree (invariant #1): parents may have subtasks, subtasks may
// not. These predicates guard every mutation path against a third level.
const parent = { id: "p", parent_id: null };
const otherParent = { id: "p2", parent_id: null };
const sub = { id: "s", parent_id: "p" };
const childless = { id: "c", parent_id: null };
const tasks = [parent, otherParent, sub, childless];

describe("taskTree two-level invariant", () => {
  it("isSubtask: only tasks with a parent_id are subtasks", () => {
    expect(isSubtask(parent)).toBe(false);
    expect(isSubtask(sub)).toBe(true);
    expect(isSubtask(null)).toBe(false);
  });

  it("hasSubtasks: true only when some task points at the id", () => {
    expect(hasSubtasks("p", tasks)).toBe(true);
    expect(hasSubtasks("c", tasks)).toBe(false);
    expect(hasSubtasks("s", tasks)).toBe(false);
  });

  describe("canAddSubtask — a subtask can't gain a subtask", () => {
    it("allows adding under a top-level task", () => {
      expect(canAddSubtask(parent)).toBe(true);
      expect(canAddSubtask(childless)).toBe(true);
    });
    it("refuses adding under a subtask (would be a 3rd level)", () => {
      expect(canAddSubtask(sub)).toBe(false);
    });
    it("refuses when the parent is missing", () => {
      expect(canAddSubtask(null)).toBe(false);
      expect(canAddSubtask(undefined)).toBe(false);
    });
  });

  describe("canNestUnder — a task with subtasks can't become a subtask", () => {
    it("allows nesting a childless top-level task under another top-level task", () => {
      expect(canNestUnder("c", parent, tasks)).toBe(true);
    });
    it("refuses nesting a task that already has subtasks (its kids would be 3rd level)", () => {
      expect(canNestUnder("p", otherParent, tasks)).toBe(false);
    });
    it("refuses nesting under a subtask (would be a 3rd level)", () => {
      expect(canNestUnder("c", sub, tasks)).toBe(false);
    });
    it("refuses nesting under a missing parent", () => {
      expect(canNestUnder("c", null, tasks)).toBe(false);
    });
    it("refuses nesting a task under itself", () => {
      expect(canNestUnder("p", parent, tasks)).toBe(false);
    });
  });
});
