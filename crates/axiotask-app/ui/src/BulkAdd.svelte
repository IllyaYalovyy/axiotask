<script>
  let { initialText = "", lists = [], defaultListId = "", onsubmit, onclose } = $props();

  let text = $state(initialText);
  // "perLine"  → one task per non-empty line
  // "titleNotes" → first line is the title, the rest become the notes
  let mode = $state("perLine");
  let listId = $state(defaultListId);
  let textarea = $state(null);

  $effect(() => {
    if (textarea) textarea.focus();
  });

  // How many tasks the current text + mode will create (for a live preview).
  let taskCount = $derived.by(() => {
    if (mode === "titleNotes") {
      return text.split("\n")[0]?.trim() ? 1 : 0;
    }
    return text.split("\n").filter((l) => l.trim().length > 0).length;
  });

  function submit() {
    if (taskCount === 0) return;
    onsubmit({ text, mode, listId });
  }

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); onclose(); }
    // Ctrl/Cmd+Enter submits without leaving the textarea.
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); submit(); }
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
  class="overlay"
  onclick={onclose}
  onkeydown={handleKeydown}
  role="dialog"
  aria-modal="true"
  aria-label="Add multiple tasks"
  tabindex="-1"
>
  <div class="card" role="document" onclick={(e) => e.stopPropagation()}>
    <header class="head">
      <h2>Add multiple tasks</h2>
      <button class="x" onclick={onclose} aria-label="Close">×</button>
    </header>

    <!-- svelte-ignore a11y_autofocus -->
    <textarea
      bind:this={textarea}
      bind:value={text}
      class="bulk-text"
      placeholder="Paste or type one task per line…"
      rows="10"
    ></textarea>

    <fieldset class="modes">
      <legend>How to create</legend>
      <label>
        <input type="radio" name="bulk-mode" value="perLine" bind:group={mode} />
        <span>
          <strong>One task per line</strong>
          <small>Each non-empty line becomes its own task.</small>
        </span>
      </label>
      <label>
        <input type="radio" name="bulk-mode" value="titleNotes" bind:group={mode} />
        <span>
          <strong>First line is the title, the rest are notes</strong>
          <small>Creates a single task with the remaining lines as its description.</small>
        </span>
      </label>
    </fieldset>

    <div class="field-row">
      <label for="bulk-list">List</label>
      <select id="bulk-list" bind:value={listId}>
        {#each lists as list}
          <option value={list.id}>{list.title}</option>
        {/each}
      </select>
    </div>

    <footer class="actions">
      <span class="count">
        {#if taskCount === 0}Nothing to add
        {:else if taskCount === 1}Creates 1 task
        {:else}Creates {taskCount} tasks{/if}
      </span>
      <div class="buttons">
        <button class="cancel" onclick={onclose}>Cancel</button>
        <button class="primary" onclick={submit} disabled={taskCount === 0}>Add</button>
      </div>
    </footer>
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.7);
    display: flex; align-items: center; justify-content: center; z-index: 2000;
  }
  .card {
    background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 10px;
    width: 90%; max-width: 560px; max-height: 88vh; display: flex; flex-direction: column;
    padding: 1.25rem; gap: 1rem;
  }
  .head { display: flex; align-items: center; justify-content: space-between; }
  .head h2 { margin: 0; font-size: 1.05rem; color: #7ec8e3; }
  .x { background: none; border: none; color: #888; font-size: 1.4rem; line-height: 1; cursor: pointer; padding: 0 0.25rem; }
  .x:hover { color: #e0e0e0; }

  .bulk-text {
    width: 100%; box-sizing: border-box; background: #16213e; border: 1px solid #2a2a4a;
    border-radius: 6px; color: #e0e0e0; padding: 0.6rem; font-size: 0.9rem;
    font-family: inherit; resize: vertical; min-height: 120px; outline: none;
  }
  .bulk-text:focus { border-color: #0f3460; }

  .modes { border: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0.5rem; }
  .modes legend {
    font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em;
    color: #667; padding: 0; margin-bottom: 0.2rem;
  }
  .modes label { display: flex; align-items: flex-start; gap: 0.6rem; cursor: pointer; padding: 0.4rem 0.5rem; border-radius: 6px; }
  .modes label:hover { background: #16213e; }
  .modes input { margin-top: 0.2rem; cursor: pointer; }
  .modes span { display: flex; flex-direction: column; gap: 0.1rem; }
  .modes strong { color: #e0e0e0; font-size: 0.85rem; font-weight: 600; }
  .modes small { color: #888; font-size: 0.78rem; }

  .field-row { display: flex; align-items: center; gap: 0.6rem; }
  .field-row label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.03em; color: #667; }
  .field-row select {
    flex: 1; background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 4px;
    color: #e0e0e0; padding: 0.4rem; font-size: 0.85rem; font-family: inherit; outline: none; color-scheme: dark;
  }
  .field-row select option { background: #1a1a2e; color: #e0e0e0; }

  .actions { display: flex; align-items: center; justify-content: space-between; }
  .count { color: #888; font-size: 0.8rem; }
  .buttons { display: flex; gap: 0.5rem; }
  .actions button {
    border: none; padding: 0.45rem 1rem; border-radius: 5px; cursor: pointer;
    font-size: 0.85rem; font-family: inherit;
  }
  .cancel { background: #2a2a4a; color: #ccc; }
  .cancel:hover { background: #3a3a5a; }
  .primary { background: #0f3460; color: #7ec8e3; }
  .primary:hover:not(:disabled) { background: #1a4a7a; }
  .primary:disabled { opacity: 0.45; cursor: default; }
</style>
