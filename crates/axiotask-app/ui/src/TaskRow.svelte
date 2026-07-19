<script>
  import Icon from "./Icon.svelte";
  import { invokeWithTimeout } from "./ipc.js";
  let { task, focused, editing, completing = false, selected = false, onrename, oncanceledit, onclick, onselect, ontoggle, onsetdue, onpickdate, oncontextmenu, onaddsubtask, ontogglecollapse, showList = false, subtaskProgress = null, draggable = false, ondragstart, ondragend, ondragover, ondrop } = $props();

  let touchTimer = $state(null);
  let touchDragging = $state(false);
  let isDragging = $state(false);
  let rowTouch = $state(null);
  let suppressNextClick = $state(false);
  let swipeActionsOpen = $state(false);
  let swipeActionsPeeking = $state(false);
  let swipeReveal = $state(0);

  function clearRowTouchTimer() {
    if (rowTouch?.timer) clearTimeout(rowTouch.timer);
    if (rowTouch) rowTouch.timer = null;
  }

  function handleRowTouchStart(e) {
    if (e.target.closest(".drag-handle, .checkbox, .actions, .edit-input, a, button")) return;
    const touch = e.touches?.[0];
    if (!touch) return;
    clearRowTouchTimer();
    const timer = setTimeout(() => {
      if (!rowTouch?.moved) {
        suppressNextClick = true;
        onselect?.(task.id);
      }
    }, 450);
    rowTouch = {
      startX: touch.clientX,
      startY: touch.clientY,
      lastX: touch.clientX,
      lastY: touch.clientY,
      moved: false,
      timer,
    };
  }

  function handleRowTouchMove(e) {
    if (!rowTouch) return;
    const touch = e.touches?.[0];
    if (!touch) return;
    rowTouch.lastX = touch.clientX;
    rowTouch.lastY = touch.clientY;
    const dx = touch.clientX - rowTouch.startX;
    const dy = touch.clientY - rowTouch.startY;
    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
      rowTouch.moved = true;
      clearRowTouchTimer();
    }
    if (dx < -10 && Math.abs(dx) > Math.abs(dy) * 1.25) {
      swipeActionsPeeking = true;
      swipeReveal = Math.min(Math.round(Math.abs(dx)), 112);
    } else if (swipeActionsPeeking) {
      swipeActionsPeeking = false;
      swipeReveal = 0;
    }
  }

  function handleRowTouchEnd() {
    if (!rowTouch) return;
    clearRowTouchTimer();
    const dx = rowTouch.lastX - rowTouch.startX;
    const dy = rowTouch.lastY - rowTouch.startY;
    const isHorizontalSwipe = Math.abs(dx) >= 80 && Math.abs(dx) > Math.abs(dy) * 1.5;
    if (isHorizontalSwipe) {
      suppressNextClick = true;
      if (dx > 0) {
        swipeActionsOpen = false;
        ontoggle?.(task.id);
      } else {
        swipeActionsOpen = true;
      }
    }
    swipeActionsPeeking = false;
    swipeReveal = 0;
    rowTouch = null;
  }

  function handleTouchStart(e) {
    if (!draggable) return;
    touchTimer = setTimeout(() => { touchDragging = true; }, 300);
  }
  function handleTouchMove(e) {
    if (touchTimer) { clearTimeout(touchTimer); touchTimer = null; }
  }
  function handleTouchEnd(e) {
    if (touchTimer) { clearTimeout(touchTimer); touchTimer = null; }
    touchDragging = false;
  }
  function handleDragStart(e) {
    if (!draggable) { e.preventDefault(); return; }
    e.dataTransfer.setData("text/plain", task.id);
    e.dataTransfer.effectAllowed = "move";
    isDragging = true;
    ondragstart?.(task.id);
  }
  function handleDragEnd(e) { isDragging = false; ondragend?.(); touchDragging = false; }
  function handleDragOver(e) { if (!draggable) return; e.preventDefault(); ondragover?.(task.id, e.clientY); }
  function handleDrop(e) { if (!draggable) return; e.preventDefault(); ondrop?.(task.id, e.clientY); }

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
    if (suppressNextClick) {
      suppressNextClick = false;
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (e.target.closest(".checkbox, .edit-input, .actions")) return;
    if (swipeActionsOpen) {
      swipeActionsOpen = false;
      return;
    }
    if (e.ctrlKey || e.metaKey) { onselect?.(task.id); return; }
    onclick?.(task.id);
  }

  function handleTitleDblClick(e) {
    e.stopPropagation();
    onclick?.(task.id, "edit");
  }

  function handleCheckboxClick(e) {
    e.preventDefault();
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
    swipeActionsOpen = false;
    onsetdue?.(task.id, mv);
  }

  function handleToggleCollapse(e) {
    e.preventDefault();
    e.stopPropagation();
    ontogglecollapse?.(task.id);
  }

  // URL detection
  function extractUrls(text) {
    if (!text) return [];
    const re = /https?:\/\/[^\s)>\]]+/g;
    return text.match(re) || [];
  }
  // URLs and the notes badge use the task's notes directly.
  let urls = $derived([...extractUrls(task.title), ...extractUrls(task.notes || "")]);
  let hasVisibleNotes = $derived((task.notes || "").length > 0);

  function parseLocalDate(due) {
    // Due dates are date-only. Parse YYYY-MM-DD portion to avoid timezone shift.
    const [y, m, d] = due.slice(0, 10).split("-").map(Number);
    return new Date(y, m - 1, d);
  }

  function formatDue(due) {
    if (!due) return "";
    const d = parseLocalDate(due);
    const now = new Date(); now.setHours(0,0,0,0);
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
    const d = parseLocalDate(due);
    const now = new Date(); now.setHours(0,0,0,0);
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
  class:selected
  class:swipe-actions-open={swipeActionsOpen}
  class:swipe-actions-peeking={swipeActionsPeeking}
  class:touch-dragging={touchDragging}
  class:dragging={isDragging}
  style="padding-left: {task.depth * 1.5 + 0.5}rem; --swipe-reveal: {swipeReveal}px"
  onclick={handleRowClick}
  ontouchstart={handleRowTouchStart}
  ontouchmove={handleRowTouchMove}
  ontouchend={handleRowTouchEnd}
  ontouchcancel={handleRowTouchEnd}
  oncontextmenu={handleContextMenu}
  ondragover={handleDragOver}
  ondrop={handleDrop}
  data-testid="drop-zone"
>
  <!-- Line 1: Main row -->
  <div class="main-row">
    {#if draggable}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span
        class="drag-handle"
        data-testid="drag-handle"
        draggable="true"
        ondragstart={handleDragStart}
        ondragend={handleDragEnd}
        ontouchstart={handleTouchStart}
        ontouchmove={handleTouchMove}
        ontouchend={handleTouchEnd}
      >⠿</span>
    {/if}
    {#if task.hasChildren}
      <button
        class="tree-icon tree-toggle"
        type="button"
        aria-label={task.isCollapsed ? `Expand ${task.title || "task"}` : `Collapse ${task.title || "task"}`}
        aria-expanded={!task.isCollapsed}
        onclick={handleToggleCollapse}
      >
        {task.isCollapsed ? "▸" : "▾"}
      </button>
    {:else if task.parent_id}
      <span class="tree-icon sub">└</span>
    {:else}
      <span class="tree-icon"></span>
    {/if}

    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <input
      class="checkbox"
      type="checkbox"
      checked={task.status === "completed"}
      aria-label={task.status === "completed" ? `Mark ${task.title || "task"} incomplete` : `Mark ${task.title || "task"} complete`}
      onclick={handleCheckboxClick}
    />

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

    {#if task.sync_state === "dirty"}
      <span class="sync-pending" title="Not synced to Google yet" aria-label="Pending sync">●</span>
    {/if}

    <!-- Quick actions (hover) -->
    <span class="actions" aria-label="Task actions">
      <button onclick={(e) => { e.stopPropagation(); onaddsubtask?.(task.id); }} title="Add subtask">+</button>
      <button onclick={(e) => handleDateAction(e, "Today")} title="Today (o)">→o</button>
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
    {#if hasVisibleNotes}
      <span class="badge notes-icon" title="Has notes" aria-label="Has notes">
        <Icon name="fileText" size={13} />
      </span>
    {/if}
    {#if urls.length > 0}
      <a class="badge link-badge" href={urls[0]} onclick={(e) => { e.preventDefault(); e.stopPropagation(); invokeWithTimeout("open_url", { url: urls[0] }).catch((err) => console.error("[open_url]", err)); }} title={urls[0]} aria-label="Open link">
        <Icon name="externalLink" size={13} />{#if urls.length > 1}<span class="link-count">{urls.length}</span>{/if}
      </a>
    {/if}
    {#if task.due}
      <span class="scheduled-marker" title="Scheduled" aria-label="Scheduled"><Icon name="calendar" size={13} /></span>
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="due {dueClass(task.due)} pickable" title="Pick a date" onclick={(e) => { e.stopPropagation(); onpickdate?.(task.id); }}>{formatDue(task.due)}</span>
    {:else if task.inheritedDue}
      <!-- Date inherited from the earliest unfinished subtask. Read-only marker
           (↳), but still clickable to set the task's own explicit date. -->
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="due inherited {dueClass(task.inheritedDue)} pickable" title="Earliest subtask date — used for sorting and filtering. Click to set this task's own date." onclick={(e) => { e.stopPropagation(); onpickdate?.(task.id); }}>↳ {formatDue(task.inheritedDue)}</span>
    {:else}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="no-due pickable" title="Pick a date" onclick={(e) => { e.stopPropagation(); onpickdate?.(task.id); }}>no date</span>
    {/if}
    {#if subtaskProgress}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="progress" title="{subtaskProgress.done}/{subtaskProgress.total} subtasks" onclick={handleToggleCollapse}>
        <span class="progress-bar"><span class="progress-fill" style="width: {(subtaskProgress.done / subtaskProgress.total) * 100}%"></span></span>
        <span class="progress-text">{subtaskProgress.done}/{subtaskProgress.total}</span>
      </span>
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
  .task-widget:hover { background: var(--bg-hover); }
  .task-widget.focused { background: var(--bg-active); }
  .task-widget.selected { box-shadow: inset 3px 0 0 var(--accent); background: var(--bg-active); }
  .task-widget.selected.focused { background: var(--bg-active); }
  .task-widget.swipe-actions-open, .task-widget.swipe-actions-peeking { background: var(--bg-active); }
  .task-widget.completing { opacity: 0.5; transform: scale(0.98); }
  .task-widget.completing .title { text-decoration: line-through; }
  .task-widget.completed { opacity: 0.5; transform: scale(0.98); }
  .task-widget.completed .title { text-decoration: line-through; }
  .task-widget.completed .meta-row { opacity: 0.6; }
  .task-widget.dragging { opacity: 0.4; }
  .task-widget.touch-dragging { opacity: 0.6; transform: scale(1.02); box-shadow: 0 4px 12px rgba(0,0,0,0.4); }

  .drag-handle { flex-shrink: 0; cursor: grab; color: var(--fg-faint); font-size: 0.9rem; user-select: none; padding: 0 0.2rem; }
  .drag-handle:hover { color: var(--accent); }
  .drag-handle:active { cursor: grabbing; }

  .main-row { display: flex; align-items: center; gap: 0.4rem; }

  .tree-icon { flex-shrink: 0; width: 1rem; text-align: center; font-size: 0.7rem; color: var(--fg-faint); }
  .tree-toggle {
    border: 0; background: transparent; padding: 0; height: 1.25rem; cursor: pointer;
    display: inline-flex; align-items: center; justify-content: center; font-family: inherit;
  }
  .tree-toggle:hover { color: var(--accent); }
  .tree-icon.sub { color: var(--border-faint); font-size: 0.75rem; }

  .checkbox {
    flex-shrink: 0; width: 1rem; height: 1rem; margin: 0; cursor: pointer;
    accent-color: var(--accent);
  }
  .checkbox:hover { outline: 1px solid var(--accent); outline-offset: 2px; }

  .title { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 0.9rem; cursor: text; }
  .title:hover { text-decoration: underline; text-decoration-color: var(--border-faint); }

  .actions { display: none; gap: 0.2rem; flex-shrink: 0; }
  .task-widget:hover .actions, .task-widget.focused .actions, .task-widget.swipe-actions-open .actions, .task-widget.swipe-actions-peeking .actions { display: flex; }
  .actions button {
    background: var(--bg-elevated); border: none; color: var(--fg-muted); padding: 0.15rem 0.35rem;
    border-radius: 3px; font-size: 0.7rem; cursor: pointer; font-family: inherit;
    min-width: 2rem; min-height: 1.5rem; display: flex; align-items: center; justify-content: center;
  }
  .actions button:hover { background: var(--bg-active); color: var(--accent); }

  /* Touch/mobile: hide actions until the row is swiped left, then keep 44px tap targets. */
  @media (pointer: coarse) {
    .actions, .task-widget:hover .actions, .task-widget.focused .actions { display: none; }
    .task-widget.swipe-actions-open .actions, .task-widget.swipe-actions-peeking .actions { display: flex; }
    .task-widget.swipe-actions-peeking .main-row { transform: translateX(calc(var(--swipe-reveal) * -0.35)); }
    .actions button { min-width: 44px; min-height: 44px; font-size: 0.8rem; padding: 0.3rem 0.5rem; }
    .checkbox { width: 1.3rem; height: 1.3rem; min-width: 44px; min-height: 44px; }
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

  @media (max-width: 600px) and (pointer: coarse) {
    .actions, .task-widget:hover .actions, .task-widget.focused .actions { display: none; }
    .task-widget.swipe-actions-open .actions, .task-widget.swipe-actions-peeking .actions { display: flex; }
  }

  /* Metadata row */
  .meta-row {
    display: flex; align-items: center; gap: 0.5rem;
    padding: 0.2rem 0 0 2.4rem; font-size: 0.75rem;
  }

  .progress { display: flex; align-items: center; gap: 0.3rem; cursor: pointer; }
  .progress-bar { display: inline-block; width: 60px; height: 6px; background: var(--bg-elevated); border-radius: 3px; overflow: hidden; }
  .progress-fill { display: block; height: 100%; background: var(--accent); border-radius: 3px; transition: width 0.2s; }
  .progress-text { color: var(--fg-secondary); }

  .badge { font-size: 0.7rem; cursor: default; display: inline-flex; align-items: center; gap: 0.2rem; }
  .link-badge { text-decoration: none; color: var(--accent); cursor: pointer; }
  .link-badge:hover { text-decoration: underline; }
  .link-count { color: var(--fg-secondary); font-size: 0.7rem; }

  /* Pending-sync dot: a local change not yet pushed to Google. */
  .sync-pending { color: var(--warning); font-size: 0.5rem; line-height: 1; flex-shrink: 0; cursor: default; }

  .scheduled-marker { font-size: 0.7rem; cursor: default; flex-shrink: 0; }
  .due { color: var(--fg-muted); }
  .due.overdue { color: var(--danger); font-weight: 600; }
  .due.due-today { color: var(--warning); }
  /* Inherited (propagated from a subtask): dimmer + italic so it reads as
     borrowed, not set on this task. */
  .due.inherited { font-style: italic; opacity: 0.8; }
  .no-due { color: var(--border-faint); }
  .pickable { cursor: pointer; }
  .pickable:hover { text-decoration: underline; }
  .list-tag { color: var(--fg-faint); background: var(--bg-elevated); padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.65rem; }

  .edit-input {
    flex: 1; background: var(--bg-input); border: 1px solid var(--bg-active);
    color: var(--fg); padding: 0.3rem 0.5rem; border-radius: 3px;
    font-size: 0.9rem; outline: none;
  }
</style>
