<script>
  let { lists, selectedView, onselect, onlogin, onlogout, onsync, onfreshsync, oncreateList, onrenameList, onlistaction, onabout, authenticated, syncStatus, lastSynced, excludedLists = [], counts = {}, renamingListId = null } = $props();

  let newListMode = $state(false);
  let newListValue = $state("");
  let editingListId = $state(null);
  let editingListValue = $state("");
  let newListInput = $state(null);
  let editListInput = $state(null);

  $effect(() => {
    if (renamingListId) {
      const list = lists.find(l => l.id === renamingListId);
      if (list) {
        editingListId = renamingListId;
        editingListValue = list.title;
        setTimeout(() => editListInput?.focus(), 0);
      }
    }
  });

  function formatSynced(date) {
    if (!date) return "";
    const secs = Math.floor((Date.now() - date.getTime()) / 1000);
    if (secs < 60) return "just now";
    if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
    return `${Math.floor(secs / 3600)}h ago`;
  }

  function handleNewList() {
    newListMode = true;
    newListValue = "";
    setTimeout(() => newListInput?.focus(), 0);
  }

  function submitNewList() {
    if (newListValue.trim()) oncreateList(newListValue.trim());
    newListMode = false;
    newListValue = "";
  }

  function cancelNewList() {
    newListMode = false;
    newListValue = "";
  }

  function submitRename() {
    if (editingListValue.trim() && editingListId) {
      onrenameList(editingListId, editingListValue.trim());
    }
    editingListId = null;
    editingListValue = "";
  }

  function cancelRename() {
    editingListId = null;
    editingListValue = "";
  }
</script>

