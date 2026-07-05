<script>
  let { value, onchange } = $props();
  let open = $state(false);

  const options = [
    { id: "manual", label: "My order" },
    { id: "due", label: "Due date" },
    { id: "alpha", label: "Alphabetical" },
    { id: "created", label: "Recently created" },
  ];

  function select(id) { onchange(id); open = false; }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="sort-dropdown" onclick={() => open = !open}>
  <span class="label">Sort: {options.find(o => o.id === value)?.label || "My order"}</span>
  <span class="arrow">{open ? "▴" : "▾"}</span>
  {#if open}
    <div class="menu">
      {#each options as opt}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div class="option" class:active={value === opt.id} onclick={(e) => { e.stopPropagation(); select(opt.id); }}>
          {value === opt.id ? "●" : "○"} {opt.label}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .sort-dropdown { position: relative; cursor: pointer; font-size: 0.8rem; color: var(--fg-muted); user-select: none; }
  .label:hover { color: var(--fg-secondary); }
  .arrow { font-size: 0.6rem; margin-left: 0.2rem; }
  .menu {
    position: absolute; top: 100%; left: 0; margin-top: 0.3rem;
    background: var(--bg-panel); border: 1px solid var(--border); border-radius: 6px;
    padding: 0.3rem 0; min-width: 160px; z-index: 100; box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  }
  .option { padding: 0.4rem 0.75rem; font-size: 0.8rem; color: var(--fg-secondary); }
  .option:hover { background: var(--bg-active); color: var(--fg-strong); }
  .option.active { color: var(--accent); }

  @media (pointer: coarse) {
    .sort-dropdown { font-size: 0.9rem; padding: 0.3rem 0; }
    .option { padding: 0.6rem 0.75rem; }
  }
</style>
