<script>
  let { lists, selectedView, onselect, onlogin, onlogout, onsync, onfreshsync, oncreateList, onrenameList, onlistaction, onreorderlists, onproperties, authenticated, syncStatus, lastSynced, excludedLists = [], counts = {}, renamingListId = null } = $props();

  let newListMode = $state(false);
  let newListValue = $state("");
  let newListLocalOnly = $state(false);
  let editingListId = $state(null);
  let editingListValue = $state("");
  let newListInput = $state(null);
  let editListInput = $state(null);

  // Drag-to-reorder state for the lists.
  let draggingListId = $state(null);
  let dropTargetId = $state(null);

  function handleListDragStart(e, id) {
    // WebKit only initiates a drag when data is set in dragstart.
    e.dataTransfer?.setData("text/plain", id);
    if (e.dataTransfer) e.dataTransfer.effectAllowed = "move";
    draggingListId = id;
  }
  function handleListDragEnd() { draggingListId = null; dropTargetId = null; }
  function handleListDragOver(e, id) {
    if (!draggingListId) return;
    e.preventDefault(); // allow the drop
    dropTargetId = id;
  }
  function handleListDrop(targetId) {
    if (!draggingListId || draggingListId === targetId) { handleListDragEnd(); return; }
    const ids = lists.map((l) => l.id);
    const from = ids.indexOf(draggingListId);
    if (from < 0) { handleListDragEnd(); return; }
    ids.splice(from, 1);
    const to = ids.indexOf(targetId);
    // Insert before the list it was dropped on (the drop indicator sits above
    // the target), matching what the user sees.
    ids.splice(to < 0 ? ids.length : to, 0, draggingListId);
    onreorderlists?.(ids);
    handleListDragEnd();
  }

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

  function handleNewList(localOnly = false) {
    newListMode = true;
    newListValue = "";
    newListLocalOnly = localOnly;
    setTimeout(() => newListInput?.focus(), 0);
  }

  function submitNewList() {
    if (newListValue.trim()) oncreateList(newListValue.trim(), newListLocalOnly);
    newListMode = false;
    newListValue = "";
    newListLocalOnly = false;
  }

  function cancelNewList() {
    newListMode = false;
    newListValue = "";
    newListLocalOnly = false;
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
    <div class="list-actions">
      <button class="icon-btn" onclick={() => handleNewList(false)} title="New list">+</button>
      <button class="icon-btn" onclick={() => handleNewList(true)} title="New local-only list">+◍</button>
    </div>
  </div>
  <nav class="lists">
    {#each lists as list (list.id)}
      {#if editingListId === list.id}
        <input
          bind:this={editListInput}
          bind:value={editingListValue}
          class="inline-input"
          onkeydown={(e) => { if (e.key === "Enter") submitRename(); else if (e.key === "Escape") cancelRename(); }}
          onblur={submitRename}
        />
      {:else}
        {#if dropTargetId === list.id && draggingListId && draggingListId !== list.id}
          <div class="list-drop-indicator"></div>
        {/if}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          class="list-row"
          class:dragging={draggingListId === list.id}
          ondragover={(e) => handleListDragOver(e, list.id)}
          ondrop={() => handleListDrop(list.id)}
        >
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <span
            class="list-drag-handle"
            draggable="true"
            ondragstart={(e) => handleListDragStart(e, list.id)}
            ondragend={handleListDragEnd}
            title="Drag to reorder"
            aria-label="Drag to reorder {list.title}"
          >⠿</span>
          <button
            class="list-btn"
            class:active={selectedView === list.id}
            class:excluded={excludedLists.includes(list.id)}
            onclick={() => onselect(list.id)}
            oncontextmenu={(e) => { e.preventDefault(); onlistaction?.(list, e.clientX, e.clientY); }}
          >
            {list.title}
            {#if list.local_only}<span class="local-badge" title="Local only — not synced to Google">local</span>{/if}
            {#if counts[list.id]}<span class="count">{counts[list.id]}</span>{/if}
          </button>
        </div>
      {/if}
    {/each}
    {#if newListMode}
      <input
        bind:this={newListInput}
        bind:value={newListValue}
        class="inline-input"
        placeholder={newListLocalOnly ? "Local list name..." : "List name..."}
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
    <button class="about-btn" onclick={onproperties} title="Properties (,)">⚙ Properties</button>
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
  .list-actions { display: flex; gap: 4px; }
  .icon-btn { background: none; border: 1px solid #3a3a5a; color: #888; min-width: 20px; height: 20px; padding: 0 4px; border-radius: 3px; cursor: pointer; font-size: 0.9rem; display: flex; align-items: center; justify-content: center; }
  .icon-btn:hover { background: #0f3460; color: #fff; border-color: #0f3460; }
  .local-badge { font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.04em; color: #7ec8e3; background: #1a2a4a; border: 1px solid #2a4a6a; padding: 0.05rem 0.3rem; border-radius: 8px; margin-left: 0.35rem; }
  .lists { padding: 0 0.5rem; flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
  .list-row { display: flex; align-items: center; }
  .list-row.dragging { opacity: 0.4; }
  .list-row .list-btn { flex: 1; width: auto; min-width: 0; }
  .list-drag-handle {
    flex-shrink: 0; cursor: grab; color: #3a3a5a; font-size: 0.85rem;
    padding: 0 0.25rem; user-select: none; opacity: 0; transition: opacity 0.1s;
  }
  .list-row:hover .list-drag-handle { opacity: 1; color: #667; }
  .list-drag-handle:hover { color: #7ec8e3; }
  .list-drag-handle:active { cursor: grabbing; }
  .list-drop-indicator { height: 2px; background: #7ec8e3; margin: 0 0.4rem; border-radius: 1px; }
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
