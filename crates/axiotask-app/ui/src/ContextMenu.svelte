<script>
  let { items, x, y, onclose } = $props();
  let menuEl = $state(null);
  let activeSubmenu = $state(null);
  let focusIdx = $state(0);

  $effect(() => { if (menuEl) menuEl.focus(); });

  // Close on click outside
  function handleWindowClick(e) {
    if (menuEl && !menuEl.contains(e.target)) onclose();
  }

  function handleKeydown(e) {
    const actionItems = items.filter(i => i !== "separator");
    switch (e.key) {
      case "Escape": e.preventDefault(); onclose(); break;
      case "ArrowDown": e.preventDefault(); focusIdx = (focusIdx + 1) % actionItems.length; break;
      case "ArrowUp": e.preventDefault(); focusIdx = (focusIdx - 1 + actionItems.length) % actionItems.length; break;
      case "ArrowRight":
        e.preventDefault();
        if (actionItems[focusIdx]?.submenu) activeSubmenu = actionItems[focusIdx].id;
        break;
      case "ArrowLeft": e.preventDefault(); activeSubmenu = null; break;
      case "Enter":
        e.preventDefault();
        const item = actionItems[focusIdx];
        if (item?.submenu) activeSubmenu = item.id;
        else if (item?.action) { item.action(); onclose(); }
        break;
    }
  }

  function handleItemClick(item) {
    if (item.submenu) { activeSubmenu = activeSubmenu === item.id ? null : item.id; return; }
    if (item.action) { item.action(); onclose(); }
  }

  function handleSubmenuClick(action) {
    action();
    onclose();
  }

  // Clamp position to viewport
  let style = $derived(`left: ${Math.min(x, window.innerWidth - 220)}px; top: ${Math.min(y, window.innerHeight - 300)}px`);
</script>

<svelte:window onclick={handleWindowClick} />

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div class="context-menu" bind:this={menuEl} {style} tabindex="-1" onkeydown={handleKeydown} role="menu">
  {#each items as item, i}
    {#if item === "separator"}
      <div class="separator"></div>
    {:else}
      {@const actionIdx = items.filter((x, j) => j < i && x !== "separator").length}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="menu-item"
        class:focused={actionIdx === focusIdx}
        class:has-submenu={!!item.submenu}
        onclick={() => handleItemClick(item)}
        onmouseenter={() => { focusIdx = actionIdx; if (item.submenu) activeSubmenu = item.id; }}
      >
        <span class="icon">{item.icon || ""}</span>
        <span class="label">{item.label}</span>
        {#if item.shortcut}
          <span class="shortcut">{item.shortcut}</span>
        {/if}
        {#if item.submenu}
          <span class="arrow">▸</span>
        {/if}
      </div>
      {#if item.submenu && activeSubmenu === item.id}
        <div class="submenu">
          {#each item.submenu as sub}
            <!-- svelte-ignore a11y_click_events_have_key_events -->
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div class="menu-item" onclick={() => handleSubmenuClick(sub.action)}>
              <span class="label">{sub.label}</span>
            </div>
          {/each}
        </div>
      {/if}
    {/if}
  {/each}
</div>

<style>
  .context-menu {
    position: fixed; z-index: 5000;
    background: #1e2a3e; border: 1px solid #3a4a6a; border-radius: 6px;
    padding: 0.3rem 0; min-width: 200px; box-shadow: 0 8px 24px rgba(0,0,0,0.5);
    outline: none;
  }
  .separator { height: 1px; background: #2a3a5a; margin: 0.3rem 0; }
  .menu-item {
    display: flex; align-items: center; gap: 0.5rem;
    padding: 0.4rem 0.75rem; cursor: pointer; font-size: 0.85rem; color: #ccc;
  }
  .menu-item:hover, .menu-item.focused { background: #0f3460; color: #fff; }
  .icon { width: 1.2rem; text-align: center; font-size: 0.8rem; }
  .label { flex: 1; }
  .shortcut { font-size: 0.7rem; color: #666; }
  .arrow { color: #666; font-size: 0.7rem; }
  .submenu {
    position: absolute; left: 100%; top: 0; margin-top: -0.3rem;
    background: #1e2a3e; border: 1px solid #3a4a6a; border-radius: 6px;
    padding: 0.3rem 0; min-width: 160px; box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  }
  .has-submenu + .submenu { position: relative; left: 1rem; margin: 0; border: none; box-shadow: none; padding: 0 0 0 1rem; }
</style>
