<script>
  import { FREQUENCIES, WEEKDAYS, defaultRule, summarize } from "./recurrence.js";

  let { rule = null, onchange } = $props();

  let freq = $state("");
  let interval = $state(1);
  let byday = $state([]);
  let endKind = $state("never");
  let endDate = $state("");
  let endCount = $state(1);

  let initializedFrom = $state(undefined);

  // Initialize local fields from the incoming rule (once per distinct rule).
  $effect(() => {
    const key = rule ? JSON.stringify(rule) : "null";
    if (initializedFrom === key) return;
    initializedFrom = key;
    if (rule) {
      freq = rule.freq;
      interval = rule.interval ?? 1;
      byday = [...(rule.byday ?? [])];
      endKind = rule.end?.kind ?? "never";
      endDate = rule.end?.kind === "onDate" ? rule.end.date : "";
      endCount = rule.end?.kind === "count" ? rule.end.count : 1;
    } else {
      freq = "";
      interval = 1;
      byday = [];
      endKind = "never";
      endDate = "";
      endCount = 1;
    }
  });

  const FREQ_LABELS = { DAILY: "Daily", WEEKLY: "Weekly", MONTHLY: "Monthly", YEARLY: "Yearly" };
  const FREQ_NOUN = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" };

  function buildRule() {
    if (!freq) return null;
    let end = { kind: "never" };
    if (endKind === "onDate" && endDate) end = { kind: "onDate", date: endDate };
    else if (endKind === "count") end = { kind: "count", count: Math.max(1, Number(endCount) || 1) };
    return {
      freq,
      interval: Math.max(1, Number(interval) || 1),
      byday: freq === "WEEKLY" ? [...byday] : [],
      end,
    };
  }

  function emit() {
    onchange?.(buildRule());
  }

  function onFreqChange(e) {
    freq = e.target.value;
    emit();
  }

  function onEndKindChange(e) {
    endKind = e.target.value;
    emit();
  }

  function toggleDay(token) {
    const selected = new Set(byday);
    if (selected.has(token)) selected.delete(token);
    else selected.add(token);
    byday = WEEKDAYS.map((w) => w.token).filter((t) => selected.has(t));
    emit();
  }

  let preview = $derived(buildRule() ? summarize(buildRule()) : "Does not repeat");
</script>

<div class="recurrence-editor" data-testid="recurrence-editor">
  <div class="field">
    <label for="rec-freq">Repeat</label>
    <select id="rec-freq" bind:value={freq} onchange={onFreqChange}>
      <option value="">Does not repeat</option>
      {#each FREQUENCIES as f}
        <option value={f}>{FREQ_LABELS[f]}</option>
      {/each}
    </select>
  </div>

  {#if freq}
    <div class="field inline">
      <label for="rec-interval">Every</label>
      <input
        id="rec-interval"
        type="number"
        min="1"
        bind:value={interval}
        oninput={emit}
        class="interval-input"
      />
      <span class="unit">{FREQ_NOUN[freq]}{Number(interval) === 1 ? "" : "s"}</span>
    </div>

    {#if freq === "WEEKLY"}
      <div class="field">
        <span class="field-label">On days</span>
        <div class="weekdays" role="group" aria-label="Weekdays">
          {#each WEEKDAYS as w}
            <button
              type="button"
              class="day-btn"
              class:active={byday.includes(w.token)}
              aria-pressed={byday.includes(w.token)}
              aria-label={w.short}
              onclick={() => toggleDay(w.token)}
            >{w.short.slice(0, 1)}</button>
          {/each}
        </div>
      </div>
    {/if}

    <div class="field">
      <label for="rec-end">Ends</label>
      <select id="rec-end" bind:value={endKind} onchange={onEndKindChange}>
        <option value="never">Never</option>
        <option value="onDate">On date</option>
        <option value="count">After N times</option>
      </select>
    </div>

    {#if endKind === "onDate"}
      <div class="field">
        <label for="rec-end-date">End date</label>
        <input id="rec-end-date" type="date" bind:value={endDate} onchange={(e) => { endDate = e.target.value; emit(); }} />
      </div>
    {/if}

    {#if endKind === "count"}
      <div class="field inline">
        <label for="rec-end-count">Occurrences</label>
        <input
          id="rec-end-count"
          type="number"
          min="1"
          bind:value={endCount}
          oninput={(e) => { endCount = e.target.value; emit(); }}
          class="interval-input"
        />
      </div>
    {/if}
  {/if}

  <div class="preview" data-testid="recurrence-preview">{preview}</div>
</div>

<style>
  .recurrence-editor { display: flex; flex-direction: column; gap: 0.6rem; }
  .field { display: flex; flex-direction: column; gap: 0.3rem; }
  .field.inline { flex-direction: row; align-items: center; gap: 0.4rem; }
  .field label, .field-label {
    font-size: 0.75rem; color: #666; text-transform: uppercase; letter-spacing: 0.03em;
  }
  .recurrence-editor select, .recurrence-editor input {
    background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 4px;
    color: #e0e0e0; padding: 0.4rem; font-size: 0.85rem; font-family: inherit; outline: none;
  }
  .recurrence-editor select:focus, .recurrence-editor input:focus { border-color: #0f3460; }
  .interval-input { width: 4rem; }
  .unit { font-size: 0.85rem; color: #aaa; }
  .weekdays { display: flex; gap: 0.25rem; flex-wrap: wrap; }
  .day-btn {
    width: 1.9rem; height: 1.9rem; border-radius: 50%; border: 1px solid #2a2a4a;
    background: #1a1a2e; color: #888; cursor: pointer; font-size: 0.8rem; padding: 0;
  }
  .day-btn:hover { border-color: #0f3460; color: #ccc; }
  .day-btn.active { background: #0f3460; color: #7ec8e3; border-color: #0f3460; }
  .preview { font-size: 0.78rem; color: #7ec8e3; font-style: italic; }

  @media (pointer: coarse) {
    .day-btn { width: 44px; height: 44px; }
    .recurrence-editor select, .recurrence-editor input { min-height: 44px; }
  }
</style>
