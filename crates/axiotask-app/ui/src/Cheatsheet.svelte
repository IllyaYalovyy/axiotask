<script>
  import { SHORTCUT_CATEGORIES, formatKeys } from "./shortcuts.js";

  let { onclose, onboarding = false } = $props();

  // Split categories across two columns to preserve the existing layout.
  const mid = Math.ceil(SHORTCUT_CATEGORIES.length / 2);
  const columns = [
    SHORTCUT_CATEGORIES.slice(0, mid),
    SHORTCUT_CATEGORIES.slice(mid),
  ];
</script>

<div
  class="overlay"
  onclick={onclose}
  onkeydown={(e) => e.key === "Escape" && onclose()}
  role="dialog"
  aria-modal="true"
  aria-label={onboarding ? "Welcome to axiotask" : "Keyboard Shortcuts"}
  tabindex="-1"
>
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="sheet" role="document" onclick={(e) => e.stopPropagation()}>
    <h2>{onboarding ? "Welcome to axiotask" : "Keyboard Shortcuts"}</h2>
    {#if onboarding}
      <p class="intro">Press n or use the quick-add field to capture a task. Dates at the end, like tomorrow or 2026-08-03, are applied automatically.</p>
    {/if}
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
    {#if onboarding}
      <button class="primary" type="button" onclick={onclose}>Start using axiotask</button>
    {:else}
      <p class="hint">Press any key to close</p>
    {/if}
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
  .intro { color: var(--fg-secondary); font-size: 0.9rem; line-height: 1.45; margin: -0.5rem 0 1.25rem; }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  .col h3 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--fg-faint); margin: 1rem 0 0.4rem; }
  .col h3:first-child { margin-top: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 0.2rem 0.75rem; margin: 0; }
  dt { font-family: monospace; color: var(--accent); font-size: 0.8rem; }
  dd { margin: 0; color: var(--fg-secondary); font-size: 0.8rem; }
  .hint { text-align: center; color: var(--fg-faint); font-size: 0.75rem; margin: 1.5rem 0 0; }
  .primary {
    display: block; margin: 1.5rem auto 0; border: 0; border-radius: 6px;
    background: var(--accent); color: var(--bg); padding: 0.6rem 0.9rem;
    font-weight: 600; cursor: pointer;
  }
</style>
