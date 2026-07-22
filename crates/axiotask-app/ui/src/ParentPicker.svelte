<script>
  // #88: pick the parent to demote a top-level task under. Deliberately a
  // searchable picker, not a one-key gesture — the candidate list can be long,
  // and demotion is a rare, irreversible-feeling move that deserves a
  // considered choice. `candidates` is already filtered to the legal parents
  // (other top-level tasks in the same list that keep the tree two levels deep).
  let { candidates, onselect, onclose } = $props();

  let query = $state("");
  let inputEl = $state(null);
  let selectedIdx = $state(0);

  $effect(() => { if (inputEl) inputEl.focus(); });

  let results = $derived(
    query.trim().length > 0
      ? candidates.filter(t => t.title?.toLowerCase().includes(query.toLowerCase()))
      : candidates
  );

  // Reset the highlighted row whenever the result set changes so the selection
  // can't point past the end of a narrowed list. Reading `results` establishes
  // the reactive dependency.
  $effect(() => { results; selectedIdx = 0; });

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onclose(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); selectedIdx = Math.min(selectedIdx + 1, results.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); selectedIdx = Math.max(selectedIdx - 1, 0); }
    else if (e.key === "Enter" && results[selectedIdx]) { e.preventDefault(); onselect(results[selectedIdx]); }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="overlay" onclick={onclose}>
  <div
    class="picker"
    role="dialog"
    tabindex="-1"
    aria-label="Make subtask of"
    onclick={(e) => e.stopPropagation()}
    onkeydown={handleKeydown}
  >
    <h3>Make subtask of…</h3>
    <input
      bind:this={inputEl}
      bind:value={query}
      placeholder="Search for a parent task…"
      aria-label="Search for a parent task"
      type="text"
    />
    {#if results.length > 0}
      <div class="results">
        {#each results as parent, i}
          <button
            class="parent-option"
            class:focused={i === selectedIdx}
            type="button"
            onclick={() => onselect(parent)}
            onmouseenter={() => selectedIdx = i}
          >
            {parent.title || "Untitled task"}
          </button>
        {/each}
      </div>
    {:else}
      <div class="no-results">No matching task</div>
    {/if}
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.5);
    display: flex; align-items: flex-start; justify-content: center;
    padding-top: 15vh; z-index: 6000;
  }
  .picker {
    background: var(--bg-panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 1rem; width: 90%; max-width: 420px; box-shadow: 0 8px 32px rgba(0,0,0,0.5);
  }
  h3 { margin: 0 0 0.75rem; font-size: 0.9rem; color: var(--fg-secondary); }
  input {
    width: 100%; background: var(--bg-elevated); border: 1px solid var(--border);
    border-radius: 6px; color: var(--fg); padding: 0.5rem 0.75rem; font-size: 0.9rem;
    outline: none; box-sizing: border-box; font-family: inherit;
  }
  input::placeholder { color: var(--fg-faint); }
  .results { max-height: 300px; overflow-y: auto; margin-top: 0.5rem; }
  .parent-option {
    display: block; width: 100%; border: none; background: transparent; text-align: left; font-family: inherit;
    padding: 0.5rem 0.75rem; border-radius: 4px; cursor: pointer;
    font-size: 0.85rem; color: var(--fg);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .parent-option:hover, .parent-option.focused { background: var(--bg-active); color: var(--fg-strong); }
  .no-results { padding: 0.75rem; text-align: center; color: var(--fg-faint); font-size: 0.85rem; }

  @media (pointer: coarse) {
    input { padding: 0.7rem; font-size: 1rem; }
    .parent-option { padding: 0.7rem 0.75rem; }
  }
</style>
