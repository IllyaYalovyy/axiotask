<script>
  // A small calendar popover for picking a specific due date (#37). Emits the
  // chosen date as a local "YYYY-MM-DD" string (or null when cleared); the caller
  // maps that to set_due(raw:…) / Clear. Keyboard-accessible.
  let { value = null, onselect, onclose } = $props();

  const WEEKDAYS = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
  const MONTHS = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"];

  const pad = (n) => String(n).padStart(2, "0");
  const toISO = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  function parse(s) {
    if (!s) return null;
    const [y, m, d] = s.slice(0, 10).split("-").map(Number);
    return y ? new Date(y, m - 1, d) : null;
  }

  const today = new Date(); today.setHours(0, 0, 0, 0);
  const initialSelected = () => parse(value);
  let selected = $derived(parse(value));

  let view = $state(new Date((initialSelected() ?? today).getFullYear(), (initialSelected() ?? today).getMonth(), 1));
  let focus = $state(new Date(initialSelected() ?? today));
  let picker = $state(null);
  $effect(() => { if (picker) picker.focus(); });

  // 6-week grid (Sunday-first) covering the view month.
  let grid = $derived.by(() => {
    const start = new Date(view.getFullYear(), view.getMonth(), 1);
    start.setDate(start.getDate() - start.getDay());
    return Array.from({ length: 42 }, (_, i) => {
      const d = new Date(start); d.setDate(start.getDate() + i); return d;
    });
  });

  const sameDay = (a, b) => a && b && a.getFullYear() === b.getFullYear()
    && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const inView = (d) => d.getMonth() === view.getMonth();

  const pick = (d) => onselect(toISO(d));
  const prevMonth = () => { view = new Date(view.getFullYear(), view.getMonth() - 1, 1); };
  const nextMonth = () => { view = new Date(view.getFullYear(), view.getMonth() + 1, 1); };

  function moveFocus(days) {
    const f = new Date(focus); f.setDate(f.getDate() + days); focus = f;
    if (f.getMonth() !== view.getMonth() || f.getFullYear() !== view.getFullYear()) {
      view = new Date(f.getFullYear(), f.getMonth(), 1);
    }
  }
  function handleKeydown(e) {
    switch (e.key) {
      case "Escape": e.preventDefault(); e.stopPropagation(); onclose(); break;
      case "ArrowLeft": e.preventDefault(); moveFocus(-1); break;
      case "ArrowRight": e.preventDefault(); moveFocus(1); break;
      case "ArrowUp": e.preventDefault(); moveFocus(-7); break;
      case "ArrowDown": e.preventDefault(); moveFocus(7); break;
      case "PageUp": e.preventDefault(); prevMonth(); break;
      case "PageDown": e.preventDefault(); nextMonth(); break;
      case "Enter": e.preventDefault(); pick(focus); break;
    }
  }
</script>

<div class="overlay" role="presentation" onclick={onclose}>
  <div
    class="datepicker"
    bind:this={picker}
    tabindex="-1"
    role="dialog"
    aria-label="Pick a date"
    onclick={(e) => e.stopPropagation()}
    onkeydown={handleKeydown}
  >
    <div class="dp-header">
      <button class="dp-nav" onclick={prevMonth} aria-label="Previous month">‹</button>
      <span class="dp-title">{MONTHS[view.getMonth()]} {view.getFullYear()}</span>
      <button class="dp-nav" onclick={nextMonth} aria-label="Next month">›</button>
    </div>
    <div class="dp-weekdays">
      {#each WEEKDAYS as w}<span class="dp-weekday">{w}</span>{/each}
    </div>
    <div class="dp-grid">
      {#each grid as d}
        <button
          class="dp-day"
          class:other={!inView(d)}
          class:today={sameDay(d, today)}
          class:selected={sameDay(d, selected)}
          class:focused={sameDay(d, focus)}
          aria-label={toISO(d)}
          onclick={() => pick(d)}
          onmouseenter={() => (focus = new Date(d))}
        >{d.getDate()}</button>
      {/each}
    </div>
    <div class="dp-footer">
      <button class="dp-action" onclick={() => onselect(toISO(today))}>Today</button>
      <button class="dp-action" onclick={() => onselect(null)}>Clear</button>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed; inset: 0; background: rgba(0, 0, 0, 0.5);
    display: flex; align-items: center; justify-content: center; z-index: 6000;
  }
  .datepicker {
    background: var(--bg-panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.75rem; width: 260px; outline: none; color: var(--fg);
  }
  .dp-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem; }
  .dp-title { font-size: 0.9rem; font-weight: 600; }
  .dp-nav {
    background: none; border: none; color: var(--fg-secondary); font-size: 1.1rem; cursor: pointer;
    padding: 0 0.4rem; border-radius: 4px;
  }
  .dp-nav:hover { background: var(--bg-active); color: var(--fg-strong); }
  .dp-weekdays, .dp-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 2px; }
  .dp-weekday { text-align: center; font-size: 0.65rem; color: var(--fg-muted); padding: 0.2rem 0; }
  .dp-day {
    background: none; border: none; color: var(--fg); cursor: pointer;
    padding: 0.35rem 0; border-radius: 4px; font-size: 0.8rem; font-family: inherit;
  }
  .dp-day:hover, .dp-day.focused { background: var(--bg-active); color: var(--fg-strong); }
  .dp-day.other { color: var(--fg-faint); }
  .dp-day.today { outline: 1px solid var(--accent); }
  .dp-day.selected { background: var(--accent-bg); color: var(--fg-strong); }
  .dp-footer { display: flex; gap: 0.5rem; margin-top: 0.5rem; }
  .dp-action {
    flex: 1; background: var(--bg-elevated); border: none; color: var(--fg-secondary); padding: 0.35rem;
    border-radius: 4px; cursor: pointer; font-size: 0.78rem; font-family: inherit;
  }
  .dp-action:hover { background: var(--bg-active); color: var(--accent); }
</style>
