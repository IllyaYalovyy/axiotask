<script>
  import { tick, untrack } from "svelte";
  import DatePicker from "./DatePicker.svelte";
  import Icon from "./Icon.svelte";
  import { invokeWithTimeout } from "./ipc.js";
  import { formatDue } from "./dateFormat.js";
  import { storageKey } from "./storage.js";
  let { task, parentTask, propagatedDue = null, lists, subtasks = [], focusRequest = null, onsave, onclose, ondelete, onmovelist, ondetach, ontogglesubtask, onopensubtask, onopenparent, onaddsubtask, onprev, onnext } = $props();

  let title = $state("");
  let notes = $state("");
  let due = $state("");
  let selectedList = $state("");

  // The "Due date" field opens our own calendar popover rather than relying on
  // <input type="date">: WebKitGTK's native date popup does not close when a day
  // is picked, and it ignores the app's light/dark theme.
  let showDatePicker = $state(false);
  let subtaskDatePickerTask = $state(null);

  // Inline "add a subtask" field. Creating a subtask no longer means spawning a
  // blank task and navigating into it — the user types a name here and presses
  // Enter (or taps +), the subtask appears in the list below, and the panel
  // stays on the parent so several can be added in a row.
  let newSubtaskTitle = $state("");
  let newSubtaskInput = $state(null);

  // Optionally collapse finished subtasks out of the checklist. UX only — this
  // never touches the tasks themselves (no delete, no status change) or the
  // date rollup; completed subtasks still exist and still count. The choice is
  // remembered per user so a busy checklist stays tidy across panels/sessions.
  let hideCompletedSubtasks = $state(localStorage.getItem(storageKey("hideCompletedSubtasks")) === "true");
  $effect(() => { localStorage.setItem(storageKey("hideCompletedSubtasks"), String(hideCompletedSubtasks)); });
  let completedSubtaskCount = $derived(subtasks.filter((s) => s.status === "completed").length);
  let visibleSubtasks = $derived(hideCompletedSubtasks ? subtasks.filter((s) => s.status !== "completed") : subtasks);

  let prevTaskId = $state(null);
  let titleInput = $state(null);
  let notesInput = $state(null);
  let appliedFocusKey = $state(null);
  // The task's values when it was loaded, so we only save fields the user
  // actually changed. Saving unchanged fields would needlessly mark the task
  // dirty and trigger a push (and, if it races another push, a 412 conflict).
  let orig = $state({ title: "", notes: "", due: "", list: "" });

  // Clickable links found in the title or notes (deduped, live as you type).
  function extractUrls(text) {
    return text ? (text.match(/https?:\/\/[^\s)>\]]+/g) || []) : [];
  }
  let detectedLinks = $derived([...new Set([...extractUrls(title), ...extractUrls(notes)])]);

  // Local calendar date as YYYY-MM-DD. Must NOT go through toISOString(), which
  // converts to UTC — west of UTC in the evening that rolls to tomorrow, so
  // "Today" would set the wrong day.
  const pad2 = (n) => String(n).padStart(2, "0");
  const localISO = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;

  // Only the { title, notes, due } fields that differ from the loaded values.
  function changedFields() {
    const out = {};
    if (title !== orig.title) out.title = title;
    if (notes !== orig.notes) out.notes = notes;
    if (due !== orig.due) out.due = due || null;
    return out;
  }

  // Auto-save the previous task's edits when switching to a different task —
  // but only if something actually changed.
  $effect.pre(() => {
    if (task && prevTaskId && prevTaskId !== task.id) {
      const ch = changedFields();
      if (Object.keys(ch).length) onsave(prevTaskId, ch);
    }
  });

  // Load `task` into the editable fields. Reads of the editable vars are
  // untracked so this effect depends solely on `task` — otherwise editing a
  // field would re-trigger it and wipe the edit.
  $effect(() => {
    if (!task) return;
    const id = task.id;
    const t = task.title || "";
    const n = task.notes || "";
    const d = task.due ? task.due.slice(0, 10) : "";
    const l = task.listId || "";
    untrack(() => {
      if (id !== prevTaskId) {
        // A different task: load it wholesale.
        title = t; notes = n; due = d; selectedList = l;
        prevTaskId = id;
        if (!t) tick().then(() => titleInput?.focus());
      } else {
        // Same task, refreshed from the store (an inline rename, a sync pull, a
        // quick date action). Adopt each incoming value only where the user has
        // not typed over it, so the panel stays current without losing edits.
        if (title === orig.title) title = t;
        if (notes === orig.notes) notes = n;
        if (due === orig.due) due = d;
        if (selectedList === orig.list) selectedList = l;
      }
      orig = { title: t, notes: n, due: d, list: l };
    });
  });

  $effect(() => {
    if (!task || focusRequest?.id !== task.id || focusRequest.field !== "notes") return;
    const key = `${focusRequest.id}:${focusRequest.field}:${focusRequest.nonce ?? ""}`;
    if (appliedFocusKey === key) return;
    appliedFocusKey = key;
    tick().then(() => notesInput?.focus());
  });

  function save() {
    const ch = changedFields();
    if (Object.keys(ch).length) {
      onsave(task.id, ch);
      orig = { ...orig, ...ch, due: ch.due ?? (ch.due === null ? "" : orig.due) };
    }
    if (selectedList !== orig.list) {
      onmovelist(task.id, selectedList);
      orig = { ...orig, list: selectedList };
    }
  }

  function saveTitle() {
    if (title === orig.title) return;
    onsave(task.id, { title });
    orig = { ...orig, title };
  }

  function saveNotes() {
    if (notes === orig.notes) return;
    onsave(task.id, { notes });
    orig = { ...orig, notes };
  }

  function saveDue(nextDue = due) {
    due = nextDue;
    if (due === orig.due) return;
    onsave(task.id, { due: due || null });
    orig = { ...orig, due };
  }

  function saveList() {
    if (selectedList === orig.list) return;
    onmovelist(task.id, selectedList);
    orig = { ...orig, list: selectedList };
  }

  function subtaskDue(sub) {
    return sub.due ? sub.due.slice(0, 10) : "";
  }

  function openSubtaskDatePicker(sub) {
    subtaskDatePickerTask = sub;
  }

  function saveSubtaskDue(date) {
    const sub = subtaskDatePickerTask;
    subtaskDatePickerTask = null;
    if (sub) onsave(sub.id, { due: date || null });
  }

  function submitNewSubtask() {
    const t = newSubtaskTitle.trim();
    if (!t) return;
    onaddsubtask?.(task.id, t);
    newSubtaskTitle = "";
    // Keep focus for rapid entry of several subtasks in a row.
    tick().then(() => newSubtaskInput?.focus());
  }

  function newSubtaskKeydown(e) {
    if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); submitNewSubtask(); }
  }

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
    if (e.key === "s" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); save(); }
    if (e.key === "ArrowLeft" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); goPrev(); }
    if (e.key === "ArrowRight" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); goNext(); }
  }

  function goToParent() { save(); onopenparent?.(parentTask); }
  function openSub(sub) { save(); onopensubtask?.(sub); }
  function detachFromParent() { save(); ondetach?.(task.id); }
  function close() { save(); onclose({ ...task, title, notes, due: due ? `${due}T00:00:00.000Z` : null }); }
  function goPrev() { if (onprev) { save(); onprev(); } }
  function goNext() { if (onnext) { save(); onnext(); } }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside class="detail-panel" onkeydown={handleKeydown}>
  <div class="panel-header">
    <div class="panel-nav">
      <button class="nav-btn" onclick={goPrev} disabled={!onprev} title="Previous (←)">‹</button>
      <button class="nav-btn" onclick={goNext} disabled={!onnext} title="Next (→)">›</button>
      <h3>{parentTask ? "Subtask" : "Task Details"}</h3>
    </div>
    <div class="panel-actions">
      <button class="close-btn" onclick={close}>✕</button>
    </div>
  </div>

  {#if parentTask}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="breadcrumb" onclick={goToParent}>
      ← {parentTask.title || "Parent task"}
    </div>
    <button class="detach-btn" onclick={detachFromParent}>Detach from parent</button>
  {/if}

  <div class="field">
    <label for="detail-title">Title</label>
    <input id="detail-title" type="text" bind:this={titleInput} bind:value={title} onblur={saveTitle} placeholder="Task title" />
  </div>

  {#if task.web_view_link}
    <button
      class="open-google"
      onclick={() => invokeWithTimeout("open_url", { url: task.web_view_link }).catch((err) => console.error("[open_url]", err))}
      title="Open this task in the Google Tasks web app (to set a repeat, etc.)"
    >
      <Icon name="externalLink" size={14} />
      <span>Open in Google Tasks</span>
    </button>
  {/if}

  <div class="field">
    <label for="detail-due">Due date</label>
    <button id="detail-due" class="due-btn" class:empty={!due} onclick={() => (showDatePicker = true)}>
      {due || "No date"}
    </button>
    <div class="quick-dates">
      <button onclick={() => { const d = new Date(); saveDue(localISO(d)); }}>Today</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+1); saveDue(localISO(d)); }}>Tomorrow</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+7); saveDue(localISO(d)); }}>+1 week</button>
      <button onclick={() => { const d = new Date(); d.setMonth(d.getMonth()+1); saveDue(localISO(d)); }}>+1 month</button>
      <button onclick={() => saveDue("")}>Clear</button>
    </div>
  </div>

  {#if propagatedDue}
    <div class="field">
      <span class="field-label">From subtasks</span>
      <div class="inherited-due" title="Earliest due date among unfinished subtasks. Read-only — set on the subtasks. The task is sorted and filtered by whichever is earlier, this or its own due date.">
        ↳ {propagatedDue}
      </div>
    </div>
  {/if}

  <div class="field">
    <label for="detail-list">List</label>
    <select id="detail-list" value={selectedList} onchange={(e) => { selectedList = e.currentTarget.value; saveList(); }}>
      {#each lists as list}
        <option value={list.id}>{list.title}</option>
      {/each}
    </select>
  </div>

  <div class="field">
    <label for="detail-notes">Notes</label>
    <textarea id="detail-notes" bind:this={notesInput} bind:value={notes} onblur={saveNotes} placeholder="Add notes..." rows="6"></textarea>
  </div>

  {#if detectedLinks.length > 0}
    <div class="field">
      <span class="field-label">Links</span>
      <div class="links">
        {#each detectedLinks as url}
          <button class="link-chip" title={url} onclick={() => invokeWithTimeout("open_url", { url }).catch((err) => console.error("[open_url]", err))}>
            <Icon name="link" size={14} />
            <span>{url}</span>
          </button>
        {/each}
      </div>
    </div>
  {/if}

  {#if !parentTask}
    <div class="field">
      <div class="subtask-header">
        <span class="field-label">Subtasks</span>
        {#if completedSubtaskCount > 0}
          <label class="hide-completed-toggle">
            <input type="checkbox" bind:checked={hideCompletedSubtasks} aria-label="Hide completed subtasks" />
            Hide completed
          </label>
        {/if}
      </div>
      {#if visibleSubtasks.length > 0}
        <div class="subtask-list">
          {#each visibleSubtasks as sub}
            <div class="subtask-item" class:completed={sub.status === "completed"}>
              <input
                class="subtask-check"
                type="checkbox"
                checked={sub.status === "completed"}
                aria-label={sub.status === "completed" ? `Mark ${sub.title || "subtask"} incomplete` : `Mark ${sub.title || "subtask"} complete`}
                onclick={(e) => { e.stopPropagation(); e.preventDefault(); ontogglesubtask?.(sub.id); }}
              />
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <!-- svelte-ignore a11y_no_static_element_interactions -->
              <span class="subtask-title clickable" onclick={() => openSub(sub)}>{sub.title || "Untitled"}</span>
              <button
                class="subtask-due"
                class:empty={!subtaskDue(sub)}
                aria-label={`Subtask due date: ${subtaskDue(sub) || "No date"}`}
                title="Pick subtask due date"
                onclick={(e) => { e.stopPropagation(); openSubtaskDatePicker(sub); }}
              >
                {formatDue(sub.due) || "no date"}
              </button>
            </div>
          {/each}
        </div>
      {/if}
      <div class="subtask-add-row">
        <input
          class="subtask-add"
          type="text"
          bind:this={newSubtaskInput}
          bind:value={newSubtaskTitle}
          onkeydown={newSubtaskKeydown}
          placeholder="Add a subtask"
          aria-label="New subtask"
        />
        <button
          class="add-subtask-btn"
          title="Add subtask"
          aria-label="Add subtask"
          disabled={!newSubtaskTitle.trim()}
          onclick={submitNewSubtask}
        >+</button>
      </div>
    </div>
  {/if}

  <div class="danger-zone">
    <button class="delete-btn" onclick={() => { ondelete(task.id); onclose(); }}>
      <Icon name="trash" size={14} />
      <span>Delete task</span>
    </button>
  </div>
</aside>

{#if showDatePicker}
  <DatePicker
    value={due || null}
    onselect={(d) => { saveDue(d || ""); showDatePicker = false; }}
    onclose={() => (showDatePicker = false)}
  />
{/if}

{#if subtaskDatePickerTask}
  <DatePicker
    value={subtaskDue(subtaskDatePickerTask) || null}
    onselect={saveSubtaskDue}
    onclose={() => (subtaskDatePickerTask = null)}
  />
{/if}

<style>
  .detail-panel {
    width: 320px; background: var(--bg-sidebar); border-left: 1px solid var(--bg-elevated);
    display: flex; flex-direction: column; padding: 1rem; overflow-y: auto;
  }
  .panel-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
  .panel-nav { display: flex; align-items: center; gap: 0.3rem; }
  .nav-btn { background: none; border: 1px solid var(--border); color: var(--accent); width: 1.5rem; height: 1.5rem; border-radius: 3px; cursor: pointer; font-size: 1rem; line-height: 1; }
  .nav-btn:hover:not(:disabled) { background: var(--bg-hover); }
  .nav-btn:disabled { opacity: 0.3; cursor: default; }
  .panel-header h3 { margin: 0; font-size: 0.9rem; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.05em; }
  .breadcrumb { font-size: 0.8rem; color: var(--accent); cursor: pointer; margin-bottom: 0.75rem; padding: 0.3rem 0.5rem; background: var(--bg-hover); border-radius: 4px; }
  .breadcrumb:hover { background: var(--bg-active); }
  .detach-btn {
    width: 100%; margin: -0.35rem 0 0.75rem; background: none; border: 1px solid var(--border);
    color: var(--accent); padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer;
    font-size: 0.8rem; font-family: inherit; text-align: center;
  }
  .detach-btn:hover { background: var(--bg-hover); border-color: var(--accent); }
  .panel-actions { display: flex; gap: 0.4rem; }
  .open-google {
    display: inline-flex; align-items: center; justify-content: center; gap: 0.35rem;
    width: 100%; box-sizing: border-box; margin: 0 0 1rem;
    background: none; border: 1px solid var(--border); color: var(--accent);
    padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer;
    font-size: 0.8rem; font-family: inherit; text-align: center;
  }
  .open-google:hover { background: var(--bg-hover); border-color: var(--accent); }
  .close-btn { background: none; border: none; color: var(--fg-faint); cursor: pointer; font-size: 1.1rem; }
  .close-btn:hover { color: var(--fg); }

  .field { margin-bottom: 1rem; }
  .field label { display: block; font-size: 0.75rem; color: var(--fg-faint); text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 0.3rem; }
  .field-label { display: block; font-size: 0.75rem; color: var(--fg-faint); text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 0.3rem; }
  .links { display: flex; flex-direction: column; gap: 0.25rem; }
  .link-chip {
    display: inline-flex; align-items: center; gap: 0.35rem;
    width: 100%; box-sizing: border-box; text-align: left;
    background: var(--bg-sidebar); border: 1px solid var(--bg-elevated); border-radius: 4px;
    color: var(--accent); padding: 0.35rem 0.5rem; cursor: pointer; font-size: 0.78rem;
    font-family: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .link-chip span { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .link-chip:hover { background: var(--bg-hover); border-color: var(--accent); }
  .subtask-add-row { display: flex; align-items: center; gap: 0.4rem; margin-top: 0.4rem; }
  .subtask-add {
    flex: 1; min-width: 0; background: var(--bg-input); border: 1px solid var(--border);
    border-radius: 4px; color: var(--fg); padding: 0.4rem 0.5rem; font-size: 0.85rem;
    font-family: inherit; outline: none; box-sizing: border-box;
  }
  .subtask-add::placeholder { color: var(--fg-faint); }
  .subtask-add:focus { border-color: var(--accent); }
  .add-subtask-btn { flex: 0 0 auto; background: none; border: 1px solid var(--border); color: var(--accent); width: 1.9rem; height: 1.9rem; border-radius: 3px; cursor: pointer; font-size: 1rem; line-height: 1; }
  .add-subtask-btn:hover:not(:disabled) { background: var(--bg-hover); }
  .add-subtask-btn:disabled { opacity: 0.4; cursor: default; }
  .field input[type="text"], .field .due-btn, .field textarea, .field select {
    width: 100%; background: var(--bg-input); border: 1px solid var(--border); border-radius: 4px;
    color: var(--fg); padding: 0.5rem; font-size: 0.9rem; font-family: inherit; outline: none;
    box-sizing: border-box;
  }
  .due-btn { text-align: left; cursor: pointer; }
  .due-btn:hover { border-color: var(--accent); }
  .due-btn.empty { color: var(--fg-faint); }
  .inherited-due {
    font-style: italic; color: var(--fg-muted); font-size: 0.9rem;
    padding: 0.5rem; border: 1px dashed var(--border); border-radius: 4px;
  }
  .field input:focus, .field textarea:focus, .field select:focus { border-color: var(--accent); }
  .field textarea { resize: vertical; min-height: 100px; }
  .field select { cursor: pointer; }
  /* Style the dropdown popup itself — without this the <option> list inherits
     the OS default (white) background while keeping light text → unreadable. */
  .field select option { background: var(--bg); color: var(--fg); }

  .quick-dates { display: flex; gap: 0.3rem; margin-top: 0.4rem; flex-wrap: wrap; }
  .quick-dates button {
    background: var(--bg-elevated); border: none; color: var(--fg-muted); padding: 0.25rem 0.5rem;
    border-radius: 3px; font-size: 0.75rem; cursor: pointer;
  }
  .quick-dates button:hover { background: var(--bg-active); color: var(--accent); }

  .danger-zone { margin-top: auto; padding-top: 1rem; border-top: 1px solid var(--bg-elevated); }
  .delete-btn { display: inline-flex; align-items: center; justify-content: center; gap: 0.35rem; background: none; border: 1px solid var(--border-danger); color: var(--danger); padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; width: 100%; }
  .delete-btn:hover { background: var(--bg-danger); }

  .subtask-header { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; }
  .hide-completed-toggle { display: flex; align-items: center; gap: 0.3rem; font-size: 0.75rem; color: var(--fg-muted); cursor: pointer; user-select: none; }
  .hide-completed-toggle input { cursor: pointer; }
  .subtask-list { display: flex; flex-direction: column; gap: 0.3rem; }
  .subtask-item { display: flex; align-items: center; gap: 0.4rem; padding: 0.3rem 0.4rem; border-radius: 3px; }
  .subtask-item:hover { background: var(--bg-hover); }
  .subtask-item.completed .subtask-title { text-decoration: line-through; opacity: 0.5; }
  .subtask-check {
    cursor: pointer; width: 0.95rem; height: 0.95rem; margin: 0;
    accent-color: var(--accent); flex-shrink: 0;
  }
  .subtask-title { font-size: 0.85rem; flex: 1; min-width: 0; }
  .subtask-title.clickable { cursor: pointer; }
  .subtask-title.clickable:hover { text-decoration: underline; color: var(--accent); }
  .subtask-due {
    flex: 0 0 auto; background: var(--bg-input); border: 1px solid var(--border);
    color: var(--fg-muted); border-radius: 3px; cursor: pointer; font-size: 0.75rem;
    padding: 0.2rem 0.35rem; font-family: inherit;
  }
  .subtask-due.empty { color: var(--fg-faint); }
  .subtask-due:hover { border-color: var(--accent); color: var(--accent); }

  @media (max-width: 700px) {
    .detail-panel { width: 100%; position: fixed; inset: 0; z-index: 3000; }
  }
  @media (pointer: coarse) {
    .field input, .field textarea, .field select, .field .due-btn { padding: 0.6rem; font-size: 1rem; min-height: 44px; }
    .quick-dates button { padding: 0.5rem 0.8rem; font-size: 0.85rem; min-height: 44px; }
    .close-btn, .detach-btn { min-height: 44px; min-width: 44px; }
    .delete-btn { min-height: 44px; }
    .subtask-item { min-height: 44px; }
    .subtask-add { padding: 0.6rem; font-size: 1rem; min-height: 44px; }
    .add-subtask-btn { min-height: 44px; min-width: 44px; }
  }
</style>
