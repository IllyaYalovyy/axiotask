import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import Sidebar from "../Sidebar.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
  { id: "L3", title: "Someday" },
];

function renderSidebar(overrides = {}) {
  return render(Sidebar, {
    props: {
      lists,
      selectedView: "focus",
      onselect: vi.fn(),
      onlogin: vi.fn(),
      onlogout: vi.fn(),
      onsync: vi.fn(),
      onfreshsync: vi.fn(),
      oncreateList: vi.fn(),
      onrenameList: vi.fn(),
      onlistaction: vi.fn(),
      onreorderlists: vi.fn(),
      onproperties: vi.fn(),
      ontoggletheme: vi.fn(),
      authenticated: true,
      syncStatus: "idle",
      lastSynced: null,
      excludedLists: [],
      counts: {},
      ...overrides,
    },
  });
}

describe("Sidebar", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  describe("Smart views", () => {
    it("renders all smart view buttons", () => {
      renderSidebar();
      expect(screen.getByRole("button", { name: /Focus/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Upcoming/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Missed/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Unscheduled/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /All Tasks/i })).toBeInTheDocument();
    });

    it("highlights the active view", () => {
      renderSidebar({ selectedView: "missed" });
      const btn = screen.getByRole("button", { name: /Missed/i });
      expect(btn.classList.contains("active")).toBe(true);
    });

    it("calls onselect when a smart view is clicked", async () => {
      const onselect = vi.fn();
      renderSidebar({ onselect });
      await fireEvent.click(screen.getByRole("button", { name: /Upcoming/i }));
      expect(onselect).toHaveBeenCalledWith("upcoming");
    });
  });

  describe("Count badges", () => {
    it("shows count badge next to smart views with tasks", () => {
      renderSidebar({ counts: { focus: 5, missed: 2, upcoming: 0 } });
      const focusBtn = screen.getByRole("button", { name: /Focus/i });
      expect(focusBtn.textContent).toContain("5");
      const missedBtn = screen.getByRole("button", { name: /Missed/i });
      expect(missedBtn.textContent).toContain("2");
    });

    it("does not show badge when count is 0 or absent", () => {
      renderSidebar({ counts: { focus: 0 } });
      const focusBtn = screen.getByRole("button", { name: /Focus/i });
      expect(focusBtn.textContent).not.toMatch(/\d/);
    });

    it("shows count badge next to list items", () => {
      renderSidebar({ counts: { L1: 3, L2: 7 } });
      const workBtn = screen.getByRole("button", { name: /Work/i });
      expect(workBtn.textContent).toContain("3");
      const personalBtn = screen.getByRole("button", { name: /Personal/i });
      expect(personalBtn.textContent).toContain("7");
    });
  });

  describe("+ New list button", () => {
    it("renders the + button for new list", () => {
      renderSidebar();
      expect(screen.getByTitle("New list")).toBeInTheDocument();
    });

    it("calls oncreateList with entered title", async () => {
      const oncreateList = vi.fn();
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New list"));
      const input = screen.getByPlaceholderText("List name...");
      await fireEvent.input(input, { target: { value: "Shopping" } });
      await fireEvent.keyDown(input, { key: "Enter" });
      expect(oncreateList).toHaveBeenCalledWith("Shopping", false);
    });

    it("does not call oncreateList if Escape pressed", async () => {
      const oncreateList = vi.fn();
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New list"));
      const input = screen.getByPlaceholderText("List name...");
      await fireEvent.keyDown(input, { key: "Escape" });
      expect(oncreateList).not.toHaveBeenCalled();
    });
  });

  describe("Local-only lists", () => {
    it("renders the local-only new-list button", () => {
      renderSidebar();
      expect(screen.getByTitle("New local-only list")).toBeInTheDocument();
    });

    it("creates a local-only list with the local-only flag", async () => {
      const oncreateList = vi.fn();
      renderSidebar({ oncreateList });
      await fireEvent.click(screen.getByTitle("New local-only list"));
      const input = screen.getByPlaceholderText("Local list name...");
      await fireEvent.input(input, { target: { value: "Scratch" } });
      await fireEvent.keyDown(input, { key: "Enter" });
      expect(oncreateList).toHaveBeenCalledWith("Scratch", true);
    });

    it("badges lists that are local-only", () => {
      renderSidebar({
        lists: [
          { id: "L1", title: "Work", local_only: false },
          { id: "L2", title: "Scratch", local_only: true },
        ],
      });
      const scratch = screen.getByRole("button", { name: /Scratch/i });
      expect(scratch.querySelector(".local-badge")).not.toBeNull();
      const work = screen.getByRole("button", { name: /Work/i });
      expect(work.querySelector(".local-badge")).toBeNull();
    });
  });

  describe("Sync Now button with status", () => {
    it("shows Sync now button when authenticated", () => {
      renderSidebar({ authenticated: true });
      expect(screen.getByRole("button", { name: /Sync now/i })).toBeInTheDocument();
    });

    it("shows Syncing... when sync is in progress", () => {
      renderSidebar({ authenticated: true, syncStatus: "syncing" });
      expect(screen.getByRole("button", { name: /Syncing/i })).toBeInTheDocument();
    });

    it("disables sync button while syncing", () => {
      renderSidebar({ authenticated: true, syncStatus: "syncing" });
      const btn = screen.getByRole("button", { name: /Syncing/i });
      expect(btn.disabled).toBe(true);
    });

    it("calls onsync when sync button is clicked", async () => {
      const onsync = vi.fn();
      renderSidebar({ onsync });
      await fireEvent.click(screen.getByRole("button", { name: /Sync now/i }));
      expect(onsync).toHaveBeenCalled();
    });

    it("shows last synced time", () => {
      const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000);
      renderSidebar({ authenticated: true, lastSynced: fiveMinAgo });
      expect(screen.getByText(/Synced 5m ago/i)).toBeInTheDocument();
    });

    it("updates the last synced age while the sidebar stays open", async () => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-07-16T12:00:00Z"));
      renderSidebar({
        authenticated: true,
        lastSynced: new Date("2026-07-16T11:59:30Z"),
      });
      expect(screen.getByText(/Synced just now/i)).toBeInTheDocument();

      await vi.advanceTimersByTimeAsync(30_000);

      expect(screen.getByText(/Synced 1m ago/i)).toBeInTheDocument();
    });

    it("shows sync error status", () => {
      renderSidebar({ authenticated: true, syncStatus: "error" });
      expect(screen.getByText(/Sync error/i)).toBeInTheDocument();
    });
  });

  describe("Sign in button", () => {
    it("shows Sign in button when not authenticated", () => {
      renderSidebar({ authenticated: false });
      expect(screen.getByRole("button", { name: /Sign in/i })).toBeInTheDocument();
    });

    it("does not show Sign in button when authenticated", () => {
      renderSidebar({ authenticated: true });
      expect(screen.queryByRole("button", { name: /Sign in/i })).not.toBeInTheDocument();
    });

    it("calls onlogin when sign in is clicked", async () => {
      const onlogin = vi.fn();
      renderSidebar({ authenticated: false, onlogin });
      await fireEvent.click(screen.getByRole("button", { name: /Sign in/i }));
      expect(onlogin).toHaveBeenCalled();
    });
  });

  describe("Excluded lists dimmed", () => {
    it("dims excluded lists with excluded class", () => {
      renderSidebar({ excludedLists: ["L3"] });
      const somedayBtn = screen.getByRole("button", { name: /Someday/i });
      expect(somedayBtn.classList.contains("excluded")).toBe(true);
    });

    it("non-excluded lists are not dimmed", () => {
      renderSidebar({ excludedLists: ["L3"] });
      const workBtn = screen.getByRole("button", { name: /Work/i });
      expect(workBtn.classList.contains("excluded")).toBe(false);
    });
  });

  describe("Lists rendering", () => {
    it("renders all task lists", () => {
      renderSidebar();
      expect(screen.getByRole("button", { name: /Work/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Personal/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument();
    });

    it("highlights the selected list", () => {
      renderSidebar({ selectedView: "L1" });
      const btn = screen.getByRole("button", { name: /Work/i });
      expect(btn.classList.contains("active")).toBe(true);
    });

    it("shows empty state when no lists exist", () => {
      renderSidebar({ lists: [] });
      expect(screen.getByText(/No lists/i)).toBeInTheDocument();
    });
  });
});
