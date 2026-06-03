<script>
  import { invoke } from "@tauri-apps/api/core";
  let { task, focused, editing, completing = false, onrename, oncanceledit, onclick, ontoggle, onsetdue, oncontextmenu, onaddsubtask, showList = false, subtaskProgress = null } = $props();

  let editInput = $state(null);
  let editValue = $state("");

  $effect(() => {
    if (editing && editInput) {
      editValue = task.title || "";
      setTimeout(() => { if (editInput) { editInput.focus(); editInput.select(); } }, 0);
    }
  });

  let rowEl = $state(null);
  $effect(() => { if (focused && rowEl) rowEl.scrollIntoView({ block: "nearest" }); });

  function handleEditKey(e) {
    if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); onrename(task.id, editValue); }
    else if (e.key === "Escape") { e.preventDefault(); oncanceledit(); }
  }

  function handleRowClick(e) {
    if (e.target.closest(".checkbox, .edit-input, .actions")) return;
    onclick?.(task.id);
  }

  function handleTitleDblClick(e) {
    e.stopPropagation();
    onclick?.(task.id, "edit");
  }

  function handleCheckboxClick(e) {
    e.stopPropagation();
    ontoggle?.(task.id);
  }

  function handleContextMenu(e) {
    e.preventDefault();
    e.stopPropagation();
    oncontextmenu?.(task, e.clientX, e.clientY);
  }

  function handleDateAction(e, mv) {
    e.stopPropagation();
    onsetdue?.(task.id, mv);
  }

  // URL detection
  function extractUrls(text) {
    if (!text) return [];
    const re = /https?:\/\/[^\s)>\]]+/g;
    return text.match(re) || [];
  }
  let urls = $derived([...extractUrls(task.title), ...extractUrls(task.notes)]);

  // Recurrence detection (Google Tasks uses "RFC 5545" style in notes or a hidden field)
  let isRecurrent = $derived(task.title?.includes("🔁") || task.notes?.includes("recur") || task.notes?.includes("repeat") || false);

  function formatDue(due) {
    if (!due) return "";
    const d = new Date(due); const now = new Date();
    d.setHours(0,0,0,0); now.setHours(0,0,0,0);
    const diff = Math.round((d - now) / 86400000);
    if (diff < -1) return `${-diff}d overdue`;
    if (diff === -1) return "yesterday";
    if (diff === 0) return "today";
    if (diff === 1) return "tomorrow";
    if (diff < 7) return `in ${diff}d`;
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  function dueClass(due) {
    if (!due) return "";
    const d = new Date(due); const now = new Date();
    d.setHours(0,0,0,0); now.setHours(0,0,0,0);
    if (d < now) return "overdue";
    if (d.getTime() === now.getTime()) return "due-today";
    return "";
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  bind:this={rowEl}
  class="task-widget"
  class:focused
  class:completing
  class:completed={task.status === "completed"}
  style="padding-left: {task.depth * 1.5 + 0.5}rem"
  onclick={handleRowClick}
  oncontextmenu={handleContextMenu}
>
  <!-- Line 1: Main row -->
  <div class="main-row">
    {#if task.hasChildren}
      <span class="tree-icon">{task.isCollapsed ? "▸" : "▾"}</span>
    {:else if task.parent_id}
      <span class="tree-icon sub">└</span>
    {:else}
      <span class="tree-icon"></span>
    {/if}

    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <span class="checkbox" onclick={handleCheckboxClick}>
      {task.status === "completed" ? "☑" : "☐"}
    </span>

    {#if editing}
      <input
        bind:this={editInput}
        bind:value={editValue}
        onkeydown={handleEditKey}
        onblur={() => onrename(task.id, editValue)}
        class="edit-input"
      />
    {:else}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="title" ondblclick={handleTitleDblClick}>{task.title || "Untitled"}</span>
    {/if}

    <!-- Quick actions (hover) -->
    <span class="actions">
      <button onclick={(e) => { e.stopPropagation(); onaddsubtask?.(task.id); }} title="Add subtask">+</button>
      <button onclick={(e) => handleDateAction(e, "Tomorrow")} title="Tomorrow (t)">→t</button>
      <button onclick={(e) => handleDateAction(e, "NextWeek")} title="Next week (w)">→w</button>
      <button onclick={(e) => handleDateAction(e, "NextMonth")} title="Next month (m)">→m</button>
      {#if task.due}
        <button onclick={(e) => handleDateAction(e, "Clear")} title="Remove date (r)">✕</button>
      {/if}
    </span>
  </div>

  <!-- Line 2: Metadata (shown when focused or hovered) -->
  <div class="meta-row">
    {#if subtaskProgress}
      <span class="progress" title="{subtaskProgress.done}/{subtaskProgress.total} subtasks">
        <span class="progress-bar"><span class="progress-fill" style="width: {(subtaskProgress.done / subtaskProgress.total) * 100}%"></span></span>
        <span class="progress-text">{subtaskProgress.done}/{subtaskProgress.total}</span>
      </span>
    {/if}
    {#if task.notes}
      <span class="badge" title="Has notes">📝</span>
    {/if}
    {#if urls.length > 0}
      <a class="badge link-badge" href={urls[0]} onclick={(e) => { e.preventDefault(); e.stopPropagation(); invoke("open_url", { url: urls[0] }); }} title={urls[0]}>🔗{urls.length > 1 ? ` ${urls.length}` : ""}</a>
    {/if}
    {#if isRecurrent}
      <span class="badge" title="Recurring">🔁</span>
    {/if}
    {#if task.due}
      <span class="due {dueClass(task.due)}">{formatDue(task.due)}</span>
    {:else}
      <span class="no-due">no date</span>
    {/if}
    {#if showList && task.listTitle}
      <span class="list-tag">{task.listTitle}</span>
    {/if}
  </div>
</div>

<style>
  .task-widget {
    border-radius: 4px; cursor: pointer; transition: background 0.1s, opacity 0.3s, transform 0.3s;
    padding: 0.4rem 0.5rem;
  }
  .task-widget:hover { background: #1a2a4a; }
  .task-widget.focused { background: #0f3460; }
  .task-widget.completing { opacity: 0.5; transform: scale(0.98); }
  .task-widget.completing .title { text-decoration: line-through; }
  .task-widget.completed { opacity: 0.5; transform: scale(0.98); }
  .task-widget.completed .title { text-decoration: line-through; }
  .task-widget.completed .meta-row { opacity: 0.6; }

  .main-row { display: flex; align-items: center; gap: 0.4rem; }

  .tree-icon { flex-shrink: 0; width: 1rem; text-align: center; font-size: 0.7rem; color: #666; }
  .tree-icon.sub { color: #3a3a5a; font-size: 0.75rem; }

  .checkbox { flex-shrink: 0; font-size: 1rem; cursor: pointer; }
  .checkbox:hover { transform: scale(1.2); }

  .title { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 0.9rem; cursor: text; }
  .title:hover { text-decoration: underline; text-decoration-color: #3a3a5a; }

  .actions { display: none; gap: 0.2rem; flex-shrink: 0; }
  .task-widget:hover .actions, .task-widget.focused .actions { display: flex; }
  .actions button {
    background: #2a2a4a; border: none; color: #888; padding: 0.15rem 0.35rem;
    border-radius: 3px; font-size: 0.7rem; cursor: pointer; font-family: inherit;
    min-width: 2rem; min-height: 1.5rem; display: flex; align-items: center; justify-content: center;
  }
  .actions button:hover { background: #0f3460; color: #7ec8e3; }

  /* Touch/mobile: always show actions, 44px min tap targets */
  @media (pointer: coarse) {
    .actions { display: flex; }
    .actions button { min-width: 44px; min-height: 44px; font-size: 0.8rem; padding: 0.3rem 0.5rem; }
    .checkbox { font-size: 1.3rem; padding: 0.2rem; min-width: 44px; min-height: 44px; display: flex; align-items: center; justify-content: center; }
    .task-widget { padding: 0.6rem 0.5rem; min-height: 44px; }
    .title { font-size: 1rem; }
    .meta-row { font-size: 0.8rem; padding-top: 0.3rem; }
  }

  /* Small screens: stack layout */
  @media (max-width: 600px) {
    .actions { display: flex; }
    .main-row { flex-wrap: wrap; }
    .actions { width: 100%; padding-left: 2.4rem; margin-top: 0.2rem; }
  }

  /* Metadata row */
  .meta-row {
    display: flex; align-items: center; gap: 0.5rem;
    padding: 0.2rem 0 0 2.4rem; font-size: 0.75rem;
  }

  .progress { display: flex; align-items: center; gap: 0.3rem; }
  .progress-bar { width: 50px; height: 4px; background: #2a2a4a; border-radius: 2px; overflow: hidden; }
  .progress-fill { height: 100%; background: #4caf50; border-radius: 2px; transition: width 0.2s; }
  .progress-text { color: #888; }

  .badge { font-size: 0.7rem; cursor: default; }
  .link-badge { text-decoration: none; color: #7ec8e3; cursor: pointer; }
  .link-badge:hover { text-decoration: underline; }

  .due { color: #888; }
  .due.overdue { color: #e74c3c; font-weight: 600; }
  .due.due-today { color: #ff9800; }
  .no-due { color: #3a3a5a; }
  .list-tag { color: #555; background: #2a2a4a; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.65rem; }

  .edit-input {
    flex: 1; background: #1a1a3e; border: 1px solid #0f3460;
    color: #e0e0e0; padding: 0.3rem 0.5rem; border-radius: 3px;
    font-size: 0.9rem; outline: none;
  }
</style>
