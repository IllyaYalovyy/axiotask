import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import AppBoundary from "../AppBoundary.svelte";
import ThrowOnRender from "./fixtures/ThrowOnRender.svelte";
import { renderFatalError } from "../errorBoundary.js";

describe("frontend error boundary", () => {
  it("renders a recoverable app-level failure screen when a child component throws", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});

    render(AppBoundary, { props: { Component: ThrowOnRender } });

    expect(screen.getByRole("alert")).toHaveTextContent("axiotask hit a UI error");
    expect(screen.getByRole("alert")).toHaveTextContent("render exploded");
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument();

    spy.mockRestore();
  });

  it("renders startup and global failures without injecting raw HTML", () => {
    const target = document.createElement("div");
    const error = new Error("<script>alert('x')</script>");

    renderFatalError(target, "axiotask could not start", error);

    expect(target.querySelector("[role='alert']")).not.toBeNull();
    expect(target.textContent).toContain("<script>alert('x')</script>");
    expect(target.innerHTML).not.toContain("<script>alert");
  });
});
