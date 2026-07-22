<script>
  import Icon from "./Icon.svelte";
  import TaskRow from "./TaskRow.svelte";

  let { tasks, focusIndex, editingId, completingIds = new Set(), selectedIds = new Set(), onrename, oncanceledit, onfocus, onselect, ontoggle, onsetdue, onpickdate, oncontextmenu, onaddsubtask, getSubtaskProgress, showCompleted, viewType = "focus", sortMode = "manual", onreorder } = $props();

  let draggingId = $state(null);
  let dropTargetIdx = $state(null);

  function handleDragStart(taskId) { draggingId = taskId; }
  function handleDragEnd() { draggingId = null; dropTargetIdx = null; }
  function handleDragOver(taskId, clientY) {
    const idx = tasks.findIndex(t => t.id === taskId);
    if (idx >= 0) dropTargetIdx = idx;
  }
  function handleDrop(taskId) {
    if (!draggingId || draggingId === taskId) { handleDragEnd(); return; }
    const fromIdx = tasks.findIndex(t => t.id === draggingId);
    const toIdx = tasks.findIndex(t => t.id === taskId);
    if (fromIdx < 0 || toIdx < 0) { handleDragEnd(); return; }
    const direction = toIdx > fromIdx ? "down" : "up";
    // Count sibling rows only — rendered rows interleave subtask rows and
    // cross-list smart-view cards, and the backend reorders among same-list
    // siblings (see ListView.handleDrop).
    const parentOf = (t) => t.parent_id ?? null;
    const dragParent = parentOf(tasks[fromIdx]);
    const dragListId = tasks[fromIdx].listId;
    const [lo, hi] = fromIdx < toIdx ? [fromIdx + 1, toIdx] : [toIdx, fromIdx - 1];
    let steps = 0;
    for (let i = lo; i <= hi; i++) {
      if (parentOf(tasks[i]) === dragParent && tasks[i].listId === dragListId) steps++;
    }
    if (steps > 0) onreorder?.(draggingId, direction, steps);
    handleDragEnd();
  }

  function parseDueDate(due) {
    if (!due) return null;
    const [year, month, day] = due.slice(0, 10).split("-").map(Number);
    if (!year || !month || !day) return null;
    return new Date(year, month - 1, day);
  }

  function isOverdue(task) {
    // A card is overdue by its EFFECTIVE date: its own due, or the date
    // inherited from its earliest unfinished subtask (that inheritance is
    // exactly what pulled it into Focus, and the row shows "↳ overdue").
    const due = parseDueDate(task.due || task.inheritedDue);
    if (!due) return false;
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return due < today;
  }

  let indexedTasks = $derived(tasks.map((task, i) => ({ task, i })));
  // Every row is a top-level card (subtasks live in the detail panel), so this
  // just splits the cards into Overdue vs. the rest by their effective date.
  function partitionByCard(items) {
    const overdue = [];
    const rest = [];
    let bucket = rest;
    for (const item of items) {
      if ((item.task.depth ?? 0) === 0) bucket = isOverdue(item.task) ? overdue : rest;
      bucket.push(item);
    }
    return { overdue, rest };
  }
  let sections = $derived(viewType === "focus" ? partitionByCard(indexedTasks) : { overdue: [], rest: indexedTasks });
  let overdueItems = $derived(sections.overdue);
  let nonOverdueItems = $derived(sections.rest);
  // The heading counts cards, matching the sidebar badge semantics.
  let overdueCardCount = $derived(overdueItems.filter(({ task }) => (task.depth ?? 0) === 0).length);

  const emptyStates = {
    focus: { icon: "checkCircle", text: "All clear for this week", sub: "Nothing needs your attention right now." },
    upcoming: { icon: "calendar", text: "Nothing upcoming", sub: "No tasks due in the next 14 days." },
    missed: { icon: "checkCircle", text: "Nothing overdue", sub: "You're all caught up!" },
    unscheduled: { icon: "checkCircle", text: "Everything is scheduled", sub: "All tasks have a due date." },
  };
</script>

<div class="smart-view">
  {#if tasks.length > 0}
    {#if overdueItems.length > 0}
      <section class="task-section" aria-labelledby="overdue-heading">
        <h2 id="overdue-heading" class="section-heading">Overdue ({overdueCardCount})</h2>
        {#each overdueItems as { task, i }}
          {#if dropTargetIdx === i && draggingId && tasks[i]?.id !== draggingId}
            <div class="drop-indicator"></div>
          {/if}
          <TaskRow
            {task}
            focused={i === focusIndex}
            editing={editingId === task.id}
            completing={completingIds.has(task.id)}
            selected={selectedIds.has(task.id)}
            {onrename}
            {oncanceledit}
            onclick={(id, action) => action === "edit" ? onfocus?.(i, "edit") : onfocus?.(i)}
            {onselect}
            {ontoggle}
            {onsetdue}
            {onpickdate}
            {oncontextmenu}
            {onaddsubtask}
            subtaskProgress={getSubtaskProgress?.(task.id)}
            showList={true}
            draggable={sortMode === "manual"}
            ondragstart={handleDragStart}
            ondragend={handleDragEnd}
            ondragover={handleDragOver}
            ondrop={handleDrop}
          />
        {/each}
      </section>
    {/if}
    {#each nonOverdueItems as { task, i }}
      {#if dropTargetIdx === i && draggingId && tasks[i]?.id !== draggingId}
        <div class="drop-indicator"></div>
      {/if}
      <TaskRow
        {task}
        focused={i === focusIndex}
        editing={editingId === task.id}
        completing={completingIds.has(task.id)}
        selected={selectedIds.has(task.id)}
        {onrename}
        {oncanceledit}
        onclick={(id, action) => action === "edit" ? onfocus?.(i, "edit") : onfocus?.(i)}
        {onselect}
        {ontoggle}
        {onsetdue}
        {onpickdate}
        {oncontextmenu}
        {onaddsubtask}
        subtaskProgress={getSubtaskProgress?.(task.id)}
        showList={true}
        draggable={sortMode === "manual"}
        ondragstart={handleDragStart}
        ondragend={handleDragEnd}
        ondragover={handleDragOver}
        ondrop={handleDrop}
      />
    {/each}
  {:else}
    <div class="empty">
      <p class="icon"><Icon name={emptyStates[viewType]?.icon || "checkCircle"} size={32} /></p>
      <p>{emptyStates[viewType]?.text || "No tasks"}</p>
      <p class="sub">{emptyStates[viewType]?.sub || ""}</p>
    </div>
  {/if}
</div>

<style>
  .smart-view { flex: 1; overflow-y: auto; padding: 0.5rem 1rem; min-height: 0; }
  .empty { text-align: center; margin-top: 4rem; }
  .empty .icon { font-size: 2rem; margin-bottom: 0.5rem; }
  .empty p { color: var(--fg-muted); font-size: 1.1rem; margin: 0.3rem; }
  .empty .sub { font-size: 0.85rem; color: var(--fg-faint); }
  .task-section { margin-bottom: 0.75rem; }
  .section-heading {
    margin: 0.25rem 0 0.4rem;
    padding: 0 0.5rem;
    color: var(--danger, #b3261e);
    font-size: 0.75rem;
    font-weight: 700;
    line-height: 1.4;
    text-transform: uppercase;
  }
  .drop-indicator { height: 2px; background: var(--accent); margin: 0 0.5rem; border-radius: 1px; }
</style>