<aside class="sidebar">
  <div class="header"><h1>axiotask</h1></div>

  <nav class="views">
    <button class:active={selectedView === "focus"} onclick={() => onselect("focus")}>★ Focus {#if counts.focus}<span class="count">{counts.focus}</span>{/if}</button>
    <button class:active={selectedView === "upcoming"} onclick={() => onselect("upcoming")}>☰ Upcoming {#if counts.upcoming}<span class="count">{counts.upcoming}</span>{/if}</button>
    <button class:active={selectedView === "missed"} onclick={() => onselect("missed")}>⚠ Missed {#if counts.missed}<span class="count">{counts.missed}</span>{/if}</button>
    <button class:active={selectedView === "unscheduled"} onclick={() => onselect("unscheduled")}>○ Unscheduled {#if counts.unscheduled}<span class="count">{counts.unscheduled}</span>{/if}</button>
    <button class:active={selectedView === "all"} onclick={() => onselect("all")}>▤ All Tasks {#if counts.all}<span class="count">{counts.all}</span>{/if}</button>
  </nav>

  <div class="section-header">
    <h2>Lists</h2>
    <button class="icon-btn" onclick={handleNewList} title="New list">+</button>
  </div>
  <nav class="lists">
    {#each lists as list}
      {#if editingListId === list.id}
        <input
          bind:this={editListInput}
          bind:value={editingListValue}
          class="inline-input"
          onkeydown={(e) => { if (e.key === "Enter") submitRename(); else if (e.key === "Escape") cancelRename(); }}
          onblur={submitRename}
        />
      {:else}
        <button
          class:active={selectedView === list.id}
          class:excluded={excludedLists.includes(list.id)}
          onclick={() => onselect(list.id)}
          oncontextmenu={(e) => { e.preventDefault(); onlistaction?.(list, e.clientX, e.clientY); }}
        >
          {list.title}
          {#if counts[list.id]}<span class="count">{counts[list.id]}</span>{/if}
        </button>
      {/if}
    {/each}
    {#if newListMode}
      <input
        bind:this={newListInput}
        bind:value={newListValue}
        class="inline-input"
        placeholder="List name..."
        onkeydown={(e) => { if (e.key === "Enter") submitNewList(); else if (e.key === "Escape") cancelNewList(); }}
        onblur={submitNewList}
      />
    {/if}
    {#if lists.length === 0 && !newListMode}
      <p class="no-lists">No lists yet</p>
    {/if}
  </nav>

  <div class="footer">
    {#if !authenticated}
      <button class="action-btn" onclick={onlogin} disabled={syncStatus === "syncing"}>
        {syncStatus === "syncing" ? "Signing in..." : "Sign in with Google"}
      </button>
    {:else}
      <button class="action-btn sync-btn" onclick={onsync} disabled={syncStatus === "syncing"}>
        {syncStatus === "syncing" ? "Syncing..." : "↻ Sync now"}
      </button>
    {/if}
    <button class="action-btn fresh-sync-btn" onclick={onfreshsync} disabled={syncStatus === "syncing" || !authenticated}>
      ⟳ Fresh sync
    </button>
    <div class="sync-info">
      <span class="sync-dot" class:syncing={syncStatus === "syncing"} class:error={syncStatus === "error"} class:offline={!authenticated}></span>
      <span class="sync-text">
        {#if syncStatus === "error"}Sync error
        {:else if lastSynced}Synced {formatSynced(lastSynced)}
        {:else if authenticated}Ready
        {:else}Offline
        {/if}
      </span>
      {#if authenticated}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <span class="sign-out" onclick={onlogout}>Sign out</span>
      {/if}
    </div>
    <button class="about-btn" onclick={onabout} title="About axiotask">About</button>
  </div>
</aside>

<style>
  .sidebar { width: 200px; background: #16213e; display: flex; flex-direction: column; border-right: 1px solid #2a2a4a; }
  .header { padding: 1rem 1rem 0.5rem; }
  .header h1 { font-size: 1.1rem; margin: 0; color: #7ec8e3; }
  .views { padding: 0.5rem; display: flex; flex-direction: column; gap: 2px; }
  .views button, .lists button {
    width: 100%; text-align: left; background: none; border: none;
    color: #ccc; padding: 0.4rem 0.6rem; border-radius: 4px; cursor: pointer; font-size: 0.9rem; font-family: inherit;
  }
  .views button:hover, .lists button:hover { background: #1a1a3e; }
  .views button.active, .lists button.active { background: #0f3460; color: #fff; }
  .lists button.excluded { opacity: 0.5; font-style: italic; }
  .count { font-size: 0.7rem; color: #555; background: #2a2a4a; padding: 0.1rem 0.35rem; border-radius: 8px; margin-left: auto; }
  .section-header { display: flex; align-items: center; justify-content: space-between; padding: 0.75rem 1rem 0.25rem; }
  .section-header h2 { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; color: #555; margin: 0; }
  .icon-btn { background: none; border: 1px solid #3a3a5a; color: #888; width: 20px; height: 20px; border-radius: 3px; cursor: pointer; font-size: 0.9rem; display: flex; align-items: center; justify-content: center; }
  .icon-btn:hover { background: #0f3460; color: #fff; border-color: #0f3460; }
  .lists { padding: 0 0.5rem; flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
  .no-lists { color: #444; font-size: 0.8rem; padding: 0.4rem 0.6rem; }
  .inline-input { width: 100%; padding: 0.35rem 0.6rem; background: #1a2a4a; border: 1px solid #3a4a6a; border-radius: 4px; color: #e0e0e0; font-size: 0.85rem; outline: none; box-sizing: border-box; }
  .inline-input:focus { border-color: #7ec8e3; }
  .footer { padding: 0.75rem; border-top: 1px solid #2a2a4a; display: flex; flex-direction: column; gap: 0.4rem; }
  .action-btn { width: 100%; background: #2a2a4a; color: #ccc; border: none; padding: 0.45rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem; font-family: inherit; }
  .action-btn:hover { background: #3a3a5a; }
  .action-btn:disabled { opacity: 0.5; cursor: default; }
  .sync-info { display: flex; align-items: center; gap: 0.4rem; padding: 0 0.2rem; }
  .sync-dot { width: 7px; height: 7px; border-radius: 50%; background: #4caf50; }
  .sync-dot.offline { background: #666; }
  .sync-dot.syncing { background: #ff9800; animation: pulse 1s infinite; }
  .sync-dot.error { background: #e74c3c; }
  .sync-text { font-size: 0.7rem; color: #666; }
  .sign-out { font-size: 0.7rem; color: #666; cursor: pointer; margin-left: auto; }
  .sign-out:hover { color: #e74c3c; }
  .about-btn { background: none; border: none; color: #555; font-size: 0.7rem; cursor: pointer; font-family: inherit; padding: 0.2rem; align-self: center; }
  .about-btn:hover { color: #7ec8e3; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }

  /* Mobile: horizontal compact nav */
  @media (max-width: 700px) {
    .sidebar {
      width: 100%; flex-direction: row; align-items: center;
      border-right: none; border-bottom: 1px solid #2a2a4a;
      padding: 0.4rem; gap: 0.3rem; overflow-x: auto;
    }
    .header { padding: 0 0.5rem; }
    .header h1 { font-size: 0.9rem; }
    .views { flex-direction: row; padding: 0; gap: 0.2rem; }
    .views button, .lists button { width: auto; padding: 0.3rem 0.6rem; font-size: 0.8rem; white-space: nowrap; }
    .section-header { display: none; }
    .lists { flex-direction: row; padding: 0; overflow-x: auto; flex: unset; }
    .footer { display: none; }
    .no-lists { display: none; }
  }

  /* Touch: 44px minimum tap targets */
  @media (pointer: coarse) {
    .views button, .lists button { padding: 0.6rem 0.8rem; min-height: 44px; }
    .icon-btn { width: 44px; height: 44px; }
    .action-btn { padding: 0.6rem; font-size: 0.9rem; min-height: 44px; }
  }
</style>
