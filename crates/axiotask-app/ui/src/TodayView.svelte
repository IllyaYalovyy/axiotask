<script>
  import TaskRow from "./TaskRow.svelte";

  let { tasks, focusIndex, editingId, completingIds = new Set(), onrename, oncanceledit, onfocus, ontoggle, onsetdue, oncontextmenu, onaddsubtask, getSubtaskProgress, showCompleted, viewType = "focus" } = $props();

  const emptyStates = {
    focus: { icon: "✓", text: "All clear for this week", sub: "Nothing needs your attention right now." },
    upcoming: { icon: "📅", text: "Nothing upcoming", sub: "No tasks due in the next 14 days." },
    missed: { icon: "🎉", text: "Nothing overdue", sub: "You're all caught up!" },
    unscheduled: { icon: "✓", text: "Everything is scheduled", sub: "All tasks have a due date." },
  };
</script>

<div class="smart-view">
  {#if tasks.length > 0}
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
        showList={true}
      />
    {/each}
  {:else}
    <div class="empty">
      <p class="icon">{emptyStates[viewType]?.icon || "✓"}</p>
      <p>{emptyStates[viewType]?.text || "No tasks"}</p>
      <p class="sub">{emptyStates[viewType]?.sub || ""}</p>
    </div>
  {/if}
</div>

<style>
  .smart-view { flex: 1; overflow-y: auto; padding: 0.5rem 1rem; }
  .empty { text-align: center; margin-top: 4rem; }
  .empty .icon { font-size: 2rem; margin-bottom: 0.5rem; }
  .empty p { color: #888; font-size: 1.1rem; margin: 0.3rem; }
  .empty .sub { font-size: 0.85rem; color: #555; }
</style>
