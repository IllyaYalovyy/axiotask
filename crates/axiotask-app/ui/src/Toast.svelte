<script>
  let { message, onundo, ondismiss, variant = "info" } = $props();
</script>

<div class="toast {variant === 'error' ? 'toast-error' : ''}" role={variant === "error" ? "alert" : undefined}>
  <span>{message}</span>
  {#if onundo}
    <button class="undo-btn" onclick={onundo}>Undo</button>
  {/if}
  <button class="dismiss-btn" aria-label="Dismiss" onclick={ondismiss}>✕</button>
</div>

<style>
  .toast {
    background: var(--bg-elevated); border: 1px solid var(--border-faint); border-radius: 6px;
    padding: 0.6rem 1rem; display: flex; align-items: center; gap: 0.75rem;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4); z-index: 1000;
    max-width: 100%;
  }
  .toast-error {
    background: var(--bg-danger); border-color: var(--danger);
  }
  span { font-size: 0.85rem; color: var(--fg); }
  .undo-btn {
    background: #4285f4; color: white; border: none; padding: 0.3rem 0.7rem;
    border-radius: 3px; cursor: pointer; font-size: 0.8rem;
  }
  .undo-btn:hover { background: #3367d6; }
  .dismiss-btn { background: none; border: none; color: var(--fg-faint); cursor: pointer; font-size: 0.9rem; }
</style>
