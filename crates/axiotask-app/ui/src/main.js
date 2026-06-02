import { mount } from "svelte";

// Capture all errors and write them visibly
window.onerror = (msg, src, line, col, err) => {
  document.getElementById("app").innerHTML = `<pre style="color:red;padding:2rem;font-size:14px;white-space:pre-wrap;">ERROR: ${msg}\nSource: ${src}:${line}:${col}\n${err?.stack || ""}</pre>`;
};

window.onunhandledrejection = (e) => {
  document.getElementById("app").innerHTML += `<pre style="color:orange;padding:1rem;font-size:14px;white-space:pre-wrap;">UNHANDLED REJECTION: ${e.reason}\n${e.reason?.stack || ""}</pre>`;
};

async function start() {
  const { default: App } = await import("./App.svelte");
  const target = document.getElementById("app");
  target.textContent = "";
  mount(App, { target });
}

start().catch((e) => {
  document.getElementById("app").innerHTML = `<pre style="color:red;padding:2rem;font-size:14px;white-space:pre-wrap;">STARTUP ERROR:\n${e.message}\n\n${e.stack}</pre>`;
});
