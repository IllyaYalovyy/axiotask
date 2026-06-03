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

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div class="overlay" onclick={onclose} onkeydown={handleKeydown}>
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="picker" bind:this={pickerEl} tabindex="-1" role="dialog" aria-label="Move to list" onclick={(e) => e.stopPropagation()}>
    <h3>Move to list</h3>
    {#each filteredLists as list, i}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="list-option" class:focused={i === focusIdx} onclick={() => handleClick(list)} onmouseenter={() => focusIdx = i}>
        {list.title}
      </div>
    {/each}
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.5);
    display: flex; align-items: center; justify-content: center; z-index: 6000;
  }
  .picker {
    background: #1e2a3e; border: 1px solid #3a4a6a; border-radius: 8px;
    padding: 1rem; min-width: 240px; outline: none;
  }
  h3 { margin: 0 0 0.75rem; font-size: 0.9rem; color: #ccc; }
  .list-option {
    padding: 0.5rem 0.75rem; border-radius: 4px; cursor: pointer;
    font-size: 0.85rem; color: #e0e0e0;
  }
  .list-option:hover, .list-option.focused { background: #0f3460; color: #fff; }
</style>
