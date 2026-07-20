import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "..");
const directMenuIconGlyph = /icon:\s*"[^"]*[\p{Extended_Pictographic}↤↗]/u;

function source(file) {
  return readFileSync(resolve(src, file), "utf8");
}

describe("Icon unification", () => {
  it("renders context menu icons through Icon.svelte names", () => {
    const app = source("App.svelte");
    const contextMenu = source("ContextMenu.svelte");

    expect(contextMenu).toContain('import Icon from "./Icon.svelte"');
    expect(contextMenu).toContain("<Icon");
    expect(app).not.toMatch(directMenuIconGlyph);
  });

  it("uses Icon.svelte for sidebar smart views and Properties tabs", () => {
    const sidebar = source("Sidebar.svelte");
    const properties = source("Properties.svelte");

    expect(sidebar).toContain('import Icon from "./Icon.svelte"');
    expect(properties).toContain('import Icon from "./Icon.svelte"');
    expect(sidebar).not.toMatch(/[★☰⚠○▤⚙↻🔑☀🌙⠿]/u);
    expect(properties).not.toMatch(/[↻◐👤⌨ℹ⚙⚠⟳⭳⭱]/u);
  });
});
