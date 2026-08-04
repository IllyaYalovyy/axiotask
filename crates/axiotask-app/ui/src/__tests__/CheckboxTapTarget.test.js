// Regression for #167: the visual checkbox glyph on mobile (pointer: coarse)
// must stay 1.3rem while the *tap target* around it reaches the 44px minimum.
//
// The shipped app applies `:global(*) { box-sizing: border-box }` (App.svelte),
// so the previous coarse-pointer rule — `width: 1.3rem; min-width: 44px` — did
// NOT enlarge only the hit area: with border-box, min-width:44px forces the
// input's border box (and therefore the drawn checkbox glyph) to 44px, so the
// checkbox rendered as a giant 44px square on mobile. The fix keeps the glyph
// at 1.3rem (content box) and pads OUT to a 44px tap target instead.
//
// jsdom does not evaluate scoped component stylesheets and cannot lay out a
// native checkbox glyph (verified — same limitation as SafeAreaInsets #160 and
// ThemeContrast #81), so this asserts the shipped CSS carries the tap-target
// contract rather than measuring a rendered pixel.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const src = readFileSync(resolve(process.cwd(), "src/TaskRow.svelte"), "utf8");

// The <style> block, comments stripped so a `/* … */` can't hide a token.
const styleBlock = src
  .slice(src.indexOf("<style>"), src.indexOf("</style>"))
  .replace(/\/\*[\s\S]*?\*\//g, "");

// Return the body of the first at-rule whose head trims to exactly `header`.
function atRuleBody(css, header) {
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open === -1) break;
    const head = css.slice(i, open).trim();
    let depth = 1;
    let j = open + 1;
    for (; j < css.length && depth > 0; j++) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") depth--;
    }
    if (head === header) return css.slice(open + 1, j - 1);
    i = j;
  }
  return null;
}

// Return the declaration body of `selector` inside `css` (non-recursive).
function ruleBody(css, selector) {
  let i = 0;
  const re = new RegExp(`(^|[\\s,>])${selector.replace(".", "\\.")}(\\s|$|[,:{])`);
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open === -1) break;
    const head = css.slice(i, open).trim();
    let depth = 1;
    let j = open + 1;
    for (; j < css.length && depth > 0; j++) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") depth--;
    }
    if (!head.startsWith("@") && re.test(head)) return css.slice(open + 1, j - 1);
    i = j;
  }
  return null;
}

describe("#167: mobile checkbox keeps a 1.3rem glyph with a 44px tap target", () => {
  const coarse = atRuleBody(styleBlock, "@media (pointer: coarse)");

  it("has a dedicated pointer:coarse media block", () => {
    expect(coarse).toBeTruthy();
  });

  it("keeps the visual glyph at 1.3rem on coarse pointers", () => {
    const cb = ruleBody(coarse, ".checkbox");
    expect(cb).toBeTruthy();
    expect(cb).toMatch(/(^|[\s;])width:\s*1\.3rem/);
    expect(cb).toMatch(/(^|[\s;])height:\s*1\.3rem/);
  });

  it("does NOT blow the glyph up to 44px via min-width/min-height", () => {
    // With the global border-box reset, a 44px min on the input's box scales
    // the drawn glyph itself — that is the exact #167 defect.
    const cb = ruleBody(coarse, ".checkbox");
    expect(cb).not.toMatch(/min-width:\s*44px/);
    expect(cb).not.toMatch(/min-height:\s*44px/);
  });

  it("pads OUT to a 44px hit area around the 1.3rem glyph (content box)", () => {
    const cb = ruleBody(coarse, ".checkbox");
    // Must opt into content-box or the border-box reset would eat the padding
    // and shrink the glyph below 1.3rem.
    expect(cb).toMatch(/box-sizing:\s*content-box/);
    // Padding derived from the 44px target so glyph(1.3rem) + padding == 44px.
    expect(cb).toMatch(/padding:\s*calc\(\(\s*44px\s*-\s*1\.3rem\s*\)\s*\/\s*2\)/);
  });
});
