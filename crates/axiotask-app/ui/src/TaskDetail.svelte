<script>
  import { invoke } from "@tauri-apps/api/core";
  let { task, parentTask, lists, subtasks = [], onsave, onclose, ondelete, onmovelist, ontogglesubtask, onopensubtask, onopenparent, onaddsubtask, onprev, onnext } = $props();

  let title = $state("");
  let notes = $state("");
  let due = $state("");
  let selectedList = $state("");

  let prevTaskId = $state(null);
  // The task's values when it was loaded, so we only save fields the user
  // actually changed. Saving unchanged fields would needlessly mark the task
  // dirty and trigger a push (and, if it races another push, a 412 conflict).
  let orig = $state({ title: "", notes: "", due: "", list: "" });

  // Clickable links found in the title or notes (deduped, live as you type).
  function extractUrls(text) {
    return text ? (text.match(/https?:\/\/[^\s)>\]]+/g) || []) : [];
  }
  let detectedLinks = $derived([...new Set([...extractUrls(title), ...extractUrls(notes)])]);

  const dueOf = (d) => (d ? `${d}T00:00:00.000Z` : null);

  // Only the { title, notes, due } fields that differ from the loaded values.
  function changedFields() {
    const out = {};
    if (title !== orig.title) out.title = title;
    if (notes !== orig.notes) out.notes = notes;
    if (dueOf(due) !== dueOf(orig.due)) out.due = dueOf(due);
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

  // Reset when task changes. Compute from `task` only (not from the editable
  // vars) so this effect depends solely on `task` — otherwise editing a field
  // would re-trigger it and wipe the edit.
  $effect(() => {
    if (task) {
      const t = task.title || "";
      const n = task.notes || "";
      const d = task.due ? task.due.slice(0, 10) : "";
      const l = task.listId || "";
      title = t; notes = n; due = d; selectedList = l;
      orig = { title: t, notes: n, due: d, list: l };
      prevTaskId = task.id;
    }
  });

  function save() {
    const ch = changedFields();
    if (Object.keys(ch).length) onsave(task.id, ch);
    if (selectedList !== orig.list) onmovelist(task.id, selectedList);
  }

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); close(); }
    if (e.key === "s" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); save(); }
    if (e.key === "ArrowLeft" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); goPrev(); }
    if (e.key === "ArrowRight" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); goNext(); }
  }

  function goToParent() { save(); onopenparent?.(parentTask); }
  function openSub(sub) { save(); onopensubtask?.(sub); }
  function close() { save(); onclose(); }
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
      <button class="save-btn" onclick={save}>Save</button>
      <button class="close-btn" onclick={close}>✕</button>
    </div>
  </div>

  {#if parentTask}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="breadcrumb" onclick={goToParent}>
      ← {parentTask.title || "Parent task"}
    </div>
  {/if}

  <div class="field">
    <label for="detail-title">Title</label>
    <input id="detail-title" type="text" bind:value={title} placeholder="Task title" />
  </div>

  {#if task.web_view_link}
    <button
      class="open-google"
      onclick={() => invoke("open_url", { url: task.web_view_link })}
      title="Open this task in the Google Tasks web app (to set a repeat, etc.)"
    >
      ↗ Open in Google Tasks
    </button>
  {/if}

  <div class="field">
    <label for="detail-due">Due date</label>
    <input id="detail-due" type="date" bind:value={due} />
    <div class="quick-dates">
      <button onclick={() => { const d = new Date(); due = d.toISOString().slice(0,10); }}>Today</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+1); due = d.toISOString().slice(0,10); }}>Tomorrow</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+7); due = d.toISOString().slice(0,10); }}>+1 week</button>
      <button onclick={() => { const d = new Date(); d.setMonth(d.getMonth()+1); due = d.toISOString().slice(0,10); }}>+1 month</button>
      <button onclick={() => due = ""}>Clear</button>
    </div>
  </div>

  <div class="field">
    <label for="detail-list">List</label>
    <select id="detail-list" value={selectedList} onchange={(e) => (selectedList = e.currentTarget.value)}>
      {#each lists as list}
        <option value={list.id}>{list.title}</option>
      {/each}
    </select>
  </div>

  <div class="field">
    <label for="detail-notes">Notes</label>
    <textarea id="detail-notes" bind:value={notes} placeholder="Add notes..." rows="6"></textarea>
  </div>

  {#if detectedLinks.length > 0}
    <div class="field">
      <span class="field-label">Links</span>
      <div class="links">
        {#each detectedLinks as url}
          <button class="link-chip" title={url} onclick={() => invoke("open_url", { url })}>🔗 {url}</button>
        {/each}
      </div>
    </div>
  {/if}

  {#if !parentTask}
    <div class="field">
      <div class="field-header">
        <span class="field-label">Subtasks</span>
        <button class="add-subtask-btn" onclick={() => onaddsubtask?.(task.id)}>+</button>
      </div>
      {#if subtasks.length > 0}
        <div class="subtask-list">
          {#each subtasks as sub}
            <div class="subtask-item" class:completed={sub.status === "completed"}>
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <!-- svelte-ignore a11y_no_static_element_interactions -->
              <span class="subtask-check" onclick={() => ontogglesubtask?.(sub.id)}>
                {sub.status === "completed" ? "☑" : "☐"}
              </span>
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <!-- svelte-ignore a11y_no_static_element_interactions -->
              <span class="subtask-title clickable" onclick={() => openSub(sub)}>{sub.title || "Untitled"}</span>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}

  <div class="danger-zone">
    <button class="delete-btn" onclick={() => { ondelete(task.id); onclose(); }}>🗑️ Delete task</button>
  </div>
</aside>

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
  .panel-actions { display: flex; gap: 0.4rem; }
  .save-btn { background: var(--bg-active); color: var(--accent); border: none; padding: 0.3rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; }
  .open-google {
    display: block; width: 100%; box-sizing: border-box; margin: 0 0 1rem;
    background: none; border: 1px solid var(--border); color: var(--accent);
    padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer;
    font-size: 0.8rem; font-family: inherit; text-align: center;
  }
  .open-google:hover { background: var(--bg-hover); border-color: var(--accent); }
  .save-btn:hover { background: var(--bg-active); }
  .close-btn { background: none; border: none; color: var(--fg-faint); cursor: pointer; font-size: 1.1rem; }
  .close-btn:hover { color: var(--fg); }

  .field { margin-bottom: 1rem; }
  .field label { display: block; font-size: 0.75rem; color: var(--fg-faint); text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 0.3rem; }
  .field-label { display: block; font-size: 0.75rem; color: var(--fg-faint); text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 0.3rem; }
  .links { display: flex; flex-direction: column; gap: 0.25rem; }
  .link-chip {
    display: block; width: 100%; box-sizing: border-box; text-align: left;
    background: var(--bg-sidebar); border: 1px solid var(--bg-elevated); border-radius: 4px;
    color: var(--accent); padding: 0.35rem 0.5rem; cursor: pointer; font-size: 0.78rem;
    font-family: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .link-chip:hover { background: var(--bg-hover); border-color: var(--accent); }
  .field-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.3rem; }
  .add-subtask-btn { background: none; border: 1px solid var(--border); color: var(--accent); width: 1.4rem; height: 1.4rem; border-radius: 3px; cursor: pointer; font-size: 0.9rem; line-height: 1; }
  .add-subtask-btn:hover { background: var(--bg-hover); }
  .field input[type="text"], .field input[type="date"], .field textarea, .field select {
    width: 100%; background: var(--bg-input); border: 1px solid var(--border); border-radius: 4px;
    color: var(--fg); padding: 0.5rem; font-size: 0.9rem; font-family: inherit; outline: none;
    box-sizing: border-box;
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
  .delete-btn { background: none; border: 1px solid var(--border-danger); color: var(--danger); padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; width: 100%; }
  .delete-btn:hover { background: var(--bg-danger); }

  .subtask-list { display: flex; flex-direction: column; gap: 0.3rem; }
  .subtask-item { display: flex; align-items: center; gap: 0.4rem; padding: 0.3rem 0.4rem; border-radius: 3px; }
  .subtask-item:hover { background: var(--bg-hover); }
  .subtask-item.completed .subtask-title { text-decoration: line-through; opacity: 0.5; }
  .subtask-check { cursor: pointer; font-size: 0.9rem; }
  .subtask-title { font-size: 0.85rem; }
  .subtask-title.clickable { cursor: pointer; }
  .subtask-title.clickable:hover { text-decoration: underline; color: var(--accent); }

  @media (max-width: 700px) {
    .detail-panel { width: 100%; position: fixed; inset: 0; z-index: 3000; }
  }
  @media (pointer: coarse) {
    .field input, .field textarea, .field select { padding: 0.6rem; font-size: 1rem; min-height: 44px; }
    .quick-dates button { padding: 0.5rem 0.8rem; font-size: 0.85rem; min-height: 44px; }
    .save-btn, .close-btn { min-height: 44px; min-width: 44px; }
    .delete-btn { min-height: 44px; }
    .subtask-item { min-height: 44px; }
  }
</style>
