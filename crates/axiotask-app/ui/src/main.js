import { mount } from "svelte";
import "./theme.css";
import { applyTheme } from "./theme.js";
import { renderFatalError, bootStartupError } from "./errorBoundary.js";

// Apply the saved theme before the app renders, so there's no flash.
applyTheme();

// A backend startup failure (store WipeAborted, or any open() error) is injected
// by the app shell as window.__STARTUP_ERROR__. Surface it and stop — do not
// mount the app or fire any IPC against state that never initialized.
if (!bootStartupError(window, document.getElementById("app"))) {
  // Capture all errors and write them visibly
  window.onerror = (msg, src, line, col, err) => {
    renderFatalError(document.getElementById("app"), "axiotask hit a UI error", err || `${msg}\nSource: ${src}:${line}:${col}`);
  };

  window.onunhandledrejection = (e) => {
    renderFatalError(document.getElementById("app"), "axiotask hit an async UI error", e.reason);
  };

  start().catch((e) => {
    renderFatalError(document.getElementById("app"), "axiotask could not start", e);
  });
}

async function start() {
  const { default: AppBoundary } = await import("./AppBoundary.svelte");
  const target = document.getElementById("app");
  target.textContent = "";
  mount(AppBoundary, { target });
}
