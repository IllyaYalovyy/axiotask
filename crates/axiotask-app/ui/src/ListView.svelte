<script>
  import TaskRow from "./TaskRow.svelte";

  let { tasks, focusIndex, editingId, completingIds = new Set(), onrename, oncanceledit, onfocus, ontoggle, onsetdue, oncontextmenu, onaddsubtask, getSubtaskProgress, isCrossList } = $props();
</script>

<div class="list-view">
  {#each tasks as task, i}
    <TaskRow
      {task}
      focused={i === focusIndex}
      editing={editingId === task.id}
      completing={completingIds.has(task.id)}
      {onrename}
      {oncanceledit}
      onclick={(id, action) => action === "edit" ? onfocus?.(i, "edit") : onfocus?.(i)}
      {ontoggle}
      {onsetdue}
      {oncontextmenu}
      {onaddsubtask}
      subtaskProgress={getSubtaskProgress?.(task.id)}
      showList={isCrossList}
    />
  {/each}
  {#if tasks.length === 0}
    <div class="empty">
      <p>No tasks</p>
      <p class="sub">Type in the box above and press Enter to create one.</p>
    </div>
  {/if}
</div>

<style>
  .list-view { flex: 1; overflow-y: auto; padding: 0.5rem 1rem; }
  .empty { text-align: center; margin-top: 4rem; }
  .empty p { color: #888; margin: 0.5rem; }
  .empty .sub { font-size: 0.85rem; color: #555; }
</style>
