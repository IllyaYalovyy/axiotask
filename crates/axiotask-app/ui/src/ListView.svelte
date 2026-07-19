<script>
  import TaskRow from "./TaskRow.svelte";

  let { tasks, focusIndex, editingId, completingIds = new Set(), selectedIds = new Set(), onrename, oncanceledit, onfocus, onselect, ontoggle, onsetdue, onpickdate, oncontextmenu, onaddsubtask, ontogglecollapse, getSubtaskProgress, isCrossList, sortMode = "manual", onreorder } = $props();

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
    // The backend reorders among SIBLINGS, but the rendered rows interleave
    // subtask rows — counting raw row distance overshoots by every expanded
    // child crossed. Count only siblings of the dragged task.
    const parentOf = (t) => t.parent_id ?? null;
    const dragParent = parentOf(tasks[fromIdx]);
    const [lo, hi] = fromIdx < toIdx ? [fromIdx + 1, toIdx] : [toIdx, fromIdx - 1];
    let steps = 0;
    for (let i = lo; i <= hi; i++) if (parentOf(tasks[i]) === dragParent) steps++;
    if (steps > 0) onreorder?.(draggingId, direction, steps);
    handleDragEnd();
  }
</script>

<div class="list-view">
  {#each tasks as task, i}
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
      {ontogglecollapse}
      subtaskProgress={getSubtaskProgress?.(task.id)}
      showList={isCrossList}
      draggable={sortMode === "manual"}
      ondragstart={handleDragStart}
      ondragend={handleDragEnd}
      ondragover={handleDragOver}
      ondrop={handleDrop}
    />
  {/each}
  {#if tasks.length === 0}
    <div class="empty">
      <p>No tasks</p>
      <p class="sub">Use quick add or press n to create one.</p>
    </div>
  {/if}
</div>

<style>
  .list-view { flex: 1; overflow-y: auto; padding: 0.5rem 1rem; min-height: 0; }
  .empty { text-align: center; margin-top: 4rem; }
  .empty p { color: var(--fg-muted); margin: 0.5rem; }
  .empty .sub { font-size: 0.85rem; color: var(--fg-faint); }
  .drop-indicator { height: 2px; background: var(--accent); margin: 0 0.5rem; border-radius: 1px; }
</style>
