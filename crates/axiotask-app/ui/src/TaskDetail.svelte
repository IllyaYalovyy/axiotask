<script>
  let { task, lists, onsave, onclose, ondelete, onmovelist } = $props();

  let title = $state("");
  let notes = $state("");
  let due = $state("");
  let selectedList = $state("");

  // Reset when task changes
  $effect(() => {
    if (task) {
      title = task.title || "";
      notes = task.notes || "";
      due = task.due ? task.due.slice(0, 10) : "";
      selectedList = task.listId || "";
    }
  });

  function save() {
    const dueVal = due ? `${due}T00:00:00.000Z` : null;
    onsave(task.id, { title, notes, due: dueVal });
    if (selectedList !== task.listId) onmovelist(task.id, selectedList);
  }

  function handleKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); onclose(); }
    if (e.key === "s" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); save(); onclose(); }
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside class="detail-panel" onkeydown={handleKeydown}>
  <div class="panel-header">
    <h3>Task Details</h3>
    <div class="panel-actions">
      <button class="save-btn" onclick={() => { save(); onclose(); }}>Save</button>
      <button class="close-btn" onclick={onclose}>✕</button>
    </div>
  </div>

  <div class="field">
    <label for="detail-title">Title</label>
    <input id="detail-title" type="text" bind:value={title} placeholder="Task title" />
  </div>

  <div class="field">
    <label for="detail-due">Due date</label>
    <input id="detail-due" type="date" bind:value={due} />
    <div class="quick-dates">
      <button onclick={() => { const d = new Date(); due = d.toISOString().slice(0,10); }}>Today</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+1); due = d.toISOString().slice(0,10); }}>Tomorrow</button>
      <button onclick={() => { const d = new Date(); d.setDate(d.getDate()+7); due = d.toISOString().slice(0,10); }}>Next week</button>
      <button onclick={() => due = ""}>Clear</button>
    </div>
  </div>

  <div class="field">
    <label for="detail-list">List</label>
    <select id="detail-list" bind:value={selectedList}>
      {#each lists as list}
        <option value={list.id}>{list.title}</option>
      {/each}
    </select>
  </div>

  <div class="field">
    <label for="detail-notes">Notes</label>
    <textarea id="detail-notes" bind:value={notes} placeholder="Add notes..." rows="6"></textarea>
  </div>

  <div class="danger-zone">
    <button class="delete-btn" onclick={() => { ondelete(task.id); onclose(); }}>🗑️ Delete task</button>
  </div>
</aside>

<style>
  .detail-panel {
    width: 320px; background: #16213e; border-left: 1px solid #2a2a4a;
    display: flex; flex-direction: column; padding: 1rem; overflow-y: auto;
  }
  .panel-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
  .panel-header h3 { margin: 0; font-size: 0.9rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
  .panel-actions { display: flex; gap: 0.4rem; }
  .save-btn { background: #0f3460; color: #7ec8e3; border: none; padding: 0.3rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; }
  .save-btn:hover { background: #1a4a7a; }
  .close-btn { background: none; border: none; color: #666; cursor: pointer; font-size: 1.1rem; }
  .close-btn:hover { color: #e0e0e0; }

  .field { margin-bottom: 1rem; }
  .field label { display: block; font-size: 0.75rem; color: #666; text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 0.3rem; }
  .field input[type="text"], .field textarea, .field select {
    width: 100%; background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 4px;
    color: #e0e0e0; padding: 0.5rem; font-size: 0.9rem; font-family: inherit; outline: none;
    box-sizing: border-box;
  }
  .field input:focus, .field textarea:focus, .field select:focus { border-color: #0f3460; }
  .field input[type="date"] { color-scheme: dark; }
  .field textarea { resize: vertical; min-height: 100px; }
  .field select { cursor: pointer; }

  .quick-dates { display: flex; gap: 0.3rem; margin-top: 0.4rem; flex-wrap: wrap; }
  .quick-dates button {
    background: #2a2a4a; border: none; color: #888; padding: 0.25rem 0.5rem;
    border-radius: 3px; font-size: 0.75rem; cursor: pointer;
  }
  .quick-dates button:hover { background: #0f3460; color: #7ec8e3; }

  .danger-zone { margin-top: auto; padding-top: 1rem; border-top: 1px solid #2a2a4a; }
  .delete-btn { background: none; border: 1px solid #5a2a2a; color: #e74c3c; padding: 0.4rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; width: 100%; }
  .delete-btn:hover { background: #3a1a1a; }

  @media (max-width: 700px) {
    .detail-panel { width: 100%; position: fixed; inset: 0; z-index: 3000; }
  }
  @media (pointer: coarse) {
    .field input, .field textarea, .field select { padding: 0.6rem; font-size: 1rem; }
    .quick-dates button { padding: 0.4rem 0.7rem; font-size: 0.85rem; }
  }
</style>
