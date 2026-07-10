// Real end-to-end smoke test — the one test that actually proves the app works.
//
// Unlike the mocked happy-dom unit tests (which stub out Tauri IPC and the
// webview, so they pass even when the app is completely broken), this launches
// the REAL built binary via tauri-driver + WebKitWebDriver, drives the REAL
// webview, and asserts:
//   1. the app renders and is NOT stuck on "Loading..."  (catches IPC/startup
//      wedges like the window-geometry-restore hang)
//   2. a real mouse click on "+ New task" produces an editable task
//   3. typing a title + Enter round-trips through the backend and shows up
//      (catches dead clicks / broken IPC / broken rendering)
//
// It reproduced the geometry hang in pure software rendering (Xephyr, no GPU),
// so it is hardware-independent and CI-friendly.

const DRIVER = process.env.WEBDRIVER_URL || "http://127.0.0.1:4444";
const BIN = process.env.AXIOTASK_BIN;
const EKEY = "element-6066-11e4-a52e-4f735466cecf";
const ENTER = "";

if (!BIN) { console.error("AXIOTASK_BIN not set"); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function wd(method, path, body) {
  // WebKitWebDriver requires a valid JSON body on POSTs (e.g. click), so default
  // to {} rather than sending an empty body.
  const res = await fetch(DRIVER + path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: method === "POST" ? JSON.stringify(body || {}) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${JSON.stringify(json)}`);
  return json;
}

async function main() {
  const caps = { capabilities: { alwaysMatch: { "tauri:options": { application: BIN } } } };
  const sess = await wd("POST", "/session", caps);
  const id = sess.value.sessionId;
  const base = `/session/${id}`;

  const findMaybe = async (css) => {
    try {
      const r = await wd("POST", `${base}/element`, { using: "css selector", value: css });
      return r.value[EKEY];
    } catch { return null; }
  };
  const source = async () => (await wd("GET", `${base}/source`)).value;

  try {
    // 1) App must leave the loading state and render the sidebar.
    let rendered = false, last = "";
    for (let i = 0; i < 60; i++) {
      last = await source();
      if (last.includes("Focus") && !last.includes("Loading...")) { rendered = true; break; }
      await sleep(500);
    }
    if (!rendered) {
      // A binary built with plain `cargo build --release` loads the dev server
      // URL and renders a connection error. That is a build mistake, not an app
      // bug, and it otherwise looks identical to a startup wedge.
      if (last.includes("Could not connect to localhost")) {
        throw new Error(
          "FAIL: binary was built in dev mode (it loads http://localhost:1420).\n" +
          "      rebuild it: cd crates/axiotask-app && cargo tauri build --no-bundle");
      }
      throw new Error("FAIL: app stuck on 'Loading...' / never rendered (startup/IPC wedge)");
    }
    console.log("ok 1 - app rendered, not stuck on Loading");

    // 2) A real click on "+ New task" must produce an editable task input.
    await sleep(500); // let the first render settle before interacting
    // WebKitWebDriver's synthesized element click is unsupported in this config,
    // so dispatch the real DOM click event via the page — this still exercises
    // the onclick handler → create_task IPC → re-render path end to end. Retry a
    // couple of times to absorb startup timing jitter.
    let editInput = null;
    for (let attempt = 0; attempt < 3 && !editInput; attempt++) {
      const btn = await findMaybe(".new-task-btn");
      if (!btn) throw new Error("FAIL: '+ New task' button not found");
      await wd("POST", `${base}/execute/sync`, {
        script: "arguments[0].click(); return true;",
        args: [{ [EKEY]: btn }],
      });
      for (let i = 0; i < 20; i++) {
        editInput = await findMaybe("input.edit-input");
        if (editInput) break;
        await sleep(250);
      }
    }
    if (!editInput) {
      const diag = await wd("POST", `${base}/execute/sync`, {
        script: `return document.querySelector('.content')?.innerHTML || document.body.innerHTML.slice(0, 1500);`,
        args: [],
      }).catch((e) => ({ value: "diag-failed: " + e.message }));
      console.error("DIAG CONTENT:", diag.value);
      throw new Error("FAIL: click had no effect — no edit input appeared (dead clicks / no repaint)");
    }
    console.log("ok 2 - click created an editable task");

    // 3) Typing a title + Enter must round-trip and render.
    const marker = `SMOKE-${Date.now()}`;
    // sendKeys is unsupported here too; drive the input through the DOM so
    // Svelte's bind:value and the Enter handler (commit → rename_task) both run.
    await wd("POST", `${base}/execute/sync`, {
      script: `
        const el = arguments[0], v = arguments[1];
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
        setter.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        return true;`,
      args: [{ [EKEY]: editInput }, marker],
    });

    let shown = false;
    for (let i = 0; i < 20; i++) {
      if ((await source()).includes(marker)) { shown = true; break; }
      await sleep(250);
    }
    if (!shown) throw new Error(`FAIL: created task '${marker}' never appeared (broken IPC/render)`);
    console.log("ok 3 - task round-tripped through backend and rendered");

    console.log("\nSMOKE TEST PASSED");
  } finally {
    await wd("DELETE", base).catch(() => {});
  }
}

main().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
