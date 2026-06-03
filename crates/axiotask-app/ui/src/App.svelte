<script>
  import { invoke } from "@tauri-apps/api/core";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { LogicalSize, LogicalPosition } from "@tauri-apps/api/window";
  import Sidebar from "./Sidebar.svelte";
  import QuickAdd from "./QuickAdd.svelte";
  import TodayView from "./TodayView.svelte";
  import ListView from "./ListView.svelte";
  import NotesPanel from "./NotesPanel.svelte";
  import Toast from "./Toast.svelte";
  import Cheatsheet from "./Cheatsheet.svelte";
  import ContextMenu from "./ContextMenu.svelte";
  import SortDropdown from "./SortDropdown.svelte";
  import TaskDetail from "./TaskDetail.svelte";
  import SearchOverlay from "./SearchOverlay.svelte";
  import MoveToListPicker from "./MoveToListPicker.svelte";

  // --- State ---
  let lists = $state([]);
  let allTasks = $state([]); // all tasks from all lists
  let selectedView = $state("focus"); // "focus" | "upcoming" | "missed" | "unscheduled" | "all" | list id
  let loading = $state(true);
  let error = $state(null);
  let authenticated = $state(false);
  let syncStatus = $state("idle");
  let lastSynced = $state(null);
  let showCompleted = $state(localStorage.getItem("axiotask:showCompleted") === "true");
  let completedBottom = $state(true);
  let sortMode = $state("manual"); // per-view, restored from localStorage
  let notesTask = $state(null);
  let undoItem = $state(null);
  let showCheatsheet = $state(false);
  let focusIndex = $state(0);
  let editingId = $state(null);
  let contextMenu = $state(null); // { items, x, y }
  let detailTask = $state(null); // task object for detail panel
  let showSearch = $state(false);
  let movePickerTask = $state(null); // task to move via Ctrl+M picker
  let collapsed = $state(new Set());
  let completingIds = $state(new Set());
  let showClearConfirm = $state(false);

  // --- Safe invoke ---
  let errorToast = $state(null);

  async function cmd(name, args = {}) {
    try { return await invoke(name, args); }
    catch (e) {
      console.error(`[${name}]`, e);
      errorToast = { message: `Failed: ${name} — ${e}`, timer: setTimeout(() => errorToast = null, 5000) };
      return null;
    }
  }

  // --- Data loading ---
  async function loadAll() {
    const result = await cmd("list_tasklists");
    if (result) lists = result;
    // Load tasks from all lists
    let tasks = [];
    for (const list of lists) {
      const t = await cmd("list_tasks", { listId: list.id });
      if (t) tasks.push(...t.map(task => ({ ...task, listTitle: list.title, listId: list.id })));
    }
    allTasks = tasks;
    loading = false;
  }

  async function checkAuth() {
    const r = await cmd("auth_status");
    authenticated = r === true;
  }

  async function init() {
    await checkAuth();
    await loadAll();
    if (authenticated) {
      doSync();
    }
  }

  $effect(() => { init(); });

  // --- Window geometry persistence ---
  $effect(() => {
    // Restore window geometry on mount
    const geo = JSON.parse(localStorage.getItem("axiotask:windowGeometry") || "null");
    if (geo) {
      try {
        getCurrentWindow().setSize(new LogicalSize(geo.width, geo.height));
        getCurrentWindow().setPosition(new LogicalPosition(geo.x, geo.y));
      } catch {}
    }
  });

  function saveWindowGeometry() {
    Promise.all([
      getCurrentWindow().outerSize(),
      getCurrentWindow().outerPosition(),
    ]).then(([size, pos]) => {
      localStorage.setItem("axiotask:windowGeometry", JSON.stringify({
        width: size.width, height: size.height, x: pos.x, y: pos.y,
      }));
    }).catch(() => {});
  }

  // Restore view from localStorage
  $effect(() => {
    const saved = localStorage.getItem("axiotask:view");
    if (saved) selectedView = saved;
  });
  $effect(() => {
    if (selectedView) localStorage.setItem("axiotask:view", selectedView);
    try { 
      const titles = { focus: "Focus", upcoming: "Upcoming", missed: "Missed", unscheduled: "Unscheduled", all: "All Tasks" };
      const title = titles[selectedView] || lists.find(l => l.id === selectedView)?.title || "axiotask";
      getCurrentWindow().setTitle(`${title} — axiotask`);
    } catch {}
  });

  // --- Derived views ---
  // --- Preferences ---
  let excludedLists = $state(JSON.parse(localStorage.getItem("axiotask:excludedLists") || "[]"));
  $effect(() => { localStorage.setItem("axiotask:excludedLists", JSON.stringify(excludedLists)); });
  $effect(() => { localStorage.setItem("axiotask:showCompleted", String(showCompleted)); });

  function isExcluded(listId) { return excludedLists.includes(listId); }
  function toggleExclude(listId) {
    if (isExcluded(listId)) excludedLists = excludedLists.filter(id => id !== listId);
    else excludedLists = [...excludedLists, listId];
  }

  // --- Smart view filters ---
  function smartTasks() {
    return allTasks.filter(t => !isExcluded(t.listId) && (showCompleted || t.status !== "completed"));
  }

  function focusTasks() {
    const now = new Date(); now.setHours(0,0,0,0);
    const weekEnd = new Date(now.getTime() + 7 * 86400000);
    return smartTasks().filter(t => {
      if (!t.due) return false;
      const d = new Date(t.due); d.setHours(0,0,0,0);
      return d < weekEnd;
    });
  }

  function upcomingTasks() {
    const now = new Date(); now.setHours(0,0,0,0);
    const end = new Date(now.getTime() + 14 * 86400000);
    return smartTasks().filter(t => {
      if (!t.due) return false;
      const d = new Date(t.due); d.setHours(0,0,0,0);
      return d > now && d <= end;
    });
  }

  function missedTasks() {
    const now = new Date(); now.setHours(0,0,0,0);
    return smartTasks().filter(t => {
      if (!t.due) return false;
      const d = new Date(t.due); d.setHours(0,0,0,0);
      return d < now;
    }).sort((a, b) => new Date(a.due) - new Date(b.due)); // oldest first
  }

  function unscheduledTasks() {
    return smartTasks().filter(t => !t.due);
  }

  function listTasks(listId) {
    return allTasks.filter(t => t.listId === listId && (showCompleted || t.status !== "completed"));
  }

  function visibleTasks() {
    switch (selectedView) {
      case "focus": return focusTasks();
      case "upcoming": return upcomingTasks();
      case "missed": return missedTasks();
      case "unscheduled": return unscheduledTasks();
      case "all": return allTasks.filter(t => showCompleted || t.status !== "completed");
      default: return listTasks(selectedView);
    }
  }

  function applySortAndOrder(tasks) {
    let sorted = [...tasks];
    // Apply sort mode
    if (sortMode === "due") {
      sorted.sort((a, b) => {
        if (!a.due && !b.due) return 0;
        if (!a.due) return 1;
        if (!b.due) return -1;
        return new Date(a.due) - new Date(b.due);
      });
    } else if (sortMode === "alpha") {
      sorted.sort((a, b) => (a.title || "").localeCompare(b.title || ""));
    } else if (sortMode === "created") {
      sorted.sort((a, b) => (b.position || "").localeCompare(a.position || ""));
    }
    // Completed at bottom
    if (completedBottom) {
      const open = sorted.filter(t => t.status !== "completed");
      const done = sorted.filter(t => t.status === "completed");
      sorted = [...open, ...done];
    }
    return sorted;
  }

  // Restore sort mode per view
  $effect(() => {
    const saved = localStorage.getItem(`axiotask:sort:${selectedView}`);
    sortMode = saved || "manual";
  });
  // Persist sort mode
  $effect(() => {
    if (selectedView) localStorage.setItem(`axiotask:sort:${selectedView}`, sortMode);
  });

  let flatTasks = $derived(buildFlatTree(applySortAndOrder(visibleTasks())));

  // Counts for sidebar badges
  let viewCounts = $derived.by(() => {
    const open = t => t.status !== "completed";
    const c = {};
    c.focus = focusTasks().filter(open).length;
    c.upcoming = upcomingTasks().filter(open).length;
    c.missed = missedTasks().filter(open).length;
    c.unscheduled = unscheduledTasks().filter(open).length;
    c.all = allTasks.filter(open).length;
    for (const list of lists) {
      c[list.id] = allTasks.filter(t => t.listId === list.id && open(t)).length;
    }
    return c;
  });

  function buildFlatTree(tasks) {
    // Flat list: only top-level tasks, no tree indentation
    return tasks.filter(t => !t.parent_id).map(t => ({
      ...t,
      depth: 0,
      hasChildren: allTasks.some(c => c.parent_id === t.id),
      isCollapsed: false,
    }));
  }

  // --- Actions ---
  async function createTask(title, listId) {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all"].includes(selectedView);
    const resolvedListId = isSmartView ? null : listId;
    const targetList = resolvedListId || (!isSmartView ? selectedView : lists[0]?.id);
    if (!targetList || !title.trim()) return;
    const task = await cmd("create_task", { listId: targetList, parentId: null, title: title.trim() });
    if (task) {
      selectedView = targetList;
      await loadAll();
      // New task at top — focus it and enter edit mode
      focusIndex = 0;
      editingId = task.id;
    }
  }

  async function addSubtask(parentId) {
    const parent = allTasks.find(t => t.id === parentId);
    if (!parent) return;
    const task = await cmd("create_task", { listId: parent.listId, parentId, title: "" });
    if (task) {
      await loadAll();
      // Open detail panel for the parent task to show subtasks
      detailTask = allTasks.find(t => t.id === parentId) || parent;
      editingId = task.id;
    }
  }

  async function toggleComplete(id) {
    const task = allTasks.find(t => t.id === id);
    const wasOpen = task?.status === "needsAction";
    await cmd("toggle_complete", { id });
    if (wasOpen) {
      // Animate: add completing class, wait 300ms, then reload
      completingIds = new Set([...completingIds, id]);
      setTimeout(async () => {
        completingIds = new Set([...completingIds].filter(x => x !== id));
        await loadAll();
        undoItem = { id, title: task.title, listId: task.listId, isComplete: true, timer: setTimeout(() => { undoItem = null; }, 10000) };
      }, 300);
    } else {
      await loadAll();
    }
  }

  async function deleteTask(id) {
    const task = allTasks.find(t => t.id === id);
    if (!task) return;
    const token = await cmd("delete_task", { id });
    undoItem = { id, title: task.title, listId: task.listId, deleteToken: token, timer: setTimeout(() => { undoItem = null; }, 30000) };
    await loadAll();
    focusIndex = Math.min(focusIndex, Math.max(0, flatTasks.length - 1));
  }

  async function renameTask(id, title) {
    editingId = null;
    if (!title.trim()) { await deleteTask(id); return; }
    await cmd("rename_task", { id, title: title.trim() });
    await loadAll();
  }

  async function setDue(id, mv) {
    await cmd("set_due", { id, mv });
    await loadAll();
  }

  async function moveTask(id, parentId) {
    await cmd("move_task", { id, parentId, previousId: null });
    await loadAll();
  }

  async function reorderTask(id, direction) {
    await cmd("reorder_task", { id, direction });
    await loadAll();
  }

  async function handleDragReorder(id, direction, steps = 1) {
    for (let i = 0; i < steps; i++) {
      await cmd("reorder_task", { id, direction });
    }
    await loadAll();
  }

  async function handleUndo() {
    if (!undoItem) return;
    clearTimeout(undoItem.timer);
    if (undoItem.isComplete) {
      // Undo completion — toggle it back
      await cmd("toggle_complete", { id: undoItem.id });
    } else if (undoItem.deleteToken) {
      // Undo delete — restore via token
      await cmd("undo_delete", { token: undoItem.deleteToken });
    } else {
      // Fallback: re-create
      await cmd("create_task", { listId: undoItem.listId, parentId: null, title: undoItem.title || "Untitled" });
    }
    undoItem = null;
    await loadAll();
  }

  async function openNotes(id) {
    notesTask = allTasks.find(t => t.id === id) || null;
  }

  async function saveNotes(id, notes) {
    await cmd("set_notes", { id, notes });
    await loadAll();
  }

  async function doSync() {
    syncStatus = "syncing";
    const r = await cmd("sync_now");
    if (r !== null) { lastSynced = new Date(); syncStatus = "idle"; await loadAll(); }
    else { syncStatus = "error"; error = "Sync failed"; }
  }

  async function login() {
    await cmd("auth_login");
    authenticated = true;
    await doSync();
  }

  async function createList(title) {
    if (!title?.trim()) return;
    await cmd("create_list", { title: title.trim() });
    await loadAll();
  }

  async function moveToList(taskId, targetListId) {
    const task = allTasks.find(t => t.id === taskId);
    const targetList = lists.find(l => l.id === targetListId);
    await cmd("move_to_list", { id: taskId, targetListId });
    await loadAll();
    if (task && targetList) {
      undoItem = { id: taskId, title: `Moved "${task.title}" to ${targetList.title}`, isMoveToast: true, timer: setTimeout(() => { undoItem = null; }, 5000) };
    }
  }

  async function handleMovePickerSelect(list) {
    const task = movePickerTask;
    movePickerTask = null;
    if (task) await moveToList(task.id, list.id);
  }

  async function clearCompleted() {
    showClearConfirm = true;
  }

  async function confirmClearCompleted() {
    const listId = selectedView !== "today" && selectedView !== "all" ? selectedView : null;
    if (!listId) return;
    showClearConfirm = false;
    await cmd("clear_completed", { listId });
    await loadAll();
  }

  function cancelClearCompleted() {
    showClearConfirm = false;
  }

  function completedCount() {
    if (["focus", "upcoming", "missed", "unscheduled", "all", "today"].includes(selectedView)) return 0;
    return allTasks.filter(t => t.listId === selectedView && t.status === "completed").length;
  }

  // Search
  let searchQuery = $state("");
  let searchResults = $derived(
    searchQuery.trim()
      ? allTasks.filter(t =>
          t.title?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          t.notes?.toLowerCase().includes(searchQuery.toLowerCase())
        )
      : null
  );

  // --- Keyboard ---
  function handleFocus(i, action) {
    focusIndex = i;
    if (action === "edit") editingId = flatTasks[i]?.id;
    else detailTask = flatTasks[i] || null;
  }

  async function saveDetail(id, { title, notes, due }) {
    if (title !== undefined) await cmd("rename_task", { id, title });
    if (notes !== undefined) await cmd("set_notes", { id, notes });
    if (due !== undefined) {
      if (due) await cmd("set_due", { id, mv: "raw:" + due });
      else await cmd("set_due", { id, mv: "Clear" });
    }
    await loadAll();
  }

  function handleSearchSelect(task) {
    // Navigate to the task's list and focus it
    selectedView = task.listId;
    loadAll().then(() => {
      const idx = flatTasks.findIndex(t => t.id === task.id);
      if (idx >= 0) focusIndex = idx;
      detailTask = task;
    });
  }

  // Context menu for tasks
  function openTaskContextMenu(task, x, y) {
    contextMenu = {
      x, y,
      items: [
        { id: "edit", icon: "✏️", label: "Edit title", shortcut: "e", action: () => { editingId = task.id; } },
        { id: "notes", icon: "📝", label: "Edit notes", shortcut: "n", action: () => { notesTask = allTasks.find(t => t.id === task.id); } },
        "separator",
        { id: "due", icon: "📅", label: "Set due date", submenu: [
          { label: "Today", action: () => setDue(task.id, "Today") },
          { label: "Tomorrow", action: () => setDue(task.id, "Tomorrow") },
          { label: "Next week", action: () => setDue(task.id, "NextWeek") },
          { label: "Next month", action: () => setDue(task.id, "NextMonth") },
          { label: "Clear", action: () => setDue(task.id, "Clear") },
        ]},
        { id: "move", icon: "↗️", label: "Move to list", submenu: lists.map(l => ({
          label: l.title, action: () => moveToList(task.id, l.id)
        }))},
        "separator",
        { id: "subtask", icon: "⬆️", label: "Add subtask", action: async () => {
          const t = await cmd("create_task", { listId: task.listId, parentId: task.id, title: "" });
          if (t) { await loadAll(); editingId = t.id; }
        }},
        { id: "duplicate", icon: "📋", label: "Duplicate", shortcut: "Ctrl+D", action: async () => {
          await cmd("create_task", { listId: task.listId, parentId: task.parent_id, title: task.title + " (copy)" });
          await loadAll();
        }},
        "separator",
        { id: "delete", icon: "🗑️", label: "Delete", shortcut: "d", action: () => deleteTask(task.id) },
      ]
    };
  }

  // Ctrl+V paste to create
  async function handlePaste(e) {
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
    const text = e.clipboardData?.getData("text/plain")?.trim();
    if (!text) return;
    e.preventDefault();

    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all"].includes(selectedView);
    const targetList = !isSmartView ? selectedView : lists[0]?.id;
    if (!targetList) return;

    const lines = text.split("\n").map(l => l.trim()).filter(l => l.length > 0);
    for (const line of lines) {
      const isLong = line.length > 500;
      const title = isLong ? line.slice(0, 500) : line;
      const task = await cmd("create_task", { listId: targetList, parentId: null, title });
      if (isLong && task) await cmd("set_notes", { id: task.id, notes: line });
    }
    await loadAll();
    selectedView = targetList;
    undoItem = { id: null, title: `${lines.length} task${lines.length > 1 ? "s" : ""} from clipboard`, listId: targetList, timer: setTimeout(() => { undoItem = null; }, 5000) };
  }

  // List context menu
  function openListContextMenu(list, x, y) {
    const isExcl = excludedLists.includes(list.id);
    contextMenu = {
      x, y,
      items: [
        { id: "rename", icon: "✏️", label: "Rename", action: async () => {
          const name = prompt("Rename list:", list.title);
          if (name?.trim()) { await cmd("rename_list", { id: list.id, title: name.trim() }); await loadAll(); }
        }},
        { id: "exclude", icon: isExcl ? "✅" : "🚫", label: isExcl ? "Include in smart views" : "Exclude from smart views", action: () => toggleExclude(list.id) },
        "separator",
        { id: "delete", icon: "🗑️", label: "Delete list", action: async () => {
          if (confirm(`Delete "${list.title}" and all its tasks?`)) {
            await cmd("delete_list", { id: list.id });
            if (selectedView === list.id) selectedView = "focus";
            await loadAll();
          }
        }},
      ]
    };
  }

  // Subtask progress for a parent task
  function getSubtaskProgress(taskId) {
    const children = allTasks.filter(t => t.parent_id === taskId);
    if (children.length === 0) return null;
    const done = children.filter(t => t.status === "completed").length;
    return { done, total: children.length };
  }

  function focused() { return flatTasks[focusIndex] ?? null; }

  function quickAddTargetName() {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all", "today"].includes(selectedView);
    if (!isSmartView) return lists.find(l => l.id === selectedView)?.title || null;
    return lists[0]?.title || null;
  }

  async function handleKeydown(e) {
    if (showCheatsheet) { showCheatsheet = false; e.preventDefault(); return; }
    if (showClearConfirm) { showClearConfirm = false; e.preventDefault(); return; }
    if (editingId || e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
    if (movePickerTask && e.key === "Escape") { movePickerTask = null; e.preventDefault(); return; }
    if (notesTask && e.key === "Escape") { notesTask = null; e.preventDefault(); return; }
    if (detailTask && e.key === "Escape") { detailTask = null; e.preventDefault(); return; }
    if (notesTask || detailTask) return;

    const f = focused();
    const len = flatTasks.length;

    switch (e.key) {
      case "?": e.preventDefault(); showCheatsheet = true; break;
      case "/": e.preventDefault(); showSearch = true; break;
      case "m":
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          if (f) movePickerTask = f;
        } else {
          e.preventDefault(); if (f) await setDue(f.id, "NextMonth");
        }
        break;
      case "j": case "ArrowDown":
        e.preventDefault();
        if (e.altKey && f && sortMode === "manual") { await reorderTask(f.id, "down"); if (focusIndex < len-1) focusIndex++; }
        else if (len > 0) focusIndex = Math.min(focusIndex + 1, len - 1);
        break;
      case "k": case "ArrowUp":
        e.preventDefault();
        if (e.altKey && f && sortMode === "manual") { await reorderTask(f.id, "up"); if (focusIndex > 0) focusIndex--; }
        else if (len > 0) focusIndex = Math.max(focusIndex - 1, 0);
        break;
      case " ": e.preventDefault(); if (f) await toggleComplete(f.id); break;
      case "h": case "ArrowLeft":
        e.preventDefault();
        if (f?.hasChildren && !collapsed.has(f.id)) {
          collapsed = new Set([...collapsed, f.id]);
        } else if (f?.parent_id) {
          const pi = flatTasks.findIndex(t => t.id === f.parent_id);
          if (pi >= 0) focusIndex = pi;
        }
        break;
      case "l": case "ArrowRight":
        e.preventDefault();
        if (f && collapsed.has(f.id)) {
          const next = new Set(collapsed); next.delete(f.id); collapsed = next;
        }
        break;
      case "Enter":
        e.preventDefault();
        {
          const targetList = f?.listId || (selectedView !== "today" && selectedView !== "all" ? selectedView : lists[0]?.id);
          if (!targetList) break;
          if (e.shiftKey && f) {
            // Create subtask and open detail panel
            await addSubtask(f.id);
          } else {
            const parentId = f?.parent_id || null;
            const task = await cmd("create_task", { listId: targetList, parentId, title: "" });
            if (task) { await loadAll(); editingId = task.id; }
          }
        }
        break;
      case "e": e.preventDefault(); if (f) editingId = f.id; break;
      case "n": e.preventDefault(); if (f) openNotes(f.id); break;
      case "d": e.preventDefault(); if (f) await deleteTask(f.id); break;
      case "t": e.preventDefault(); if (f) await setDue(f.id, "Tomorrow"); break;
      case "w": e.preventDefault(); if (f) await setDue(f.id, "NextWeek"); break;
      case "r": e.preventDefault(); if (f) await setDue(f.id, "Clear"); break;
      case "Tab":
        e.preventDefault();
        if (!f) break;
        if (e.shiftKey) { if (f.parent_id) await moveTask(f.id, null); }
        else { const prev = flatTasks[focusIndex - 1]; if (prev && prev.depth === f.depth) await moveTask(f.id, prev.id); }
        break;
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} onpaste={handlePaste} onbeforeunload={saveWindowGeometry} />

<main class="app">
  <Sidebar
    {lists}
    {selectedView}
    onselect={(v) => { selectedView = v; focusIndex = 0; detailTask = null; }}
    onlogin={login}
    onsync={doSync}
    oncreateList={createList}
    onlistaction={openListContextMenu}
    {authenticated}
    {syncStatus}
    {lastSynced}
    {excludedLists}
    counts={viewCounts}
  />
  <section class="content">
    <QuickAdd oncreate={createTask} currentListId={["focus", "upcoming", "missed", "unscheduled", "all", "today"].includes(selectedView) ? null : selectedView} targetListName={quickAddTargetName()} />
    <div class="toolbar">
      <SortDropdown value={sortMode} onchange={(v) => sortMode = v} />
      <label class="toggle">
        <input type="checkbox" bind:checked={showCompleted} /> Show completed
      </label>
      {#if showCompleted && selectedView !== "focus" && selectedView !== "upcoming" && selectedView !== "missed" && selectedView !== "unscheduled" && selectedView !== "all"}
        <button class="clear-btn" onclick={clearCompleted}>Clear completed</button>
      {/if}
      {#if sortMode !== "manual"}
        <span class="sort-notice">⚠ Reorder disabled</span>
      {/if}
    </div>
    {#if loading}
      <p class="status">Loading...</p>
    {:else if error}
      <p class="status error">{error}</p>
    {:else if selectedView === "focus"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {getSubtaskProgress} {showCompleted} viewType="focus" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "upcoming"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {getSubtaskProgress} {showCompleted} viewType="upcoming" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "missed"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {getSubtaskProgress} {showCompleted} viewType="missed" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "unscheduled"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {getSubtaskProgress} {showCompleted} viewType="unscheduled" {sortMode} onreorder={handleDragReorder} />
    {:else}
      <ListView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {getSubtaskProgress} isCrossList={selectedView === "all"} {sortMode} onreorder={handleDragReorder} />
    {/if}
  </section>
  {#if detailTask}
    <TaskDetail
      task={detailTask}
      {lists}
      subtasks={allTasks.filter(t => t.parent_id === detailTask.id)}
      onsave={saveDetail}
      onclose={() => detailTask = null}
      ondelete={deleteTask}
      onmovelist={moveToList}
      ontogglesubtask={toggleComplete}
    />
  {:else if notesTask}
    <NotesPanel taskId={notesTask.id} notes={notesTask.notes || ""} onsave={saveNotes} onclose={() => notesTask = null} />
  {/if}
</main>

{#if undoItem}
  <Toast message={undoItem.isMoveToast ? undoItem.title : undoItem.isComplete ? `Completed "${undoItem.title}"` : `Deleted "${undoItem.title || 'task'}"`} onundo={undoItem.isMoveToast ? null : handleUndo} ondismiss={() => { clearTimeout(undoItem.timer); undoItem = null; }} />
{/if}
{#if errorToast}
  <Toast message={errorToast.message} variant="error" ondismiss={() => { clearTimeout(errorToast.timer); errorToast = null; }} />
{/if}
{#if showCheatsheet}
  <Cheatsheet onclose={() => showCheatsheet = false} />
{/if}
{#if contextMenu}
  <ContextMenu items={contextMenu.items} x={contextMenu.x} y={contextMenu.y} onclose={() => contextMenu = null} />
{/if}
{#if showSearch}
  <SearchOverlay tasks={allTasks} onselect={handleSearchSelect} onclose={() => showSearch = false} />
{/if}
{#if movePickerTask}
  <MoveToListPicker {lists} currentListId={movePickerTask.listId} onselect={handleMovePickerSelect} onclose={() => movePickerTask = null} />
{/if}
{#if showClearConfirm}
  <div class="confirm-overlay" role="dialog" aria-modal="true">
    <div class="confirm-dialog">
      <p>Delete {completedCount()} completed task{completedCount() === 1 ? "" : "s"}? This cannot be undone.</p>
      <div class="confirm-actions">
        <button class="confirm-cancel" onclick={cancelClearCompleted}>Cancel</button>
        <button class="confirm-delete" onclick={confirmClearCompleted}>Delete</button>
      </div>
    </div>
  </div>
{/if}

<style>
  :global(body) { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #1a1a2e; color: #e0e0e0; -webkit-tap-highlight-color: transparent; }
  :global(*, *::before, *::after) { box-sizing: border-box; }
  .app { display: flex; height: 100vh; height: 100dvh; }
  .content { flex: 1; display: flex; flex-direction: column; overflow: hidden; min-width: 0; }
  .toolbar { padding: 0.4rem 1rem; display: flex; align-items: center; border-bottom: 1px solid #2a2a4a; gap: 0.5rem; flex-wrap: wrap; }
  .toggle { font-size: 0.8rem; color: #888; cursor: pointer; display: flex; align-items: center; gap: 0.4rem; }
  .toggle input { cursor: pointer; width: 1rem; height: 1rem; }
  .clear-btn { background: none; border: 1px solid #3a3a5a; color: #888; padding: 0.2rem 0.5rem; border-radius: 3px; font-size: 0.75rem; cursor: pointer; margin-left: auto; }
  .clear-btn:hover { background: #2a2a4a; color: #e74c3c; }
  .sort-notice { font-size: 0.7rem; color: #ff9800; margin-left: 0.5rem; }
  .status { color: #888; text-align: center; margin-top: 4rem; }
  .status.error { color: #e74c3c; }

  /* Mobile (<700px): sidebar becomes top nav, full-screen detail */
  @media (max-width: 700px) {
    .app { flex-direction: column; }
    .toolbar { padding: 0.3rem 0.75rem; }
  }

  /* Touch devices: 44px minimum tap targets */
  @media (pointer: coarse) {
    .toggle { font-size: 0.9rem; padding: 0.3rem 0; min-height: 44px; }
    .toggle input { width: 1.5rem; height: 1.5rem; }
    .clear-btn { padding: 0.5rem 0.8rem; font-size: 0.85rem; min-height: 44px; }
  }

  .confirm-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 1000; }
  .confirm-dialog { background: #2a2a4a; border: 1px solid #3a3a5a; border-radius: 8px; padding: 1.5rem; max-width: 360px; width: 90%; }
  .confirm-dialog p { margin: 0 0 1rem; color: #e0e0e0; }
  .confirm-actions { display: flex; gap: 0.5rem; justify-content: flex-end; }
  .confirm-cancel { background: none; border: 1px solid #3a3a5a; color: #aaa; padding: 0.4rem 1rem; border-radius: 4px; cursor: pointer; }
  .confirm-cancel:hover { background: #3a3a5a; }
  .confirm-delete { background: #e74c3c; border: none; color: #fff; padding: 0.4rem 1rem; border-radius: 4px; cursor: pointer; }
  .confirm-delete:hover { background: #c0392b; }
</style>
