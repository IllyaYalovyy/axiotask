// Regression guard for the task-view scrollbar.
//
// The scroll only works if an unbroken flex chain constrains height from the
// viewport down to the scrolling container:
//
//   .app (height: 100vh, display: flex)
//     └─ .content (flex: 1, flex-direction: column, min-height: 0)
//          └─ .smart-view / .list-view (flex: 1, overflow-y: auto, min-height: 0)
//
// Every flex item in the chain MUST have `min-height: 0`, otherwise its default
// `min-height: auto` lets it grow past the viewport and the inner container
// never scrolls. This has regressed more than once (the inner view, then the
// .content parent in the column/mobile layout), so we assert each invariant
// directly from the component CSS — jsdom cannot compute layout, but it can
// prove the load-bearing declarations are still present.
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const srcDir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Return the declaration body of the first CSS rule matching `selector`. */
function ruleBody(file, selector) {
  const css = readFileSync(join(srcDir, file), "utf8");
  // Escape regex metacharacters in the selector, then capture up to the next }.
  const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`(?:^|[,}\\s])${esc}\\s*\\{([^}]*)\\}`, "m");
  const m = css.match(re);
  if (!m) throw new Error(`selector "${selector}" not found in ${file}`);
  return m[1];
}

/** Assert a rule body declares `prop` with a value matching `valueRe`. */
function expectDecl(body, prop, valueRe) {
  const re = new RegExp(`${prop}\\s*:\\s*([^;]+)`, "g");
  const values = [...body.matchAll(re)].map((m) => m[1].trim());
  expect(values.length, `"${prop}" declared`).toBeGreaterThan(0);
  expect(
    values.some((v) => valueRe.test(v)),
    `"${prop}" matches ${valueRe} (got: ${values.join(" | ")})`,
  ).toBe(true);
}

describe("task-view scroll layout invariants", () => {
  it(".app pins to the viewport height and is a flex container", () => {
    const app = ruleBody("App.svelte", ".app");
    expectDecl(app, "display", /flex/);
    // 100vh with a 100dvh override is the accepted form.
    expectDecl(app, "height", /100(vh|dvh)/);
  });

  it(".content shrinks in BOTH flex directions (min-width AND min-height: 0)", () => {
    const content = ruleBody("App.svelte", ".content");
    expectDecl(content, "flex", /1/);
    expectDecl(content, "flex-direction", /column/);
    expectDecl(content, "min-width", /0/);
    // The bug: missing min-height:0 broke scrolling in the column/mobile layout.
    expectDecl(content, "min-height", /0/);
  });

  it.each([
    ["TodayView.svelte", ".smart-view"],
    ["ListView.svelte", ".list-view"],
  ])("%s %s is a scrollable flex child with min-height:0", (file, selector) => {
    const body = ruleBody(file, selector);
    expectDecl(body, "flex", /1/);
    expectDecl(body, "overflow-y", /auto|scroll/);
    expectDecl(body, "min-height", /0/);
  });
});
