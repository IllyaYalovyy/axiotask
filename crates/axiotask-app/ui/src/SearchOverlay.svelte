<script>
  let { tasks, onselect, onclose } = $props();

  let query = $state("");
  let inputEl = $state(null);
  let selectedIdx = $state(0);

  $effect(() => { if (inputEl) inputEl.focus(); });

  function matchesQuery(task, normalizedQuery) {
    return task.title?.toLowerCase().includes(normalizedQuery) ||
      task.notes?.toLowerCase().includes(normalizedQuery);
  }

  function rankResults(matches) {
    return [...matches].sort((a, b) => {
      if (a.status !== b.status) return a.status === "completed" ? 1 : -1;
      return 0;
    });
  }

  let results = $derived(
    query.trim().length > 0
      ? rankResults(tasks.filter(t => matchesQuery(t, query.toLowerCase()))).slice(0, 20)
      : []
  );

  $effect(() => { selectedIdx = 0; }); // reset on query change

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); onclose(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); selectedIdx = Math.min(selectedIdx + 1, results.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); selectedIdx = Math.max(selectedIdx - 1, 0); }
    else if (e.key === "Enter" && results[selectedIdx]) { e.preventDefault(); onselect(results[selectedIdx]); onclose(); }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="search-overlay" onclick={onclose}>
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="search-box" onclick={(e) => e.stopPropagation()}>
    <input
      bind:this={inputEl}
      bind:value={query}
      onkeydown={handleKeydown}
      placeholder="Search tasks..."
      type="text"
    />
    {#if results.length > 0}
      <div class="results">
        {#each results as task, i}
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div class="result" class:selected={i === selectedIdx} onclick={() => { onselect(task); onclose(); }}>
            <span class="result-title">{task.title}</span>
            {#if task.parent_id}
              <span class="result-kind">Subtask</span>
            {/if}
            {#if task.listTitle}
              <span class="result-list">{task.listTitle}</span>
            {/if}
            {#if task.due}
              <span class="result-due">{new Date(task.due).toLocaleDateString()}</span>
            {/if}
          </div>
        {/each}
      </div>
    {:else if query.trim().length > 0}
      <div class="no-results">No tasks found</div>
    {/if}
  </div>
</div>

<style>
  .search-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.6);
    display: flex; align-items: flex-start; justify-content: center;
    padding-top: 15vh; z-index: 4000;
  }
  .search-box {
    background: var(--bg-panel); border: 1px solid var(--border); border-radius: 8px;
    width: 90%; max-width: 500px; box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    overflow: hidden;
  }
  input {
    width: 100%; background: transparent; border: none; border-bottom: 1px solid var(--bg-elevated);
    color: var(--fg); padding: 0.8rem 1rem; font-size: 1rem; outline: none;
    box-sizing: border-box;
  }
  input::placeholder { color: var(--fg-faint); }
  .results { max-height: 300px; overflow-y: auto; }
  .result {
    display: flex; align-items: center; gap: 0.5rem;
    padding: 0.5rem 1rem; cursor: pointer; font-size: 0.9rem; color: var(--fg-secondary);
  }
  .result:hover, .result.selected { background: var(--bg-active); color: var(--fg-strong); }
  .result-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .result-kind { font-size: 0.7rem; color: var(--fg-secondary); border: 1px solid var(--border); padding: 0.08rem 0.35rem; border-radius: 3px; }
  .result-list { font-size: 0.7rem; color: var(--fg-faint); background: var(--bg-elevated); padding: 0.1rem 0.4rem; border-radius: 3px; }
  .result-due { font-size: 0.7rem; color: var(--fg-muted); }
  .no-results { padding: 1rem; text-align: center; color: var(--fg-faint); font-size: 0.9rem; }

  @media (pointer: coarse) {
    input { padding: 1rem; font-size: 1.1rem; }
    .result { padding: 0.7rem 1rem; }
  }
</style>
