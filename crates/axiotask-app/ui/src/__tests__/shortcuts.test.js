import { describe, it, expect } from "vitest";
import { SHORTCUT_CATEGORIES, formatKeys } from "../shortcuts.js";

describe("shortcuts registry", () => {
  it("exports an array of categories", () => {
    expect(Array.isArray(SHORTCUT_CATEGORIES)).toBe(true);
    expect(SHORTCUT_CATEGORIES.length).toBeGreaterThan(0);
  });

  it("each category has a name and a non-empty shortcuts list", () => {
    for (const category of SHORTCUT_CATEGORIES) {
      expect(typeof category.name).toBe("string");
      expect(category.name.length).toBeGreaterThan(0);
      expect(Array.isArray(category.shortcuts)).toBe(true);
      expect(category.shortcuts.length).toBeGreaterThan(0);
    }
  });

  it("each shortcut has keys (non-empty array of strings) and a description", () => {
    for (const category of SHORTCUT_CATEGORIES) {
      for (const sc of category.shortcuts) {
        expect(Array.isArray(sc.keys)).toBe(true);
        expect(sc.keys.length).toBeGreaterThan(0);
        for (const k of sc.keys) {
          expect(typeof k).toBe("string");
          expect(k.length).toBeGreaterThan(0);
        }
        expect(typeof sc.description).toBe("string");
        expect(sc.description.length).toBeGreaterThan(0);
      }
    }
  });

  it("covers the documented categories", () => {
    const names = SHORTCUT_CATEGORIES.map((c) => c.name);
    expect(names).toContain("Navigation");
    expect(names).toContain("Actions");
    expect(names).toContain("Due dates");
    expect(names).toContain("Organization");
    expect(names).toContain("Other");
  });

  it("includes core bindings", () => {
    const allKeys = SHORTCUT_CATEGORIES.flatMap((c) =>
      c.shortcuts.flatMap((s) => s.keys)
    );
    expect(allKeys).toContain("j");
    expect(allKeys).toContain("k");
    expect(allKeys).toContain("t");
    expect(allKeys).toContain("w");
    expect(allKeys).toContain("m");
    expect(allKeys).toContain("r");
    expect(allKeys).toContain("?");
  });

  it("has no duplicate descriptions within a category", () => {
    for (const category of SHORTCUT_CATEGORIES) {
      const descs = category.shortcuts.map((s) => s.description);
      expect(new Set(descs).size).toBe(descs.length);
    }
  });

  describe("formatKeys", () => {
    it("joins multiple keys with a slash separator", () => {
      expect(formatKeys(["j", "↓"])).toBe("j / ↓");
    });

    it("returns a single key unchanged", () => {
      expect(formatKeys(["Enter"])).toBe("Enter");
    });
  });
});
