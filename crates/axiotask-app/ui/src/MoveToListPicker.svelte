<script>
  let { lists, currentListId, onselect, onclose } = $props();
  let pickerEl = $state(null);
  let focusIdx = $state(0);

  const filteredLists = $derived(lists.filter(l => l.id !== currentListId));

  $effect(() => { if (pickerEl) pickerEl.focus(); });

  function handleKeydown(e) {
    switch (e.key) {
      case "Escape": e.preventDefault(); e.stopPropagation(); onclose(); break;
      case "ArrowDown": e.preventDefault(); focusIdx = (focusIdx + 1) % filteredLists.length; break;
      case "ArrowUp": e.preventDefault(); focusIdx = (focusIdx - 1 + filteredLists.length) % filteredLists.length; break;
      case "Enter":
        e.preventDefault();
        if (filteredLists[focusIdx]) onselect(filteredLists[focusIdx]);
        break;
    }
  }

  function handleClick(list) {
    onselect(list);
  }
</script>

<div class="overlay" role="presentation" onclick={onclose}>
  <div
    class="picker"
    bind:this={pickerEl}
    tabindex="-1"
    role="dialog"
    aria-label="Move to list"
    onclick={(e) => e.stopPropagation()}
    onkeydown={handleKeydown}
  >
    <h3>Move to list</h3>
    {#each filteredLists as list, i}
      <button
        class="list-option"
        class:focused={i === focusIdx}
        type="button"
        onclick={() => handleClick(list)}
        onmouseenter={() => focusIdx = i}
      >
        {list.title}
      </button>
    {/each}
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.5);
    display: flex; align-items: center; justify-content: center; z-index: 6000;
  }
  .picker {
    background: var(--bg-panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 1rem; min-width: 240px; outline: none;
  }
  h3 { margin: 0 0 0.75rem; font-size: 0.9rem; color: var(--fg-secondary); }
  .list-option {
    display: block; width: 100%; border: none; background: transparent; text-align: left; font-family: inherit;
    padding: 0.5rem 0.75rem; border-radius: 4px; cursor: pointer;
    font-size: 0.85rem; color: var(--fg);
  }
  .list-option:hover, .list-option.focused { background: var(--bg-active); color: var(--fg-strong); }
</style>
