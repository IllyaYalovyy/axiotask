<script>
  let { message, onundo, ondismiss } = $props();
</script>

<div class="toast">
  <span>{message}</span>
  <button class="undo-btn" onclick={onundo}>Undo</button>
  <button class="dismiss-btn" onclick={ondismiss}>✕</button>
</div>

<style>
  .toast {
    position: fixed; bottom: 1.5rem; left: 50%; transform: translateX(-50%);
    background: #2a2a4a; border: 1px solid #3a3a5a; border-radius: 6px;
    padding: 0.6rem 1rem; display: flex; align-items: center; gap: 0.75rem;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4); z-index: 1000;
  }
  span { font-size: 0.85rem; color: #e0e0e0; }
  .undo-btn {
    background: #4285f4; color: white; border: none; padding: 0.3rem 0.7rem;
    border-radius: 3px; cursor: pointer; font-size: 0.8rem;
  }
  .undo-btn:hover { background: #3367d6; }
  .dismiss-btn { background: none; border: none; color: #666; cursor: pointer; font-size: 0.9rem; }
</style>
