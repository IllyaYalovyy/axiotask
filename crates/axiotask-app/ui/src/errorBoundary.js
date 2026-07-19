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
