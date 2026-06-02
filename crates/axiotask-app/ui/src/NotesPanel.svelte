<script>
  let { taskId, notes, onsave, onclose } = $props();
  let value = $state("");
  let textarea = $state(null);

  $effect(() => { value = notes; });
  $effect(() => { if (textarea) textarea.focus(); });

  function handleBlur() {
    if (value !== notes) onsave(taskId, value);
  }

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); onclose(); }
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<section class="notes-panel" aria-label="Notes" onkeydown={handleKeydown}>
  <div class="notes-header">
    <h3>Notes</h3>
    <button class="close-btn" onclick={onclose}>✕</button>
  </div>
  <textarea
    bind:this={textarea}
    bind:value={value}
    onblur={handleBlur}
    placeholder="Add notes..."
  ></textarea>
</section>

<style>
  .notes-panel {
    width: 300px; background: #16213e; border-left: 1px solid #2a2a4a;
    display: flex; flex-direction: column; padding: 1rem;
  }
  .notes-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
  .notes-header h3 { margin: 0; font-size: 0.85rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
  .close-btn { background: none; border: none; color: #666; cursor: pointer; font-size: 1rem; }
  .close-btn:hover { color: #e0e0e0; }
  textarea {
    flex: 1; background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 4px;
    color: #e0e0e0; padding: 0.75rem; font-size: 0.9rem; font-family: inherit;
    resize: none; outline: none;
  }
  textarea:focus { border-color: #0f3460; }
</style>
