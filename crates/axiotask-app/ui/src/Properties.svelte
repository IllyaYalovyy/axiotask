<script>
  import pkg from "../package.json";
  import { SHORTCUT_CATEGORIES, formatKeys } from "./shortcuts.js";

  let {
    settings,
    busy = false,
    onclose,
    onsetpush,
    onsetautosync,
    onlogin,
    onlogout,
    onsync,
    onfreshsync,
  } = $props();

  let section = $state("sync");

  const SECTIONS = [
    { id: "sync", label: "Sync", icon: "↻" },
    { id: "account", label: "Account", icon: "👤" },
    { id: "shortcuts", label: "Shortcuts", icon: "⌨" },
    { id: "about", label: "About", icon: "ℹ" },
  ];

  const repository = "https://github.com/yalovoy/axiotask";
  const repoLabel = "github.com/yalovoy/axiotask";

  // Friendly absolute + relative time for the last sync.
  function relativeTime(iso) {
    if (!iso) return "never";
    const then = new Date(iso.replace(" ", "T"));
    if (isNaN(then.getTime())) return iso;
    const secs = Math.floor((Date.now() - then.getTime()) / 1000);
    if (secs < 0) return "just now";
    if (secs < 60) return "just now";
    if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
    if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
    return `${Math.floor(secs / 86400)}d ago`;
  }

  // Friendly name for an OAuth scope URL.
  function scopeLabel(scope) {
    if (scope.endsWith("/tasks")) return "Google Tasks — read & write";
    if (scope.endsWith("/tasks.readonly")) return "Google Tasks — read only";
    return scope;
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
  class="overlay"
  onclick={onclose}
  onkeydown={(e) => e.key === "Escape" && onclose()}
  role="dialog"
  aria-modal="true"
  aria-label="Properties"
  tabindex="-1"
>
  <div class="card" role="document" onclick={(e) => e.stopPropagation()}>
    <header class="head">
      <h2>⚙ Properties{#if settings.instance}<span class="instance-badge">{settings.instance}</span>{/if}</h2>
      <button class="x" onclick={onclose} aria-label="Close">×</button>
    </header>

    <div class="body">
      <nav class="tabs" role="tablist" aria-label="Properties sections">
        {#each SECTIONS as s}
          <button
            class="tab"
            class:active={section === s.id}
            role="tab"
            aria-selected={section === s.id}
            onclick={() => (section = s.id)}
          >
            <span class="tab-icon" aria-hidden="true">{s.icon}</span>{s.label}
          </button>
        {/each}
      </nav>

      <section class="pane" role="tabpanel">
        {#if section === "sync"}
          <h3>Sync mode</h3>
          <label class="switch">
            <input
              type="checkbox"
              checked={settings.push_enabled}
              disabled={busy}
              onchange={(e) => onsetpush(e.currentTarget.checked)}
            />
            <span>
              <strong>Read-write sync</strong>
              <small>
                {settings.push_enabled
                  ? "Local edits are pushed to Google Tasks."
                  : "Read-only: changes stay on this device and are never pushed."}
              </small>
            </span>
          </label>
          <label class="switch">
            <input
              type="checkbox"
              checked={settings.auto_sync_on_start}
              disabled={busy}
              onchange={(e) => onsetautosync(e.currentTarget.checked)}
            />
            <span>
              <strong>Auto-sync on startup</strong>
              <small>Sync automatically when the app launches.</small>
            </span>
          </label>

          <h3>Status</h3>
          {#if settings.sync.last_error}
            <p class="error" role="alert">⚠ Last sync failed: {settings.sync.last_error}</p>
          {/if}
          <dl class="stats">
            <dt>Last synced</dt>
            <dd>{relativeTime(settings.sync.last_synced)}</dd>
            <dt>Pending changes</dt>
            <dd>{settings.pending_pushes}</dd>
            <dt>Last run</dt>
            <dd>
              ↓{settings.sync.last_pulled} ↑{settings.sync.last_pushed}
              · {settings.sync.last_conflicts} conflicts
              · {settings.sync.last_deleted} removed
            </dd>
            <dt>Syncs this session</dt>
            <dd>{settings.sync.total_syncs}</dd>
          </dl>
          <div class="actions">
            <button onclick={onsync} disabled={busy || !settings.authenticated}>↻ Sync now</button>
            <button onclick={onfreshsync} disabled={busy || !settings.authenticated}>⟳ Fresh sync</button>
          </div>
          {#if !settings.authenticated}
            <p class="hint">Sign in on the Account tab to enable syncing.</p>
          {/if}

        {:else if section === "account"}
          <h3>Google account</h3>
          <p class="acct-status">
            <span class="dot" class:on={settings.authenticated}></span>
            {settings.authenticated ? "Signed in" : "Not signed in"}
          </p>
          <h3>Access</h3>
          <ul class="scopes">
            {#each settings.scopes as scope}
              <li>{scopeLabel(scope)}</li>
            {/each}
          </ul>
          <p class="hint">axiotask only requests access to your Google Tasks — nothing else.</p>
          <div class="actions">
            {#if settings.authenticated}
              <button onclick={onlogout}>Sign out</button>
            {:else}
              <button class="primary" onclick={onlogin}>Sign in with Google</button>
            {/if}
          </div>

        {:else if section === "shortcuts"}
          <h3>Keyboard shortcuts</h3>
          <div class="shortcuts">
            {#each SHORTCUT_CATEGORIES as category}
              <h4>{category.name}</h4>
              <dl>
                {#each category.shortcuts as sc}
                  <dt>{formatKeys(sc.keys)}</dt>
                  <dd>{sc.description}</dd>
                {/each}
              </dl>
            {/each}
            <h4>App</h4>
            <dl>
              <dt>,</dt><dd>Open Properties</dd>
              <dt>?</dt><dd>Shortcut cheatsheet</dd>
            </dl>
          </div>

        {:else if section === "about"}
          <div class="about">
            <h1 class="name">axiotask</h1>
            <p class="tagline">Keyboard-driven Google Tasks client</p>
            <dl class="meta">
              <dt>Version</dt>
              <dd class="version">v{pkg.version}</dd>
              <dt>Instance</dt>
              <dd>{settings.instance ? settings.instance : "default (production)"}</dd>
              <dt>Repository</dt>
              <dd><a href={repository} target="_blank" rel="noreferrer noopener">{repoLabel}</a></dd>
              <dt>Database</dt>
              <dd class="path" title={settings.db_path}>{settings.db_path}</dd>
              <dt>Config</dt>
              <dd class="path" title={settings.config_path}>{settings.config_path}</dd>
            </dl>
            <p class="license">Apache-2.0</p>
          </div>
        {/if}
      </section>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.7);
    display: flex; align-items: center; justify-content: center; z-index: 2000;
  }
  .card {
    background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 10px;
    width: 90%; max-width: 620px; max-height: 85vh; display: flex; flex-direction: column;
    overflow: hidden;
  }
  .head {
    display: flex; align-items: center; justify-content: space-between;
    padding: 1rem 1.25rem; border-bottom: 1px solid #2a2a4a;
  }
  .head h2 { margin: 0; font-size: 1.05rem; color: #7ec8e3; }
  .instance-badge {
    margin-left: 0.5rem; font-size: 0.65rem; font-weight: 600; vertical-align: middle;
    text-transform: uppercase; letter-spacing: 0.04em; color: #ffb74d;
    background: #3a2a14; border: 1px solid #5a4424; padding: 0.1rem 0.4rem; border-radius: 8px;
  }
  .x {
    background: none; border: none; color: #888; font-size: 1.4rem; line-height: 1;
    cursor: pointer; padding: 0 0.25rem;
  }
  .x:hover { color: #e0e0e0; }

  .body { display: flex; min-height: 0; flex: 1; }
  .tabs {
    display: flex; flex-direction: column; gap: 2px; padding: 0.75rem;
    border-right: 1px solid #2a2a4a; min-width: 130px; background: #16213e;
  }
  .tab {
    display: flex; align-items: center; gap: 0.5rem; text-align: left;
    background: none; border: none; color: #aaa; padding: 0.5rem 0.7rem;
    border-radius: 6px; cursor: pointer; font-size: 0.85rem; font-family: inherit;
  }
  .tab:hover { background: #1a2a4a; color: #e0e0e0; }
  .tab.active { background: #0f3460; color: #fff; }
  .tab-icon { width: 1.1rem; text-align: center; }

  .pane { padding: 1.1rem 1.25rem; overflow-y: auto; flex: 1; min-width: 0; }
  .pane h3 {
    font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em;
    color: #667; margin: 0 0 0.6rem; padding-top: 0.25rem;
  }
  .pane h3:not(:first-child) { margin-top: 1.4rem; border-top: 1px solid #23233e; padding-top: 1rem; }

  .switch {
    display: flex; align-items: flex-start; gap: 0.7rem; margin-bottom: 0.7rem;
    cursor: pointer; padding: 0.5rem 0.6rem; border-radius: 6px;
  }
  .switch:hover { background: #16213e; }
  .switch input { margin-top: 0.2rem; width: 1.05rem; height: 1.05rem; cursor: pointer; flex-shrink: 0; }
  .switch span { display: flex; flex-direction: column; gap: 0.15rem; }
  .switch strong { color: #e0e0e0; font-size: 0.88rem; font-weight: 600; }
  .switch small { color: #888; font-size: 0.78rem; line-height: 1.3; }

  .stats { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 1rem; margin: 0; }
  .stats dt { color: #667; font-size: 0.8rem; }
  .stats dd { margin: 0; color: #ccc; font-size: 0.8rem; }

  .actions { display: flex; gap: 0.5rem; margin-top: 1rem; flex-wrap: wrap; }
  .actions button {
    background: #2a2a4a; color: #ccc; border: none; padding: 0.45rem 0.9rem;
    border-radius: 5px; cursor: pointer; font-size: 0.82rem; font-family: inherit;
  }
  .actions button:hover:not(:disabled) { background: #3a3a5a; }
  .actions button:disabled { opacity: 0.45; cursor: default; }
  .actions button.primary { background: #0f3460; color: #7ec8e3; }
  .actions button.primary:hover { background: #1a4a7a; }

  .error {
    background: #3a1a1a; border: 1px solid #5a2a2a; color: #e8a0a0;
    padding: 0.5rem 0.7rem; border-radius: 5px; font-size: 0.8rem; margin: 0 0 0.8rem;
  }
  .hint { color: #667; font-size: 0.78rem; margin: 0.8rem 0 0; }

  .acct-status { display: flex; align-items: center; gap: 0.5rem; color: #ccc; font-size: 0.9rem; margin: 0; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #888; }
  .dot.on { background: #4caf50; }
  .scopes { margin: 0; padding-left: 1.1rem; color: #ccc; font-size: 0.82rem; }
  .scopes li { margin: 0.2rem 0; }

  .shortcuts h4 {
    font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.05em;
    color: #667; margin: 1rem 0 0.3rem;
  }
  .shortcuts h4:first-child { margin-top: 0; }
  .shortcuts dl { display: grid; grid-template-columns: auto 1fr; gap: 0.2rem 0.8rem; margin: 0; }
  .shortcuts dt { font-family: monospace; color: #7ec8e3; font-size: 0.8rem; }
  .shortcuts dd { margin: 0; color: #aaa; font-size: 0.8rem; }

  .about { text-align: center; padding: 0.5rem 0; }
  .about .name { margin: 0; font-size: 1.5rem; color: #7ec8e3; }
  .about .tagline { margin: 0.3rem 0 1.3rem; color: #888; font-size: 0.85rem; }
  .about .meta {
    display: grid; grid-template-columns: auto 1fr; gap: 0.4rem 1rem;
    text-align: left; margin: 0 auto 1rem; max-width: 460px;
  }
  .about .meta dt { color: #667; font-size: 0.8rem; }
  .about .meta dd { margin: 0; color: #ccc; font-size: 0.8rem; }
  .about .version { font-family: monospace; color: #e0e0e0; }
  .about .path { font-family: monospace; font-size: 0.72rem; word-break: break-all; color: #99a; }
  .about .meta a { color: #7ec8e3; text-decoration: none; word-break: break-all; }
  .about .meta a:hover { text-decoration: underline; }
  .about .license { color: #555; font-size: 0.75rem; margin: 0.5rem 0 0; }

  @media (max-width: 700px) {
    .body { flex-direction: column; }
    .tabs { flex-direction: row; min-width: 0; border-right: none; border-bottom: 1px solid #2a2a4a; overflow-x: auto; }
  }
</style>
