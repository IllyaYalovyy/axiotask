<script>
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { LogicalSize, LogicalPosition } from "@tauri-apps/api/window";
  import Sidebar from "./Sidebar.svelte";
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
  import DatePicker from "./DatePicker.svelte";
  import Properties from "./Properties.svelte";
  import BulkAdd from "./BulkAdd.svelte";
  import { storageKey } from "./storage.js";
  import { getThemePref, setThemePref } from "./theme.js";

  // --- State ---
  let lists = $state([]);
  let allTasks = $state([]); // all tasks from all lists
  let selectedView = $state("focus"); // "focus" | "upcoming" | "missed" | "unscheduled" | "all" | list id
  let loading = $state(true);
  let error = $state(null);
  let authenticated = $state(false);
  let syncStatus = $state("idle");
  let lastSynced = $state(null);
  let lastSyncError = $state(null); // most recent background-sync error message
  let showCompleted = $state(localStorage.getItem(storageKey("showCompleted")) === "true");
  let completedBottom = $state(true);
  let sortMode = $state("manual"); // per-view, restored from localStorage
  let notesTask = $state(null);
  let undoItem = $state(null);
  let showCheatsheet = $state(false);
  let showProperties = $state(false);
  let settings = $state(null); // AppSettings snapshot for the Properties dialog
  let propsBusy = $state(false);
  let newestTaskId = $state(null); // transient: force this task to top of list
  let focusIndex = $state(0);
  let editingId = $state(null);
  let contextMenu = $state(null); // { items, x, y }
  let detailTask = $state(null); // task object for detail panel
  let showSearch = $state(false);
  let movePickerTask = $state(null); // task to move via Ctrl+M picker
  let datePickerTask = $state(null); // task whose due date is being picked (#37)
  let themePref = $state(getThemePref()); // "dark" | "light" | "system" (#46)
  let renamingListId = $state(null); // triggers inline rename in sidebar
  let collapsed = $state(new Set());
  let completingIds = $state(new Set());
  let showClearConfirm = $state(false);
  let bulkAdd = $state(null); // { text } when the bulk-add dialog is open
  let selectedIds = $state(new Set()); // multi-select for bulk operations
  let bulkMovePicker = $state(false); // bulk "move to list" picker open

  // --- Safe invoke ---
  let errorToast = $state(null);
  let infoToast = $state(null);

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

  // Refetch only the given list(s) and splice their tasks back into allTasks,
  // preserving the same grouped order loadAll() produces. This replaces the old
  // "reload every task from every list after every mutation" (O(n·lists)) with
  // O(tasks in the affected list(s)) — see #40.
  async function refreshLists(listIds) {
    const ids = new Set(listIds.filter(Boolean));
    if (ids.size === 0) return;
    const fetched = new Map();
    await Promise.all([...ids].map(async (id) => {
      const t = (await cmd("list_tasks", { listId: id })) || [];
      const title = lists.find(l => l.id === id)?.title;
      fetched.set(id, t.map(task => ({ ...task, listTitle: title, listId: id })));
    }));
    const next = [];
    for (const list of lists) {
      next.push(...(fetched.get(list.id) ?? allTasks.filter(t => t.listId === list.id)));
    }
    allTasks = next;
  }

  // The list a task currently belongs to (captured before a mutation).
  function taskListId(id) { return allTasks.find(t => t.id === id)?.listId; }

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

  // Reflect background syncs, not just manual "Sync now": the backend emits a
  // `sync-updated` event after every run. Surface failures and refresh data so
  // pulled/pushed changes appear without the user doing anything.
  $effect(() => {
    let unlisten;
    listen("sync-updated", (e) => {
      const s = e.payload || {};
      if (s.last_error) {
        syncStatus = "error";
        // The loop retries periodically; only toast a new/changed error so a
        // persistent failure (e.g. offline) doesn't spam every 60s.
        if (s.last_error !== lastSyncError) {
          lastSyncError = s.last_error;
          errorToast = { message: `Sync failed: ${s.last_error}`, timer: setTimeout(() => (errorToast = null), 6000) };
        }
      } else {
        lastSyncError = null;
        syncStatus = "idle";
        if (s.last_synced) lastSynced = new Date(s.last_synced);
        // A conflict kept the user's edit as a "(conflicted copy)" — explain the
        // duplicate that just appeared, so it isn't a mystery.
        if (s.last_conflicts > 0) {
          const n = s.last_conflicts;
          infoToast = { message: `${n} sync conflict${n > 1 ? "s" : ""} — your version was kept as a "(conflicted copy)".`, timer: setTimeout(() => (infoToast = null), 8000) };
        }
      }
      // Don't reload while the user is typing a new/renamed task inline — a
      // reload unmounts the editor (and its id may have been remapped by the
      // push), losing the edit. The pending edit's own refresh will catch up.
      if (editingId == null) loadAll();
    }).then((fn) => { unlisten = fn; });
    return () => { if (unlisten) unlisten(); };
  });

  // Pause background pushes while the user is actively editing (inline editor
  // or detail panel open), so a create's id remap can't invalidate the id being
  // edited (RC3). Pull keeps running server-side.
  let editingActive = $derived(editingId != null || detailTask != null);
  $effect(() => {
    invoke("set_editing", { editing: editingActive }).catch(() => {});
  });

  // --- Window geometry persistence ---
  // NOTE: programmatically restoring the saved window geometry via
  // setSize/setPosition is intentionally disabled. On WebKitGTK (Linux) driving
  // the webview through a size/position change at startup wedges its IPC/repaint
  // path on some GPU/compositor setups. Leaving the window at its builder size
  // avoids that. Kept as a stub so callers/imports stay valid.
  function restoreWindowGeometry() {
    /* disabled — see note above */
  }

  function saveWindowGeometry() {
    Promise.all([
      getCurrentWindow().outerSize(),
      getCurrentWindow().outerPosition(),
    ]).then(([size, pos]) => {
      localStorage.setItem(storageKey("windowGeometry"), JSON.stringify({
        width: size.width, height: size.height, x: pos.x, y: pos.y,
      }));
    }).catch(() => {});
  }

  // Restore view from localStorage
  $effect(() => {
    const saved = localStorage.getItem(storageKey("view"));
    if (saved) selectedView = saved;
  });
  $effect(() => {
    if (selectedView) localStorage.setItem(storageKey("view"), selectedView);
    try { 
      const titles = { focus: "Focus", upcoming: "Upcoming", missed: "Missed", unscheduled: "Unscheduled", all: "All Tasks" };
      const title = titles[selectedView] || lists.find(l => l.id === selectedView)?.title || "axiotask";
      getCurrentWindow().setTitle(`${title} — axiotask`);
    } catch {}
  });

  // --- Derived views ---
  // --- Preferences ---
  let excludedLists = $state(JSON.parse(localStorage.getItem(storageKey("excludedLists")) || "[]"));
  $effect(() => { localStorage.setItem(storageKey("excludedLists"), JSON.stringify(excludedLists)); });
  $effect(() => { localStorage.setItem(storageKey("showCompleted"), String(showCompleted)); });

  // Custom sidebar order for lists. Google Tasks has no list-ordering concept,
  // so this is a local preference (a saved array of list ids). Lists not in the
  // saved order — e.g. freshly created or pulled — keep their backend order and
  // appear after the ordered ones.
  let listOrder = $state(JSON.parse(localStorage.getItem(storageKey("listOrder")) || "[]"));
  $effect(() => { localStorage.setItem(storageKey("listOrder"), JSON.stringify(listOrder)); });

  function sortListsByOrder(items, order) {
    if (!order.length) return items;
    const pos = new Map(order.map((id, i) => [id, i]));
    // JS Array.sort is stable, so unknown lists (rank Infinity) keep their
    // existing relative order at the end.
    return [...items].sort(
      (a, b) => (pos.get(a.id) ?? Infinity) - (pos.get(b.id) ?? Infinity),
    );
  }

  // Lists in the user's custom sidebar order.
  let orderedLists = $derived(sortListsByOrder(lists, listOrder));

  // Persist a new full ordering emitted by the sidebar after a drag.
  function reorderLists(orderedIds) {
    listOrder = orderedIds;
  }

  function isExcluded(listId) { return excludedLists.includes(listId); }
  function toggleExclude(listId) {
    if (isExcluded(listId)) excludedLists = excludedLists.filter(id => id !== listId);
    else excludedLists = [...excludedLists, listId];
  }

  // --- Smart view filters ---
  function smartTasks() {
    return allTasks.filter(t => !isExcluded(t.listId) && (showCompleted || t.status !== "completed"));
  }

  function parseLocalDate(due) {
    const [y, m, d] = due.slice(0, 10).split("-").map(Number);
    return new Date(y, m - 1, d);
  }

  // Direct + nested children of a task (flat model, linked by parent_id).
  function descendantsOf(id) {
    const out = [];
    let frontier = allTasks.filter(t => t.parent_id === id);
    while (frontier.length) {
      out.push(...frontier);
      frontier = frontier.flatMap(t => allTasks.filter(c => c.parent_id === t.id));
    }
    return out;
  }

  // Per-task date predicates for the smart views.
  function inFocus(t) {
    if (!t.due) return false;
    const now = new Date(); now.setHours(0,0,0,0);
    return parseLocalDate(t.due) < new Date(now.getTime() + 7 * 86400000);
  }
  function inUpcoming(t) {
    if (!t.due) return false;
    const now = new Date(); now.setHours(0,0,0,0);
    const d = parseLocalDate(t.due);
    return d > now && d <= new Date(now.getTime() + 14 * 86400000);
  }
  function inMissed(t) {
    if (!t.due) return false;
    const now = new Date(); now.setHours(0,0,0,0);
    return parseLocalDate(t.due) < now;
  }

  // Smart views operate on TOP-LEVEL tasks only (subtasks appear in the detail
  // panel, never as standalone rows). A parent is included when it — or any of
  // its subtasks — matches, so a subtask due soon pulls its whole group in and
  // is never orphaned; the count then always equals the visible cards (#3 / A).
  function topLevelWhere(matchFn) {
    const visible = smartTasks();
    const visibleIds = new Set(visible.map(t => t.id));
    return visible.filter(t => !t.parent_id
      && (matchFn(t) || descendantsOf(t.id).some(d => visibleIds.has(d.id) && matchFn(d))));
  }

  function focusTasks() { return topLevelWhere(inFocus); }
  function upcomingTasks() { return topLevelWhere(inUpcoming); }
  function missedTasks() {
    // Sort by the earliest overdue date among the task and its matching subtasks.
    const earliest = (t) => Math.min(
      ...[t, ...descendantsOf(t.id)].filter(inMissed).map(x => parseLocalDate(x.due).getTime()),
    );
    return topLevelWhere(inMissed).sort((a, b) => earliest(a) - earliest(b));
  }
  function unscheduledTasks() {
    // A task is "unscheduled" when it itself has no due date.
    return smartTasks().filter(t => !t.parent_id && !t.due);
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
    // Newest task always at top (transient, regardless of sort)
    if (newestTaskId) {
      const idx = sorted.findIndex(t => t.id === newestTaskId);
      if (idx > 0) {
        const [task] = sorted.splice(idx, 1);
        sorted.unshift(task);
      }
    }
    return sorted;
  }

  // Restore sort mode per view
  $effect(() => {
    const saved = localStorage.getItem(storageKey(`sort:${selectedView}`));
    sortMode = saved || "manual";
    newestTaskId = null; // clear pinned new-task on view switch
  });
  // Persist sort mode
  $effect(() => {
    if (selectedView) localStorage.setItem(storageKey(`sort:${selectedView}`), sortMode);
  });

  let flatTasks = $derived(buildFlatTree(applySortAndOrder(visibleTasks())));

  // Counts for sidebar badges
  let viewCounts = $derived.by(() => {
    const open = t => t.status !== "completed";
    const c = {};
    // All counts are of TOP-LEVEL tasks, matching what the list actually shows
    // (subtasks live in the detail panel), so a badge never disagrees with its
    // visible cards.
    c.focus = focusTasks().filter(open).length;
    c.upcoming = upcomingTasks().filter(open).length;
    c.missed = missedTasks().filter(open).length;
    c.unscheduled = unscheduledTasks().filter(open).length;
    c.all = allTasks.filter(t => !t.parent_id && open(t)).length;
    for (const list of lists) {
      c[list.id] = allTasks.filter(t => t.listId === list.id && !t.parent_id && open(t)).length;
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
  async function newTask() {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all"].includes(selectedView);
    const targetList = isSmartView ? lists[0]?.id : selectedView;
    if (!targetList) return;
    const task = await cmd("create_task", { listId: targetList, parentId: null, title: "" });
    if (task) {
      newestTaskId = task.id;
      if (isSmartView) selectedView = targetList;
      await refreshLists([targetList]);
      focusIndex = 0;
      editingId = task.id;
    }
  }

  async function createTask(title, listId) {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all"].includes(selectedView);
    const resolvedListId = isSmartView ? null : listId;
    const targetList = resolvedListId || (!isSmartView ? selectedView : lists[0]?.id);
    if (!targetList || !title.trim()) return;
    const task = await cmd("create_task", { listId: targetList, parentId: null, title: title.trim() });
    if (task) {
      newestTaskId = task.id;
      selectedView = targetList;
      await refreshLists([targetList]);
      focusIndex = 0;
      editingId = task.id;
    }
  }

  async function addSubtask(parentId) {
    const parent = allTasks.find(t => t.id === parentId);
    if (!parent) return;
    const task = await cmd("create_task", { listId: parent.listId, parentId, title: "" });
    if (task) {
      await refreshLists([parent.listId]);
      // Open the new subtask in detail panel so user can name it immediately
      detailTask = allTasks.find(t => t.id === task.id) || task;
    }
  }

  async function toggleComplete(id) {
    const task = allTasks.find(t => t.id === id);
    const wasOpen = task?.status === "needsAction";
    await cmd("toggle_complete", { id });
    if (wasOpen && !task?.parent_id) {
      // Animate only top-level tasks in the list
      completingIds = new Set([...completingIds, id]);
      setTimeout(async () => {
        completingIds = new Set([...completingIds].filter(x => x !== id));
        await refreshLists([task.listId]);
        undoItem = { id, title: task.title, listId: task.listId, isComplete: true, timer: setTimeout(() => { undoItem = null; }, 10000) };
      }, 300);
    } else {
      await refreshLists([task.listId]);
    }
  }

  async function deleteTask(id) {
    const task = allTasks.find(t => t.id === id);
    if (!task) return;
    const token = await cmd("delete_task", { id });
    undoItem = { id, title: task.title, listId: task.listId, deleteToken: token, timer: setTimeout(() => { undoItem = null; }, 30000) };
    await refreshLists([task.listId]);
    focusIndex = Math.min(focusIndex, Math.max(0, flatTasks.length - 1));
  }

  async function renameTask(id, title) {
    editingId = null;
    if (!title.trim()) { await deleteTask(id); return; }
    const listId = taskListId(id);
    await cmd("rename_task", { id, title: title.trim() });
    await refreshLists([listId]);
  }

  async function setDue(id, mv) {
    const listId = taskListId(id);
    await cmd("set_due", { id, mv });
    await refreshLists([listId]);
  }

  // #37: open the calendar popover for a task, and apply the chosen date.
  function openDatePicker(id) {
    datePickerTask = allTasks.find(t => t.id === id) || null;
  }
  function handleDatePick(dateStr) {
    const id = datePickerTask?.id;
    datePickerTask = null;
    if (id) setDue(id, dateStr ? "raw:" + dateStr : "Clear");
  }

  // #46: one-click light/dark toggle, and explicit selection from Properties.
  function toggleTheme() {
    const next = document.documentElement.dataset.theme === "light" ? "dark" : "light";
    themePref = next; setThemePref(next);
  }
  function selectTheme(pref) {
    themePref = pref; setThemePref(pref);
  }

  async function moveTask(id, parentId) {
    const listId = taskListId(id);
    await cmd("move_task", { id, parentId, previousId: null });
    await refreshLists([listId]);
  }

  async function reorderTask(id, direction) {
    const listId = taskListId(id);
    await cmd("reorder_task", { id, direction });
    await refreshLists([listId]);
  }

  async function handleDragReorder(id, direction, steps = 1) {
    const listId = taskListId(id);
    for (let i = 0; i < steps; i++) {
      await cmd("reorder_task", { id, direction });
    }
    await refreshLists([listId]);
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
    const lid = undoItem.listId;
    undoItem = null;
    await refreshLists([lid]);
  }

  async function openNotes(id) {
    notesTask = allTasks.find(t => t.id === id) || null;
  }

  async function saveNotes(id, notes) {
    const listId = taskListId(id);
    await cmd("set_notes", { id, notes });
    await refreshLists([listId]);
  }

  async function doSync() {
    syncStatus = "syncing";
    const r = await cmd("sync_now");
    if (r !== null) { lastSynced = new Date(); syncStatus = "idle"; await loadAll(); }
    else { syncStatus = "error"; error = "Sync failed"; }
  }

  async function doFreshSync() {
    if (!confirm("Drop all local data and re-download from Google?")) return;
    syncStatus = "syncing";
    const r = await cmd("fresh_sync");
    if (r !== null) { lastSynced = new Date(); syncStatus = "idle"; await loadAll(); }
    else { syncStatus = "error"; error = "Fresh sync failed"; }
  }

  // Export a complete, human-readable JSON backup of every list and task.
  async function doExport() {
    const r = await cmd("export_backup");
    if (r !== null) {
      const msg = `Backed up ${r.tasks} task${r.tasks === 1 ? "" : "s"} in ${r.lists} list${r.lists === 1 ? "" : "s"} → ${r.path}`;
      if (infoToast) clearTimeout(infoToast.timer);
      infoToast = { message: msg, timer: setTimeout(() => { infoToast = null; }, 6000) };
    }
  }

  // Restore the most recent JSON backup (inverse of doExport). Non-destructive:
  // it adds or refreshes rows but never deletes. Reloads the view on success.
  async function doImport() {
    const r = await cmd("import_backup");
    if (r !== null) {
      await loadAll();
      const msg = `Restored ${r.tasks} task${r.tasks === 1 ? "" : "s"} in ${r.lists} list${r.lists === 1 ? "" : "s"} ← ${r.path}`;
      if (infoToast) clearTimeout(infoToast.timer);
      infoToast = { message: msg, timer: setTimeout(() => { infoToast = null; }, 6000) };
    }
  }

  async function login() {
    syncStatus = "syncing"; // show loading state
    const result = await cmd("auth_login");
    if (result !== null) {
      authenticated = true;
      await doSync();
    } else {
      syncStatus = "idle";
    }
  }

  async function logout() {
    await cmd("auth_logout");
    authenticated = false;
    syncStatus = "idle";
    lastSynced = null;
    if (showProperties) await refreshSettings();
  }

  // --- Properties dialog ---
  async function refreshSettings() {
    const s = await cmd("get_settings");
    if (s !== null) settings = s;
  }

  async function openProperties() {
    await refreshSettings();
    if (settings) showProperties = true;
  }

  async function setPushEnabled(enabled) {
    propsBusy = true;
    const s = await cmd("set_push_enabled", { enabled });
    if (s !== null) settings = s;
    propsBusy = false;
  }

  async function setAutoSync(enabled) {
    propsBusy = true;
    const s = await cmd("set_auto_sync", { enabled });
    if (s !== null) settings = s;
    propsBusy = false;
  }

  // Sync from within the dialog, then refresh its stats.
  async function syncFromProperties() {
    propsBusy = true;
    await doSync();
    await refreshSettings();
    propsBusy = false;
  }

  async function freshSyncFromProperties() {
    propsBusy = true;
    await doFreshSync();
    await refreshSettings();
    propsBusy = false;
  }

  // Sign in from the dialog, then refresh so the Account tab updates.
  async function loginFromProperties() {
    await login();
    await refreshSettings();
  }

  async function createList(title, localOnly = false) {
    if (!title?.trim()) return;
    await cmd("create_list", { title: title.trim(), localOnly });
    await loadAll();
  }

  async function renameList(id, title) {
    renamingListId = null;
    if (!title?.trim()) return;
    await cmd("rename_list", { id, title: title.trim() });
    await loadAll();
  }

  async function moveToList(taskId, targetListId) {
    const task = allTasks.find(t => t.id === taskId);
    const targetList = lists.find(l => l.id === targetListId);
    await cmd("move_to_list", { id: taskId, targetListId });
    await refreshLists([task?.listId, targetListId]);
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
    await refreshLists([listId]);
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
    const listId = taskListId(id);
    if (title !== undefined) await cmd("rename_task", { id, title });
    if (notes !== undefined) await cmd("set_notes", { id, notes });
    if (due !== undefined) {
      if (due) await cmd("set_due", { id, mv: "raw:" + due });
      else await cmd("set_due", { id, mv: "Clear" });
    }
    await refreshLists([listId]);
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
          { label: "Pick a date…", action: () => openDatePicker(task.id) },
          { label: "Clear", action: () => setDue(task.id, "Clear") },
        ]},
        { id: "move", icon: "↗️", label: "Move to list", submenu: lists.map(l => ({
          label: l.title, action: () => moveToList(task.id, l.id)
        }))},
        "separator",
        { id: "subtask", icon: "⬆️", label: "Add subtask", action: async () => {
          const t = await cmd("create_task", { listId: task.listId, parentId: task.id, title: "" });
          if (t) { await refreshLists([task.listId]); editingId = t.id; }
        }},
        { id: "duplicate", icon: "📋", label: "Duplicate", shortcut: "Ctrl+D", action: async () => {
          await cmd("create_task", { listId: task.listId, parentId: task.parent_id, title: task.title + " (copy)" });
          await refreshLists([task.listId]);
        }},
        { id: "details", icon: "ℹ️", label: "Details", shortcut: "Enter", action: () => {
          detailTask = allTasks.find(t => t.id === task.id) || task;
        }},
        ...(task.web_view_link ? [{
          id: "open-google", icon: "↗", label: "Open in Google Tasks",
          action: () => cmd("open_url", { url: task.web_view_link }),
        }] : []),
        "separator",
        { id: "delete", icon: "🗑️", label: "Delete", shortcut: "d", action: () => deleteTask(task.id) },
      ]
    };
  }

  // Ctrl+V paste to create. A single line creates one task immediately; pasting
  // multiple lines opens the bulk-add dialog so the user picks how to split it.
  async function handlePaste(e) {
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
    const text = e.clipboardData?.getData("text/plain")?.trim();
    if (!text) return;
    e.preventDefault();

    const targetList = bulkTargetList();
    if (!targetList) return;

    const lines = text.split("\n").map(l => l.trim()).filter(l => l.length > 0);
    if (lines.length > 1) {
      bulkAdd = { text };
      return;
    }
    // Single line → one task, no dialog.
    await cmd("create_task", { listId: targetList, parentId: null, title: lines[0] });
    await refreshLists([targetList]);
    selectedView = targetList;
  }

  // List a fresh bulk insert should target: the current list, or the first list
  // when a smart view is active.
  function bulkTargetList() {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all"].includes(selectedView);
    return !isSmartView ? selectedView : (orderedLists[0]?.id ?? null);
  }

  // Create many tasks at once from the bulk-add dialog.
  async function bulkCreate({ text, mode, listId }) {
    let created = 0;
    if (mode === "titleNotes") {
      const all = text.split("\n");
      const title = (all[0] || "").trim();
      const notes = all.slice(1).join("\n").trim();
      if (title) {
        const task = await cmd("create_task", { listId, parentId: null, title });
        if (task && notes) await cmd("set_notes", { id: task.id, notes });
        created = 1;
      }
    } else {
      const lines = text.split("\n").map(l => l.trim()).filter(l => l.length > 0);
      for (const line of lines) {
        await cmd("create_task", { listId, parentId: null, title: line });
        created++;
      }
    }
    bulkAdd = null;
    await refreshLists([listId]);
    selectedView = listId;
    if (created > 0) {
      if (infoToast) clearTimeout(infoToast.timer);
      const msg = `Added ${created} task${created === 1 ? "" : "s"}`;
      infoToast = { message: msg, timer: setTimeout(() => { infoToast = null; }, 5000) };
    }
  }

  // --- Multi-select bulk operations ---
  function toggleSelect(id) {
    const next = new Set(selectedIds);
    if (next.has(id)) next.delete(id); else next.add(id);
    selectedIds = next;
  }
  function clearSelection() { selectedIds = new Set(); }

  function bulkToast(n, verb) {
    if (n <= 0) return;
    if (infoToast) clearTimeout(infoToast.timer);
    infoToast = { message: `${n} task${n === 1 ? "" : "s"} ${verb}`, timer: setTimeout(() => { infoToast = null; }, 4000) };
  }

  async function bulkComplete() {
    const ids = [...selectedIds];
    const listIds = ids.map(taskListId);
    for (const id of ids) {
      const t = allTasks.find(x => x.id === id);
      if (t && t.status !== "completed") await cmd("toggle_complete", { id });
    }
    clearSelection(); await refreshLists(listIds); bulkToast(ids.length, "completed");
  }
  async function bulkDelete() {
    const ids = [...selectedIds];
    const listIds = ids.map(taskListId);
    for (const id of ids) await cmd("delete_task", { id });
    clearSelection(); await refreshLists(listIds); bulkToast(ids.length, "deleted");
  }
  async function bulkSetDue(mv) {
    const ids = [...selectedIds];
    const listIds = ids.map(taskListId);
    for (const id of ids) await cmd("set_due", { id, mv });
    clearSelection(); await refreshLists(listIds);
    bulkToast(ids.length, mv === "Clear" ? "cleared" : "rescheduled");
  }
  async function bulkMove(listId) {
    const ids = [...selectedIds];
    const srcLists = ids.map(taskListId);
    for (const id of ids) await cmd("move_to_list", { id, targetListId: listId });
    bulkMovePicker = false; clearSelection(); await refreshLists([...srcLists, listId]); bulkToast(ids.length, "moved");
  }

  // List context menu
  function openListContextMenu(list, x, y) {
    const isExcl = excludedLists.includes(list.id);
    contextMenu = {
      x, y,
      items: [
        { id: "rename", icon: "✏️", label: "Rename", action: async () => {
          renamingListId = list.id;
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

  function viewTitle() {
    switch (selectedView) {
      case "focus": return "Focus";
      case "upcoming": return "Upcoming";
      case "missed": return "Missed";
      case "unscheduled": return "Unscheduled";
      case "all": return "All Tasks";
      default: return lists.find(l => l.id === selectedView)?.title || "";
    }
  }

  function quickAddTargetName() {
    const isSmartView = ["focus", "upcoming", "missed", "unscheduled", "all", "today"].includes(selectedView);
    if (!isSmartView) return lists.find(l => l.id === selectedView)?.title || null;
    return lists[0]?.title || null;
  }

  async function handleKeydown(e) {
    if (showCheatsheet) { showCheatsheet = false; e.preventDefault(); return; }
    if (showProperties) {
      // Esc closes; all other keys are handled within the dialog (its buttons
      // and checkboxes keep their default behavior) and must not reach the
      // task view underneath.
      if (e.key === "Escape") { showProperties = false; e.preventDefault(); }
      return;
    }
    if (showClearConfirm) { showClearConfirm = false; e.preventDefault(); return; }
    if (bulkAdd) {
      // The dialog (a textarea) handles its own keys; Esc closes it. Don't let
      // task shortcuts fire underneath.
      if (e.key === "Escape") { bulkAdd = null; e.preventDefault(); }
      return;
    }
    if (editingId || e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
    if (movePickerTask && e.key === "Escape") { movePickerTask = null; e.preventDefault(); return; }
    if (notesTask && e.key === "Escape") { notesTask = null; e.preventDefault(); return; }
    if (detailTask && e.key === "Escape") { detailTask = null; e.preventDefault(); return; }
    if (notesTask || detailTask) return;
    // With an active selection, Esc clears it (when no panel intercepted above).
    if (selectedIds.size > 0 && e.key === "Escape") { clearSelection(); e.preventDefault(); return; }

    const f = focused();
    const len = flatTasks.length;

    switch (e.key) {
      case "?": e.preventDefault(); showCheatsheet = true; break;
      case ",": e.preventDefault(); await openProperties(); break;
      case "/": e.preventDefault(); showSearch = true; break;
      case "x": case "X": e.preventDefault(); if (f) toggleSelect(f.id); break;
      case "e": case "E":
        e.preventDefault(); if (f) editingId = f.id;
        break;
      case "m":
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          if (selectedIds.size > 0) bulkMovePicker = true;
          else if (f) movePickerTask = f;
        } else {
          e.preventDefault();
          if (selectedIds.size > 0) await bulkSetDue("NextMonth");
          else if (f) await setDue(f.id, "NextMonth");
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
      case " ": e.preventDefault(); if (selectedIds.size > 0) await bulkComplete(); else if (f) await toggleComplete(f.id); break;
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
        if (f) {
          // Toggle detail panel
          detailTask = (detailTask?.id === f.id) ? null : f;
        } else {
          await newTask();
        }
        break;
      case "n": e.preventDefault(); await newTask(); break;
      case "s": e.preventDefault(); if (f) await addSubtask(f.id); break;
      case "d": e.preventDefault(); if (selectedIds.size > 0) await bulkDelete(); else if (f) await deleteTask(f.id); break;
      case "o": e.preventDefault(); if (selectedIds.size > 0) await bulkSetDue("Today"); else if (f) await setDue(f.id, "Today"); break;
      case "t": e.preventDefault(); if (selectedIds.size > 0) await bulkSetDue("Tomorrow"); else if (f) await setDue(f.id, "Tomorrow"); break;
      case "w": e.preventDefault(); if (selectedIds.size > 0) await bulkSetDue("NextWeek"); else if (f) await setDue(f.id, "NextWeek"); break;
      case "r": e.preventDefault(); if (selectedIds.size > 0) await bulkSetDue("Clear"); else if (f) await setDue(f.id, "Clear"); break;
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
    lists={orderedLists}
    {selectedView}
    onselect={(v) => { selectedView = v; focusIndex = 0; detailTask = null; clearSelection(); }}
    onlogin={login}
    onlogout={logout}
    onsync={doSync}
    onfreshsync={doFreshSync}
    oncreateList={createList}
    onrenameList={renameList}
    onlistaction={openListContextMenu}
    onreorderlists={reorderLists}
    onproperties={openProperties}
    ontoggletheme={toggleTheme}
    theme={themePref}
    {authenticated}
    {syncStatus}
    {lastSynced}
    {renamingListId}
    {excludedLists}
    counts={viewCounts}
  />
  <section class="content">
    <div class="toolbar">
      <span class="view-title">{viewTitle()}</span>
      <button class="new-task-btn" onclick={newTask}>+ New task</button>
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
    {#if selectedIds.size > 0}
      <div class="bulk-bar" role="toolbar" aria-label="Bulk actions">
        <span class="bulk-count">{selectedIds.size} selected</span>
        <button onclick={bulkComplete}>✓ Complete</button>
        <button onclick={() => bulkSetDue("Today")}>Today</button>
        <button onclick={() => bulkSetDue("Tomorrow")}>Tomorrow</button>
        <button onclick={() => bulkSetDue("NextWeek")}>Next week</button>
        <button onclick={() => bulkSetDue("Clear")}>Clear date</button>
        <button onclick={() => bulkMovePicker = true}>↗ Move</button>
        <button class="bulk-delete" onclick={bulkDelete}>🗑 Delete</button>
        <button class="bulk-clear" onclick={clearSelection} title="Clear selection (Esc)">✕</button>
      </div>
    {/if}
    {#if loading}
      <p class="status">Loading...</p>
    {:else if error}
      <p class="status error">{error}</p>
    {:else if selectedView === "focus"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} onpickdate={openDatePicker} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {selectedIds} onselect={toggleSelect} {getSubtaskProgress} {showCompleted} viewType="focus" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "upcoming"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} onpickdate={openDatePicker} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {selectedIds} onselect={toggleSelect} {getSubtaskProgress} {showCompleted} viewType="upcoming" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "missed"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} onpickdate={openDatePicker} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {selectedIds} onselect={toggleSelect} {getSubtaskProgress} {showCompleted} viewType="missed" {sortMode} onreorder={handleDragReorder} />
    {:else if selectedView === "unscheduled"}
      <TodayView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} onpickdate={openDatePicker} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {selectedIds} onselect={toggleSelect} {getSubtaskProgress} {showCompleted} viewType="unscheduled" {sortMode} onreorder={handleDragReorder} />
    {:else}
      <ListView tasks={flatTasks} {focusIndex} {editingId} {completingIds} onrename={renameTask} oncanceledit={() => editingId = null} onfocus={handleFocus} ontoggle={toggleComplete} onsetdue={setDue} onpickdate={openDatePicker} oncontextmenu={openTaskContextMenu} onaddsubtask={addSubtask} {selectedIds} onselect={toggleSelect} {getSubtaskProgress} isCrossList={selectedView === "all"} {sortMode} onreorder={handleDragReorder} />
    {/if}
  </section>
  {#if detailTask}
    <TaskDetail
      task={detailTask}
      parentTask={detailTask.parent_id ? allTasks.find(t => t.id === detailTask.parent_id) : null}
      {lists}
      subtasks={allTasks.filter(t => t.parent_id === detailTask.id)}
      onsave={saveDetail}
      onclose={() => detailTask = null}
      ondelete={deleteTask}
      onmovelist={moveToList}
      ontogglesubtask={toggleComplete}
      onopensubtask={(sub) => detailTask = sub}
      onopenparent={(p) => detailTask = p}
      onaddsubtask={addSubtask}
      onprev={(() => { const siblings = detailTask.parent_id ? allTasks.filter(t => t.parent_id === detailTask.parent_id) : flatTasks; const i = siblings.findIndex(t => t.id === detailTask.id); return i > 0 ? () => { detailTask = siblings[i-1]; } : null; })()}
      onnext={(() => { const siblings = detailTask.parent_id ? allTasks.filter(t => t.parent_id === detailTask.parent_id) : flatTasks; const i = siblings.findIndex(t => t.id === detailTask.id); return i < siblings.length - 1 ? () => { detailTask = siblings[i+1]; } : null; })()}
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
{#if infoToast}
  <Toast message={infoToast.message} ondismiss={() => { clearTimeout(infoToast.timer); infoToast = null; }} />
{/if}
{#if showCheatsheet}
  <Cheatsheet onclose={() => showCheatsheet = false} />
{/if}
{#if showProperties && settings}
  <Properties
    {settings}
    busy={propsBusy}
    onclose={() => showProperties = false}
    onsetpush={setPushEnabled}
    onsetautosync={setAutoSync}
    onlogin={loginFromProperties}
    onlogout={logout}
    onsync={syncFromProperties}
    onfreshsync={freshSyncFromProperties}
    onexport={doExport}
    onimport={doImport}
    theme={themePref}
    onsettheme={selectTheme}
  />
{/if}
{#if bulkAdd}
  <BulkAdd
    initialText={bulkAdd.text}
    lists={orderedLists}
    defaultListId={bulkTargetList()}
    onsubmit={bulkCreate}
    onclose={() => bulkAdd = null}
  />
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
{#if bulkMovePicker}
  <MoveToListPicker {lists} currentListId={null} onselect={(list) => bulkMove(list.id)} onclose={() => bulkMovePicker = false} />
{/if}
{#if datePickerTask}
  <DatePicker value={datePickerTask.due} onselect={handleDatePick} onclose={() => datePickerTask = null} />
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
  :global(body) { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--fg); -webkit-tap-highlight-color: transparent; }
  :global(*, *::before, *::after) { box-sizing: border-box; }
  .app { display: flex; height: 100vh; height: 100dvh; }
  .content { flex: 1; display: flex; flex-direction: column; overflow: hidden; min-width: 0; min-height: 0; }
  .toolbar { padding: 0.4rem 1rem; display: flex; align-items: center; border-bottom: 1px solid var(--bg-elevated); gap: 0.5rem; flex-wrap: wrap; }
  .new-task-btn { background: none; border: 1px solid var(--border); color: var(--accent); padding: 0.2rem 0.6rem; border-radius: 4px; font-size: 0.8rem; cursor: pointer; }
  .new-task-btn:hover { background: var(--bg-hover); }
  .view-title { font-size: 0.9rem; font-weight: 600; color: var(--fg); margin-right: auto; }
  .toggle { font-size: 0.8rem; color: var(--fg-muted); cursor: pointer; display: flex; align-items: center; gap: 0.4rem; }
  .toggle input { cursor: pointer; width: 1rem; height: 1rem; }
  .clear-btn { background: none; border: 1px solid var(--border-faint); color: var(--fg-muted); padding: 0.2rem 0.5rem; border-radius: 3px; font-size: 0.75rem; cursor: pointer; margin-left: auto; }
  .clear-btn:hover { background: var(--bg-elevated); color: var(--danger); }
  .sort-notice { font-size: 0.7rem; color: var(--warning); margin-left: 0.5rem; }
  .bulk-bar {
    display: flex; align-items: center; gap: 0.4rem; flex-wrap: wrap;
    padding: 0.4rem 1rem; background: var(--bg-active); border-bottom: 1px solid var(--bg-active);
  }
  .bulk-count { font-size: 0.8rem; color: var(--accent); font-weight: 600; margin-right: 0.3rem; }
  .bulk-bar button {
    background: var(--bg-elevated); border: none; color: var(--fg-secondary); padding: 0.25rem 0.6rem;
    border-radius: 4px; cursor: pointer; font-size: 0.78rem; font-family: inherit;
  }
  .bulk-bar button:hover { background: var(--border-faint); }
  .bulk-bar .bulk-delete:hover { background: var(--bg-danger); color: var(--danger); }
  .bulk-bar .bulk-clear { margin-left: auto; background: none; color: var(--fg-muted); }
  .bulk-bar .bulk-clear:hover { color: var(--fg); background: none; }
  .status { color: var(--fg-muted); text-align: center; margin-top: 4rem; }
  .status.error { color: var(--danger); }

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
  .confirm-dialog { background: var(--bg-elevated); border: 1px solid var(--border-faint); border-radius: 8px; padding: 1.5rem; max-width: 360px; width: 90%; }
  .confirm-dialog p { margin: 0 0 1rem; color: var(--fg); }
  .confirm-actions { display: flex; gap: 0.5rem; justify-content: flex-end; }
  .confirm-cancel { background: none; border: 1px solid var(--border-faint); color: var(--fg-secondary); padding: 0.4rem 1rem; border-radius: 4px; cursor: pointer; }
  .confirm-cancel:hover { background: var(--border-faint); }
  .confirm-delete { background: var(--danger); border: none; color: var(--fg-strong); padding: 0.4rem 1rem; border-radius: 4px; cursor: pointer; }
  .confirm-delete:hover { background: var(--danger); }
</style>
