import { describe, it, expect } from "vitest";
import { bootStartupError } from "../errorBoundary.js";

describe("startup error window", () => {
  it("shows the backend startup failure to the user instead of a blank window", () => {
    const target = document.createElement("div");
    const message =
      "Refusing to reset the local store after a schema change: it holds " +
      "local-only or unsynced changes that are not yet saved to Google, and the " +
      "pre-wipe backup could not be written to disk (no space left on device). " +
      "Your data has been left untouched.";

    const handled = bootStartupError({ __STARTUP_ERROR__: message }, target);

    expect(handled).toBe(true);
    const alert = target.querySelector("[role='alert']");
    expect(alert).not.toBeNull();
    expect(alert.textContent).toContain("axiotask couldn't start");
    expect(alert.textContent).toContain("Your data has been left untouched.");
  });

  it("does not take over the window when there is no startup error (normal boot)", () => {
    const target = document.createElement("div");

    const handled = bootStartupError({}, target);

    expect(handled).toBe(false);
    expect(target.childNodes.length).toBe(0);
  });

  it("renders a message containing markup as text, never as HTML", () => {
    const target = document.createElement("div");

    const handled = bootStartupError(
      { __STARTUP_ERROR__: "open db: <script>alert('x')</script>" },
      target,
    );

    expect(handled).toBe(true);
    expect(target.textContent).toContain("<script>alert('x')</script>");
    expect(target.innerHTML).not.toContain("<script>alert");
  });
});
