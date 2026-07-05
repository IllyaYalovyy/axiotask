import { describe, it, expect, beforeEach } from "vitest";
import { getThemePref, setThemePref, applyTheme } from "../theme.js";

// #46: theme preference is persisted and applied to <html data-theme>.
describe("theme preference", () => {
  beforeEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute("data-theme");
  });

  it("defaults to dark", () => {
    expect(getThemePref()).toBe("dark");
  });

  it("persists and applies a chosen theme", () => {
    setThemePref("light");
    expect(getThemePref()).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");

    setThemePref("dark");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("applyTheme reflects the saved preference", () => {
    setThemePref("light");
    document.documentElement.removeAttribute("data-theme");
    applyTheme();
    expect(document.documentElement.dataset.theme).toBe("light");
  });
});
