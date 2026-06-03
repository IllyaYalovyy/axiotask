<script>
  let { oncreate, currentListId, targetListName } = $props();
  let value = $state("");

  function handleKeydown(e) {
    if (e.key === "Enter" && value.trim()) {
      e.preventDefault();
      oncreate(value, currentListId);
      value = "";
    }
    if (e.key === "Escape") {
      e.preventDefault();
      value = "";
      e.target.blur();
    }
  }
</script>

<div class="quick-add">
  <input
    type="text"
    bind:value
    onkeydown={handleKeydown}
    placeholder="Add a task... (Enter)"
  />
  {#if targetListName}
    <span class="list-hint">→ {targetListName}</span>
  {/if}
</div>

<style>
  .quick-add { padding: 0.75rem 1rem; border-bottom: 1px solid #2a2a4a; display: flex; align-items: center; gap: 0.5rem; }
  input {
    flex: 1; background: #16213e; border: 1px solid #2a2a4a;
    color: #e0e0e0; padding: 0.6rem 0.8rem; border-radius: 6px;
    font-size: 0.9rem; outline: none; box-sizing: border-box;
  }
  input:focus { border-color: #0f3460; }
  input::placeholder { color: #555; }
  .list-hint { font-size: 0.75rem; color: #888; white-space: nowrap; }
</style>
