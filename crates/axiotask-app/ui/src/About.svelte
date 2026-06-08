<script>
  import pkg from "../package.json";

  let { onclose } = $props();

  const repository = "https://github.com/yalovoy/axiotask";
  const repoLabel = "github.com/yalovoy/axiotask";
  const version = pkg.version;
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
  class="overlay"
  onclick={onclose}
  onkeydown={(e) => e.key === "Escape" && onclose()}
  role="dialog"
  aria-modal="true"
  aria-label="About axiotask"
  tabindex="-1"
>
  <div class="card" role="document" onclick={(e) => e.stopPropagation()}>
    <h1 class="name">axiotask</h1>
    <p class="tagline">Keyboard-driven Google Tasks client</p>
    <dl class="meta">
      <dt>Version</dt>
      <dd class="version">v{version}</dd>
      <dt>Repository</dt>
      <dd>
        <a href={repository} target="_blank" rel="noreferrer noopener">{repoLabel}</a>
      </dd>
    </dl>
    <button class="close-btn" onclick={onclose}>Close</button>
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.7);
    display: flex; align-items: center; justify-content: center; z-index: 2000;
  }
  .card {
    background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 8px;
    padding: 2rem; max-width: 360px; width: 90%; text-align: center;
  }
  .name { margin: 0; font-size: 1.6rem; color: #7ec8e3; }
  .tagline { margin: 0.4rem 0 1.5rem; color: #888; font-size: 0.85rem; }
  .meta {
    display: grid; grid-template-columns: auto 1fr; gap: 0.4rem 1rem;
    margin: 0 0 1.5rem; text-align: left;
  }
  .meta dt { color: #666; font-size: 0.8rem; }
  .meta dd { margin: 0; color: #ccc; font-size: 0.8rem; }
  .version { font-family: monospace; color: #e0e0e0; }
  .meta a { color: #7ec8e3; text-decoration: none; word-break: break-all; }
  .meta a:hover { text-decoration: underline; }
  .close-btn {
    background: #2a2a4a; color: #ccc; border: none; padding: 0.45rem 1.2rem;
    border-radius: 4px; cursor: pointer; font-size: 0.8rem; font-family: inherit;
  }
  .close-btn:hover { background: #3a3a5a; }
</style>
