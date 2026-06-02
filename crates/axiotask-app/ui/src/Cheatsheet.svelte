<script>
  let { onclose } = $props();
</script>

<div class="overlay" onclick={onclose} onkeydown={(e) => e.key === "Escape" && onclose()} role="dialog" tabindex="-1">
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="sheet" role="document" onclick={(e) => e.stopPropagation()}>
    <h2>Keyboard Shortcuts</h2>
    <div class="columns">
      <div class="col">
        <h3>Navigation</h3>
        <dl>
          <dt>j / ↓</dt><dd>Next task</dd>
          <dt>k / ↑</dt><dd>Previous task</dd>
          <dt>h / ←</dt><dd>Collapse / go to parent</dd>
          <dt>l / →</dt><dd>Expand</dd>
        </dl>
        <h3>Actions</h3>
        <dl>
          <dt>Enter</dt><dd>New task</dd>
          <dt>e</dt><dd>Edit title</dd>
          <dt>Space</dt><dd>Toggle complete</dd>
          <dt>d</dt><dd>Delete task</dd>
          <dt>n</dt><dd>Open notes</dd>
        </dl>
      </div>
      <div class="col">
        <h3>Due dates</h3>
        <dl>
          <dt>t</dt><dd>Tomorrow</dd>
          <dt>w</dt><dd>Next week</dd>
          <dt>m</dt><dd>Next month</dd>
          <dt>r</dt><dd>Remove due date</dd>
        </dl>
        <h3>Organization</h3>
        <dl>
          <dt>Tab</dt><dd>Indent (make subtask)</dd>
          <dt>Shift+Tab</dt><dd>Outdent</dd>
          <dt>Alt+↑</dt><dd>Move up</dd>
          <dt>Alt+↓</dt><dd>Move down</dd>
        </dl>
        <h3>Other</h3>
        <dl>
          <dt>?</dt><dd>This cheatsheet</dd>
          <dt>Esc</dt><dd>Close panel / cancel</dd>
        </dl>
      </div>
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
    background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 8px;
    padding: 2rem; max-width: 600px; width: 90%;
  }
  h2 { margin: 0 0 1.5rem; font-size: 1.2rem; color: #7ec8e3; text-align: center; }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  .col h3 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: #666; margin: 1rem 0 0.4rem; }
  .col h3:first-child { margin-top: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 0.2rem 0.75rem; margin: 0; }
  dt { font-family: monospace; color: #7ec8e3; font-size: 0.8rem; }
  dd { margin: 0; color: #aaa; font-size: 0.8rem; }
  .hint { text-align: center; color: #555; font-size: 0.75rem; margin: 1.5rem 0 0; }
</style>
