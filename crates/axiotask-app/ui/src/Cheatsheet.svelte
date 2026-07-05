<script>
  import { SHORTCUT_CATEGORIES, formatKeys } from "./shortcuts.js";

  let { onclose } = $props();

  // Split categories across two columns to preserve the existing layout.
  const mid = Math.ceil(SHORTCUT_CATEGORIES.length / 2);
  const columns = [
    SHORTCUT_CATEGORIES.slice(0, mid),
    SHORTCUT_CATEGORIES.slice(mid),
  ];
</script>

<div class="overlay" onclick={onclose} onkeydown={(e) => e.key === "Escape" && onclose()} role="dialog" tabindex="-1">
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="sheet" role="document" onclick={(e) => e.stopPropagation()}>
    <h2>Keyboard Shortcuts</h2>
    <div class="columns">
      {#each columns as column}
        <div class="col">
          {#each column as category}
            <h3>{category.name}</h3>
            <dl>
              {#each category.shortcuts as shortcut}
                <dt>{formatKeys(shortcut.keys)}</dt><dd>{shortcut.description}</dd>
              {/each}
            </dl>
          {/each}
        </div>
      {/each}
    </div>
    <p class="hint">Press any key to close</p>
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.7);
    display: flex; align-items: center; justify-content: center; z-index: 2000;
  }
  .sheet {
    background: var(--bg); border: 1px solid var(--bg-elevated); border-radius: 8px;
    padding: 2rem; max-width: 600px; width: 90%;
  }
  h2 { margin: 0 0 1.5rem; font-size: 1.2rem; color: var(--accent); text-align: center; }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  .col h3 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--fg-faint); margin: 1rem 0 0.4rem; }
  .col h3:first-child { margin-top: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 0.2rem 0.75rem; margin: 0; }
  dt { font-family: monospace; color: var(--accent); font-size: 0.8rem; }
  dd { margin: 0; color: var(--fg-secondary); font-size: 0.8rem; }
  .hint { text-align: center; color: var(--fg-faint); font-size: 0.75rem; margin: 1.5rem 0 0; }
</style>
