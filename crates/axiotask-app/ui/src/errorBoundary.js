export function formatError(error) {
  return String(error?.message ?? error ?? "Unknown error");
}

export function renderFatalError(target, title, error) {
  if (!target) return;
  target.replaceChildren();

  const shell = document.createElement("main");
  shell.className = "fatal-error";
  shell.setAttribute("role", "alert");

  const heading = document.createElement("h1");
  heading.textContent = title;

  const message = document.createElement("p");
  message.textContent = formatError(error);

  const detail = document.createElement("pre");
  detail.textContent = error?.stack || "";

  shell.append(heading, message);
  if (detail.textContent) shell.append(detail);
  target.append(shell);
}

export function logBoundaryError(scope, error) {
  console.error(`[${scope}]`, error);
}

// Backend startup failure (e.g. store `WipeAborted` or any `open()` error) is
// injected by the app shell as `window.__STARTUP_ERROR__` before any page
// script runs. When present, show it to the user instead of silently loading a
// dead app: a release build has no console, so an un-surfaced startup error is
// an invisible failure. Returns true when it took over the window, so the
// normal boot path can skip mounting the app (and its IPC calls) entirely.
export function bootStartupError(win, target) {
  const message = win?.__STARTUP_ERROR__;
  if (message == null || message === "") return false;
  renderFatalError(target, "axiotask couldn't start", message);
  return true;
}
