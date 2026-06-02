# RFC-008: One-Keystroke Date Moves

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

A direct VISION ask: "Single click to move task to tomorrow, next week, next
month." Implement as one-keystroke bindings (`t`, `w`, `m`, `r`) plus a
hover-equivalent affordance for mouse users. Correct under DST, month-end,
and timezone edge cases.

---

## Goals

- **G1** — `t` sets `due` to tomorrow (local timezone).
- **G2** — `w` sets `due` to the same weekday next week.
- **G3** — `m` sets `due` to the same day-of-month next month, clamped to month-end.
- **G4** — `r` clears `due`.
- **G5** — Works on single selection from the tree; pluralizes naturally if multi-select arrives later.

## Non-Goals

- **NG1** — Time-of-day on due date (Google Tasks stores date only).
- **NG2** — Custom relative offsets ("in 3 days") — that's the command palette.
- **NG3** — Recurring tasks (post-MVP).

---

## Background & Motivation

Triage is the most frequent operation in a task system: "not today,
tomorrow" / "not this week, next." If it takes more than one key, it
doesn't happen.

---

## Considered Options

### Option A — Static "tomorrow / +7d / +1mo" calculation

**Pros**: Simple.
**Cons**: Month-end and DST need explicit handling.

### Option B — Calendar library doing it

**Pros**: Battle-tested.
**Cons**: Same edge cases; library can hide them.

---

## Decision

**Option A**, implemented with [`jiff`](https://crates.io/crates/jiff)
because its civil-date type is the right abstraction for due-date math
(timezone-aware where needed; otherwise pure civil dates).

---

## Design

```rust
pub enum DateMove { Tomorrow, NextWeek, NextMonth, Clear }

pub fn apply_date_move(today: jiff::civil::Date, mv: DateMove) -> Option<jiff::civil::Date> {
    match mv {
        DateMove::Tomorrow  => Some(today.tomorrow().unwrap()),
        DateMove::NextWeek  => Some(today.checked_add(7.days()).unwrap()),
        DateMove::NextMonth => Some(today.first_of_month().checked_add(1.month()).unwrap()
                                          .with().day(today.day().min(/*month-end of next*/)).build().unwrap()),
        DateMove::Clear     => None,
    }
}
```

`today` is computed in the user's local timezone. The function above is
pure; the IO ("get today", "patch task") sits outside it for trivial unit
testing.

### Tauri command

```rust
#[tauri::command] async fn set_due(id: String, mv: DateMove) -> Result<()>;
```

Local store update + dirty flag + sync trigger, same shape as RFC-006
commands.

### Mouse affordance

Each row has a hover-revealed "▾" chip showing `tomorrow / next week / next
month / clear`. Same backend.

---

## Testing Strategy

- **Pure function tests** — table-driven:
  - month-end: 2026-01-31 + 1mo → 2026-02-28 (clamped).
  - leap-year: 2028-01-31 + 1mo → 2028-02-29.
  - DST: any midnight-near boundary handled by working in civil dates, not zoned.
  - cross-year: 2026-12-30 + 1mo → 2027-01-30.
- **Idempotency** — pressing `t` twice on the same day yields the same date.
- **Integration** — UI test: focus task, press `t`, sync runs, Google receives correct ISO date.

---

## Development Plan

- [ ] **Step 1** — `apply_date_move` pure function + exhaustive table tests *(prerequisite: —)*
- [ ] **Step 2** — `set_due` Tauri command *(prerequisite: Step 1, RFC-006 Step 1)*
- [ ] **Step 3** — Wire `t`/`w`/`m`/`r` into keymap *(prerequisite: RFC-007 Step 4)*
- [ ] **Step 4** — Hover chip for mouse users *(prerequisite: Step 2)*

---

## Open Questions

- [ ] **Q1** — User's locale for "next week" — Mon-start vs Sun-start? MVP: `today + 7 days`, not "next Monday".
- [ ] **Q2** — Should overdue tasks "snap" forward if user presses `t` on a task whose due is yesterday? MVP: always tomorrow-from-today.
- [ ] **Q3** — Visual confirmation (toast vs subtle row animation) — UX detail.
