// Real end-to-end smoke test — the one test that actually proves the app works.
//
// Unlike the mocked happy-dom unit tests (which stub out Tauri IPC and the
// webview, so they pass even when the app is completely broken), this launches
// the REAL built binary via tauri-driver + WebKitWebDriver, drives the REAL
// webview, and asserts:
//   1. the app renders and is NOT stuck on "Loading..."  (catches IPC/startup
//      wedges like the window-geometry-restore hang)
//   2. real clicks/typing create tasks through the backend
//   3. core task flows still work in the packaged app: due dates, subtasks,
//      detail panel edits, completion, and search
//
// It reproduced the geometry hang in pure software rendering (Xephyr, no GPU),
// so it is hardware-independent and CI-friendly.

const DRIVER = process.env.WEBDRIVER_URL || "http://127.0.0.1:4444";
const BIN = process.env.AXIOTASK_BIN;
const EKEY = "element-6066-11e4-a52e-4f735466cecf";

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
  const exec = async (script, args = []) => (await wd("POST", `${base}/execute/sync`, { script, args })).value;
  const waitFor = async (label, predicate, { attempts = 40, delay = 250 } = {}) => {
    let last;
    for (let i = 0; i < attempts; i++) {
      last = await predicate();
      if (last) return last;
      await sleep(delay);
    }
    throw new Error(`FAIL: timed out waiting for ${label}`);
  };
  const textShown = async (text) => (await source()).includes(text);
  const byText = (selector, text) => `
    const needle = arguments[0];
    return [...document.querySelectorAll(${JSON.stringify(selector)})]
      .find((el) => (el.textContent || "").includes(needle)) || null;`;
  const clickElement = async (element) => exec("arguments[0].click(); return true;", [{ [EKEY]: element }]);
  const clickSelector = async (selector, label = selector) => {
    const element = await waitFor(label, () => findMaybe(selector));
    await clickElement(element);
    return element;
  };
  const clickText = async (selector, text) => {
    const element = await waitFor(`${selector} containing ${text}`, () => exec(byText(selector, text), [text]));
    await clickElement(element[EKEY] ? element[EKEY] : element);
    return element;
  };
  const setInputValue = async (selector, value, { blur = false } = {}) => exec(`
    const el = document.querySelector(arguments[0]);
    if (!el) return false;
    const proto = el instanceof HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, arguments[1]);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    if (arguments[2]) el.dispatchEvent(new FocusEvent('blur', { bubbles: false }));
    return true;`, [selector, value, blur]);
  const submitQuickAdd = async (title) => {
    const input = await waitFor("quick-add input", () => findMaybe("#quick-add-input"));
    await exec(`
      const el = arguments[0], v = arguments[1];
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(el, v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.form?.dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true }));
      return true;`, [{ [EKEY]: input }, title]);
    await waitFor(`created task ${title}`, () => textShown(title));
    return title;
  };
  const rowInfo = async (title) => exec(`
    const title = arguments[0];
    const row = [...document.querySelectorAll(".task-widget")]
      .find((el) => (el.textContent || "").includes(title));
    if (!row) return null;
    return {
      text: row.textContent,
      completed: row.classList.contains("completed"),
      checked: row.querySelector(".checkbox")?.checked ?? false,
      due: row.querySelector(".due")?.textContent || "",
      progress: row.querySelector(".progress-text")?.textContent || "",
    };`, [title]);
  const clickRowControl = async (title, selector, label) => {
    const element = await waitFor(label, () => exec(`
      const row = [...document.querySelectorAll(".task-widget")]
        .find((el) => (el.textContent || "").includes(arguments[0]));
      return row?.querySelector(arguments[1]) || null;`, [title, selector]));
    await clickElement(element[EKEY] ? element[EKEY] : element);
  };

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

    // 2) A real click on "+ New task" must focus the quick-add input (#8: the
    //    button routes into the persistent quick-add; nothing is persisted
    //    until the user commits a title).
    await sleep(500); // let the first render settle before interacting
    // WebKitWebDriver's synthesized element click is unsupported in this config,
    // so dispatch the real DOM click event via the page — this still exercises
    // the onclick handler end to end. Retry a couple of times to absorb
    // startup timing jitter.
    let quickAdd = null;
    for (let attempt = 0; attempt < 3 && !quickAdd; attempt++) {
      const btn = await findMaybe(".new-task-btn");
      if (!btn) throw new Error("FAIL: '+ New task' button not found");
      await wd("POST", `${base}/execute/sync`, {
        script: "arguments[0].click(); return true;",
        args: [{ [EKEY]: btn }],
      });
      for (let i = 0; i < 20; i++) {
        const focused = await wd("POST", `${base}/execute/sync`, {
          script: "return document.activeElement?.id === 'quick-add-input';",
          args: [],
        });
        if (focused.value === true) { quickAdd = await findMaybe("#quick-add-input"); }
        if (quickAdd) break;
        await sleep(250);
      }
    }
    if (!quickAdd) {
      const diag = await wd("POST", `${base}/execute/sync`, {
        script: `return document.querySelector('.content')?.innerHTML || document.body.innerHTML.slice(0, 1500);`,
        args: [],
      }).catch((e) => ({ value: "diag-failed: " + e.message }));
      console.error("DIAG CONTENT:", diag.value);
      throw new Error("FAIL: click had no effect — quick-add input never got focus (dead clicks / no repaint)");
    }
    console.log("ok 2 - click focused the quick-add input");

    // 3) Typing a title + Enter must create the task, round-trip through the
    //    backend (create_task IPC), and render as a row.
    const marker = `SMOKE-${Date.now()}`;
    // sendKeys is unsupported here too; drive the input through the DOM so
    // Svelte's bind:value and the form submit (→ create_task) both run.
    await wd("POST", `${base}/execute/sync`, {
      script: `
        const el = arguments[0], v = arguments[1];
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
        setter.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.form?.dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true }));
        return true;`,
      args: [{ [EKEY]: quickAdd }, marker],
    });

    let shown = false;
    for (let i = 0; i < 20; i++) {
      if ((await source()).includes(marker)) { shown = true; break; }
      await sleep(250);
    }
    if (!shown) throw new Error(`FAIL: created task '${marker}' never appeared (broken IPC/render)`);
    console.log("ok 3 - task round-tripped through backend and rendered");

    // Work in All Tasks for the rest of the flow so date changes and completed
    // tasks stay reachable regardless of smart-view filtering.
    await clickText(".views button", "All Tasks");
    await waitFor("All Tasks view", () => textShown("All Tasks"));

    const parent = `${marker}-parent`;
    const child = `${marker}-child`;
    const done = `${marker}-done`;

    await submitQuickAdd(parent);
    await clickRowControl(parent, "button[title='Tomorrow (t)']", "Tomorrow date action");
    const dueInfo = await waitFor("tomorrow due chip", async () => {
      const info = await rowInfo(parent);
      return info?.due ? info : null;
    });
    if (!dueInfo.due.trim()) throw new Error("FAIL: due date action did not render a dated chip");
    console.log("ok 4 - due date action persisted and rendered");

    // Subtasks are one level and live ONLY in the detail panel (#82/#91): the
    // list row has NO add-subtask affordance — the only entry point is the
    // panel's inline "Add a subtask" field. Add one there, confirm it is listed
    // in the checklist, then verify it never became a list row and the parent
    // shows a progress badge.
    await clickText(".task-widget .title", parent);
    await waitFor("parent detail panel for subtask add", () => findMaybe(".detail-panel #detail-title"));
    const rowHasAddSubtask = await exec(`
      const row = [...document.querySelectorAll(".task-widget")]
        .find((el) => (el.textContent || "").includes(arguments[0]));
      return !!row?.querySelector("button[title='Add subtask']");`, [parent]);
    if (rowHasAddSubtask) throw new Error("FAIL: task row still exposes an add-subtask control (#91 removed it)");
    await setInputValue(".detail-panel .subtask-add", child);
    await clickSelector(".detail-panel .add-subtask-btn", "Add subtask (detail panel)");
    await waitFor(`subtask ${child} listed in detail panel`, () => exec(`
      return [...document.querySelectorAll(".detail-panel .subtask-title")]
        .some((el) => (el.textContent || "").includes(arguments[0]));`, [child]));
    await clickSelector(".detail-panel .close-btn", "detail close");
    await waitFor("parent subtask progress", async () => {
      const info = await rowInfo(parent);
      return info?.progress === "0/1" ? info : null;
    });
    const childIsRow = await exec(`
      return [...document.querySelectorAll(".task-widget .title")]
        .some((el) => (el.textContent || "").includes(arguments[0]));`, [child]);
    if (childIsRow) throw new Error("FAIL: subtask rendered as a list row — it must live only in the detail panel");
    console.log("ok 5 - subtask added from the detail panel (not the list); parent shows progress");

    await clickText(".task-widget .title", parent);
    await waitFor("parent detail panel", () => findMaybe(".detail-panel #detail-title"));
    await setInputValue("#detail-title", `${parent} edited`, { blur: true });
    await setInputValue("#detail-notes", "detail panel smoke note", { blur: true });
    await waitFor("detail panel saved title", () => textShown(`${parent} edited`));
    const detailValue = await exec(`return document.querySelector("#detail-title")?.value || "";`);
    if (detailValue !== `${parent} edited`) throw new Error("FAIL: detail panel did not keep the saved title");
    await clickSelector(".detail-panel .close-btn", "detail close after edit");
    console.log("ok 6 - detail panel opens and saves title/notes");

    await submitQuickAdd(done);
    await clickRowControl(done, ".checkbox", "complete checkbox");
    await sleep(450); // completion animation settles before the list refreshes
    await clickSelector(".toggle input[type='checkbox']", "Show completed toggle");
    const completeInfo = await waitFor("completed task visible", async () => {
      const info = await rowInfo(done);
      return info?.completed && info.checked ? info : null;
    });
    if (!completeInfo.checked) throw new Error("FAIL: completed task checkbox was not checked");
    console.log("ok 7 - completion persists and completed row is visible when enabled");

    await exec(`
      document.dispatchEvent(new KeyboardEvent('keydown', {
        key: '/',
        bubbles: true,
        cancelable: true,
      }));
      return true;`);
    await waitFor("search overlay input", () => findMaybe(".search-overlay input"));
    await setInputValue(".search-overlay input", "edited");
    await waitFor("search result for edited task", () => exec(`
      return [...document.querySelectorAll(".result")]
        .some((el) => (el.textContent || "").includes(arguments[0]));`, [`${parent} edited`]));
    await exec(`
      const result = [...document.querySelectorAll(".result")]
        .find((el) => (el.textContent || "").includes(arguments[0]));
      result?.click();
      return !!result;`, [`${parent} edited`]);
    await waitFor("search selection opened detail panel", async () => {
      const title = await exec(`return document.querySelector(".detail-panel #detail-title")?.value || "";`);
      return title === `${parent} edited`;
    });
    console.log("ok 8 - search finds a task and opens it in the detail panel");

    console.log("\nSMOKE TEST PASSED");
  } finally {
    await wd("DELETE", base).catch(() => {});
  }
}

main().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
