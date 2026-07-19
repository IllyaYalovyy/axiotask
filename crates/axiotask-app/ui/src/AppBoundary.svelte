<script>
  import App from "./App.svelte";
  import { formatError, logBoundaryError } from "./errorBoundary.js";

  let { Component = App } = $props();

  function handleError(error) {
    logBoundaryError("render", error);
  }
</script>

<svelte:boundary onerror={handleError}>
  <Component />

  {#snippet failed(error, reset)}
    <main class="fatal-error" role="alert">
      <section class="fatal-error-panel">
        <h1>axiotask hit a UI error</h1>
        <p>{formatError(error)}</p>
        <button type="button" onclick={reset}>Retry</button>
      </section>
    </main>
  {/snippet}
</svelte:boundary>

<style>
  .fatal-error {
    min-height: 100vh;
    display: grid;
    place-items: center;
    padding: 2rem;
    background: var(--bg);
    color: var(--fg);
  }

  .fatal-error-panel {
    max-width: 34rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1.5rem;
    background: var(--bg-elevated);
  }

  h1 {
    margin: 0 0 0.75rem;
    font-size: 1.15rem;
  }

  p {
    margin: 0 0 1rem;
    color: var(--fg-muted);
    white-space: pre-wrap;
  }

  button {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 0.45rem 0.8rem;
    background: var(--bg-hover);
    color: var(--fg);
    cursor: pointer;
  }
</style>
