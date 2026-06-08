//! Client-side recurrence engine for "scheduled" (repeating) tasks.
//!
//! # Why client-side?
//!
//! The Google Tasks REST API (v1) exposes **no** recurrence field on a task —
//! only `due`, `status`, `notes`, etc. Recurring tasks created in Google's own
//! UI are materialized server-side into individual instances; the API can
//! neither read nor write the recurrence rule. See
//! `developers.google.com/tasks/reference/rest/v1/tasks`.
//!
//! To give axiotask faithful repeating-task behavior while staying "deep
//! integration, no abstraction layers", we:
//!
//! 1. Model recurrence with a small type that mirrors the options Google's own
//!    repeat UI offers (daily / weekly / monthly / yearly, every-N, specific
//!    weekdays, and an end condition).
//! 2. Serialize it as an RFC 5545 `RRULE` string and stash it in the task
//!    `notes` field inside a machine-readable trailer. `notes` **is** synced by
//!    Google, so the rule round-trips across devices through Google's own
//!    storage — that is how we "rely on Google" to persist scheduling.
//! 3. Compute the next occurrence locally so that completing a repeating task
//!    can spawn its next instance.
//!
//! This module is pure (no IO) and fully unit tested, matching the `dates.rs`
//! convention.

use std::fmt;

use jiff::civil::{Date, Weekday};

/// How often a task repeats.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Frequency {
    /// Repeats every N days.
    Daily,
    /// Repeats every N weeks (optionally on specific weekdays).
    Weekly,
    /// Repeats every N months on the same day-of-month (clamped to month end).
    Monthly,
    /// Repeats every N years on the same month/day (Feb 29 clamps to Feb 28).
    Yearly,
}

impl Frequency {
    /// RFC 5545 `FREQ=` token.
    pub fn as_rrule(self) -> &'static str {
        match self {
            Self::Daily => "DAILY",
            Self::Weekly => "WEEKLY",
            Self::Monthly => "MONTHLY",
            Self::Yearly => "YEARLY",
        }
    }

    fn parse_rrule(s: &str) -> Option<Self> {
        match s {
            "DAILY" => Some(Self::Daily),
            "WEEKLY" => Some(Self::Weekly),
            "MONTHLY" => Some(Self::Monthly),
            "YEARLY" => Some(Self::Yearly),
            _ => None,
        }
    }

    fn noun(self) -> &'static str {
        match self {
            Self::Daily => "day",
            Self::Weekly => "week",
            Self::Monthly => "month",
            Self::Yearly => "year",
        }
    }
}

/// When a recurrence stops.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecurrenceEnd {
    /// Repeats forever.
    Never,
    /// Repeats until (and including) this date; no occurrence after it.
    OnDate(Date),
    /// A bounded number of occurrences *still remaining* (this instance plus
    /// the ones after it). Serialized as RFC 5545 `COUNT`. We track remaining
    /// rather than the absolute total because a stateless client only ever
    /// knows "how many are left".
    Count(u32),
}

/// A parsed recurrence rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recurrence {
    /// Base cadence.
    pub freq: Frequency,
    /// Interval multiplier (`>= 1`). `2` + `Weekly` == every other week.
    pub interval: u32,
    /// For `Weekly`: the weekdays it lands on. Empty means "same weekday as the
    /// anchor date". Ignored for other frequencies.
    pub byday: Vec<Weekday>,
    /// Termination condition.
    pub end: RecurrenceEnd,
}

impl Recurrence {
    /// Build a simple rule with no `BYDAY` and no end.
    pub fn every(freq: Frequency, interval: u32) -> Self {
        Self {
            freq,
            interval: interval.max(1),
            byday: Vec::new(),
            end: RecurrenceEnd::Never,
        }
    }

    /// Serialize to an RFC 5545 `RRULE` value (without the `RRULE:` prefix).
    pub fn to_rrule(&self) -> String {
        let mut parts = vec![format!("FREQ={}", self.freq.as_rrule())];
        let interval = self.interval.max(1);
        if interval != 1 {
            parts.push(format!("INTERVAL={interval}"));
        }
        if self.freq == Frequency::Weekly && !self.byday.is_empty() {
            let days: Vec<&str> = self.byday.iter().map(|d| weekday_rrule(*d)).collect();
            parts.push(format!("BYDAY={}", days.join(",")));
        }
        match self.end {
            RecurrenceEnd::Never => {}
            RecurrenceEnd::OnDate(d) => {
                parts.push(format!("UNTIL={:04}{:02}{:02}", d.year(), d.month(), d.day()));
            }
            RecurrenceEnd::Count(n) => parts.push(format!("COUNT={n}")),
        }
        parts.join(";")
    }

    /// Parse an RFC 5545 `RRULE` value. Returns `None` if there is no usable
    /// `FREQ`. Unknown tokens are ignored for forward-compatibility.
    pub fn from_rrule(s: &str) -> Option<Self> {
        let body = s.trim().strip_prefix("RRULE:").unwrap_or(s.trim());
        let mut freq = None;
        let mut interval = 1u32;
        let mut byday = Vec::new();
        let mut end = RecurrenceEnd::Never;

        for token in body.split(';') {
            let token = token.trim();
            if token.is_empty() {
                continue;
            }
            let Some((key, value)) = token.split_once('=') else {
                continue;
            };
            match key.trim().to_ascii_uppercase().as_str() {
                "FREQ" => freq = Frequency::parse_rrule(value.trim().to_ascii_uppercase().as_str()),
                "INTERVAL" => {
                    if let Ok(n) = value.trim().parse::<u32>() {
                        interval = n.max(1);
                    }
                }
                "BYDAY" => {
                    byday = value
                        .split(',')
                        .filter_map(|d| parse_weekday_rrule(d.trim()))
                        .collect();
                }
                "UNTIL" => {
                    if let Some(d) = parse_until(value.trim()) {
                        end = RecurrenceEnd::OnDate(d);
                    }
                }
                "COUNT" => {
                    if let Ok(n) = value.trim().parse::<u32>() {
                        end = RecurrenceEnd::Count(n);
                    }
                }
                _ => {}
            }
        }

        freq.map(|freq| Self {
            freq,
            interval,
            byday,
            end,
        })
    }

    /// The next occurrence strictly after `from`, ignoring the end condition.
    pub fn raw_next(&self, from: Date) -> Date {
        let interval = i64::from(self.interval.max(1));
        match self.freq {
            Frequency::Daily => add_days(from, interval),
            Frequency::Weekly => {
                if self.byday.is_empty() {
                    add_days(from, 7 * interval)
                } else {
                    next_weekly_byday(from, &self.byday, interval)
                }
            }
            Frequency::Monthly => add_months(from, interval),
            Frequency::Yearly => add_years(from, interval),
        }
    }

    /// Plan the next occurrence after a task with due date `from` is completed.
    ///
    /// Returns `None` when the series has ended. Otherwise returns the next due
    /// date together with the rule that should be carried forward (with
    /// `COUNT` decremented when applicable).
    pub fn plan_next(&self, from: Date) -> Option<(Date, Recurrence)> {
        // A series that has zero or one occurrence left produces nothing more.
        if let RecurrenceEnd::Count(n) = self.end {
            if n <= 1 {
                return None;
            }
        }

        let next = self.raw_next(from);

        if let RecurrenceEnd::OnDate(until) = self.end {
            if next > until {
                return None;
            }
        }

        let carried_end = match self.end {
            RecurrenceEnd::Count(n) => RecurrenceEnd::Count(n - 1),
            other => other,
        };
        let carried = Recurrence {
            end: carried_end,
            ..self.clone()
        };
        Some((next, carried))
    }

    /// Human-readable summary, e.g. "Every 2 weeks on Mon, Wed, Fri".
    pub fn summary(&self) -> String {
        let interval = self.interval.max(1);
        let base = if interval == 1 {
            match self.freq {
                Frequency::Daily => "Daily".to_string(),
                Frequency::Weekly => "Weekly".to_string(),
                Frequency::Monthly => "Monthly".to_string(),
                Frequency::Yearly => "Yearly".to_string(),
            }
        } else {
            format!("Every {interval} {}s", self.freq.noun())
        };

        let mut out = base;
        if self.freq == Frequency::Weekly && !self.byday.is_empty() {
            let days: Vec<&str> = self.byday.iter().map(|d| weekday_short(*d)).collect();
            out.push_str(" on ");
            out.push_str(&days.join(", "));
        }
        match self.end {
            RecurrenceEnd::Never => {}
            RecurrenceEnd::OnDate(d) => {
                out.push_str(&format!(", until {:04}-{:02}-{:02}", d.year(), d.month(), d.day()));
            }
            RecurrenceEnd::Count(n) => {
                out.push_str(&format!(", {n} times"));
            }
        }
        out
    }
}

impl fmt::Display for Recurrence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.summary())
    }
}

const TRAILER_OPEN: &str = "[[recur:";
const TRAILER_CLOSE: &str = "]]";

/// Split a stored `notes` string into its user-visible text and an embedded
/// recurrence rule, if present. The trailer format is `[[recur:RRULE]]`.
pub fn extract_from_notes(notes: &str) -> (String, Option<Recurrence>) {
    if let Some(open) = notes.rfind(TRAILER_OPEN) {
        let after = &notes[open + TRAILER_OPEN.len()..];
        if let Some(close_rel) = after.find(TRAILER_CLOSE) {
            let rule_str = &after[..close_rel];
            let rest_start = open + TRAILER_OPEN.len() + close_rel + TRAILER_CLOSE.len();
            let mut visible = String::with_capacity(notes.len());
            visible.push_str(&notes[..open]);
            visible.push_str(&notes[rest_start..]);
            let visible = visible.trim().to_string();
            return (visible, Recurrence::from_rrule(rule_str));
        }
    }
    (notes.to_string(), None)
}

/// Embed (or replace) a recurrence trailer in a `notes` string. Passing `None`
/// strips any existing trailer. The returned string is what should be stored in
/// the task's `notes` field so the rule syncs through Google.
pub fn embed_in_notes(notes: &str, rule: Option<&Recurrence>) -> String {
    let (visible, _) = extract_from_notes(notes);
    match rule {
        None => visible,
        Some(r) => {
            let trailer = format!("{TRAILER_OPEN}{}{TRAILER_CLOSE}", r.to_rrule());
            if visible.is_empty() {
                trailer
            } else {
                format!("{visible}\n{trailer}")
            }
        }
    }
}

// --- weekday <-> RRULE token mapping ----------------------------------------

fn weekday_rrule(d: Weekday) -> &'static str {
    match d {
        Weekday::Monday => "MO",
        Weekday::Tuesday => "TU",
        Weekday::Wednesday => "WE",
        Weekday::Thursday => "TH",
        Weekday::Friday => "FR",
        Weekday::Saturday => "SA",
        Weekday::Sunday => "SU",
    }
}

fn weekday_short(d: Weekday) -> &'static str {
    match d {
        Weekday::Monday => "Mon",
        Weekday::Tuesday => "Tue",
        Weekday::Wednesday => "Wed",
        Weekday::Thursday => "Thu",
        Weekday::Friday => "Fri",
        Weekday::Saturday => "Sat",
        Weekday::Sunday => "Sun",
    }
}

fn parse_weekday_rrule(s: &str) -> Option<Weekday> {
    match s.to_ascii_uppercase().as_str() {
        "MO" => Some(Weekday::Monday),
        "TU" => Some(Weekday::Tuesday),
        "WE" => Some(Weekday::Wednesday),
        "TH" => Some(Weekday::Thursday),
        "FR" => Some(Weekday::Friday),
        "SA" => Some(Weekday::Saturday),
        "SU" => Some(Weekday::Sunday),
        _ => None,
    }
}

/// Parse an RFC 5545 `UNTIL` value. Accepts `YYYYMMDD` and the datetime form
/// `YYYYMMDDTHHMMSSZ` (we keep only the date part — Google due dates are
/// date-only).
fn parse_until(s: &str) -> Option<Date> {
    let date_part = s.split('T').next().unwrap_or(s);
    if date_part.len() != 8 {
        return None;
    }
    let year: i16 = date_part[0..4].parse().ok()?;
    let month: i8 = date_part[4..6].parse().ok()?;
    let day: i8 = date_part[6..8].parse().ok()?;
    Date::new(year, month, day).ok()
}

// --- date arithmetic (deterministic, clamping) ------------------------------

fn add_days(from: Date, days: i64) -> Date {
    from.checked_add(jiff::Span::new().days(days))
        .expect("date within range")
}

/// Add `n` months, clamping the day to the target month's last day.
fn add_months(from: Date, n: i64) -> Date {
    let total = i64::from(from.year()) * 12 + (i64::from(from.month()) - 1) + n;
    let target_year = total.div_euclid(12) as i16;
    let target_month = (total.rem_euclid(12) + 1) as i8;
    let first = Date::new(target_year, target_month, 1).expect("valid month start");
    let last_day = first.last_of_month().day();
    let day = from.day().min(last_day);
    Date::new(target_year, target_month, day).expect("clamped date is valid")
}

/// Add `n` years, clamping Feb 29 to Feb 28 in non-leap target years.
fn add_years(from: Date, n: i64) -> Date {
    let target_year = (i64::from(from.year()) + n) as i16;
    let first = Date::new(target_year, from.month(), 1).expect("valid month start");
    let last_day = first.last_of_month().day();
    let day = from.day().min(last_day);
    Date::new(target_year, from.month(), day).expect("clamped date is valid")
}

/// Monday of the ISO week containing `d`.
fn monday_of(d: Date) -> Date {
    let offset = i64::from(d.weekday().to_monday_zero_offset());
    add_days(d, -offset)
}

/// Next date strictly after `from` whose weekday is in `byday` and whose week
/// (relative to `from`'s week) is a multiple of `interval`.
fn next_weekly_byday(from: Date, byday: &[Weekday], interval: i64) -> Date {
    let start_week = monday_of(from);
    let mut d = add_days(from, 1);
    // Bounded: worst case we scan to the start of the next eligible week plus a
    // full week of days. `interval * 7 + 7` is a safe upper bound.
    let max_scan = interval * 7 + 7;
    for _ in 0..max_scan {
        let weeks = days_between(start_week, monday_of(d)) / 7;
        if weeks % interval == 0 && byday.contains(&d.weekday()) {
            return d;
        }
        d = add_days(d, 1);
    }
    // Should be unreachable given the bound; fall back to a plain interval jump.
    add_days(from, 7 * interval)
}

fn days_between(a: Date, b: Date) -> i64 {
    i64::from((b - a).get_days())
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    fn rule(s: &str) -> Recurrence {
        Recurrence::from_rrule(s).expect("valid rrule")
    }

    #[test]
    fn round_trips_simple_daily() {
        let r = Recurrence::every(Frequency::Daily, 1);
        assert_eq!(r.to_rrule(), "FREQ=DAILY");
        assert_eq!(Recurrence::from_rrule("FREQ=DAILY"), Some(r));
    }

    #[test]
    fn round_trips_interval() {
        let r = rule("FREQ=DAILY;INTERVAL=3");
        assert_eq!(r.freq, Frequency::Daily);
        assert_eq!(r.interval, 3);
        assert_eq!(r.to_rrule(), "FREQ=DAILY;INTERVAL=3");
    }

    #[test]
    fn round_trips_weekly_byday() {
        let r = rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR");
        assert_eq!(r.interval, 2);
        assert_eq!(
            r.byday,
            vec![Weekday::Monday, Weekday::Wednesday, Weekday::Friday]
        );
        assert_eq!(r.to_rrule(), "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR");
    }

    #[test]
    fn round_trips_until() {
        let r = rule("FREQ=MONTHLY;UNTIL=20261231");
        assert_eq!(r.end, RecurrenceEnd::OnDate(date(2026, 12, 31)));
        assert_eq!(r.to_rrule(), "FREQ=MONTHLY;UNTIL=20261231");
    }

    #[test]
    fn round_trips_count() {
        let r = rule("FREQ=YEARLY;COUNT=5");
        assert_eq!(r.end, RecurrenceEnd::Count(5));
        assert_eq!(r.to_rrule(), "FREQ=YEARLY;COUNT=5");
    }

    #[test]
    fn parse_accepts_rrule_prefix_and_is_case_insensitive() {
        let r = rule("RRULE:freq=weekly;byday=tu");
        assert_eq!(r.freq, Frequency::Weekly);
        assert_eq!(r.byday, vec![Weekday::Tuesday]);
    }

    #[test]
    fn parse_ignores_unknown_tokens() {
        let r = rule("FREQ=DAILY;WKST=MO;FOO=BAR");
        assert_eq!(r.freq, Frequency::Daily);
    }

    #[test]
    fn parse_until_accepts_datetime_form() {
        let r = rule("FREQ=DAILY;UNTIL=20260901T000000Z");
        assert_eq!(r.end, RecurrenceEnd::OnDate(date(2026, 9, 1)));
    }

    #[test]
    fn parse_returns_none_without_freq() {
        assert_eq!(Recurrence::from_rrule("INTERVAL=2"), None);
        assert_eq!(Recurrence::from_rrule(""), None);
    }

    #[test]
    fn raw_next_daily() {
        let r = Recurrence::every(Frequency::Daily, 1);
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 9));
    }

    #[test]
    fn raw_next_daily_interval_crosses_month() {
        let r = Recurrence::every(Frequency::Daily, 5);
        assert_eq!(r.raw_next(date(2026, 1, 30)), date(2026, 2, 4));
    }

    #[test]
    fn raw_next_weekly_no_byday() {
        let r = Recurrence::every(Frequency::Weekly, 1);
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 15));
    }

    #[test]
    fn raw_next_weekly_every_other_week() {
        let r = Recurrence::every(Frequency::Weekly, 2);
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 22));
    }

    #[test]
    fn raw_next_weekly_byday_within_same_week() {
        // 2026-06-08 is a Monday. MO,WE,FR -> next is Wednesday the 10th.
        let r = rule("FREQ=WEEKLY;BYDAY=MO,WE,FR");
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 10));
    }

    #[test]
    fn raw_next_weekly_byday_rolls_to_next_week() {
        // Friday 2026-06-12 with MO,WE,FR rolls to Monday the 15th.
        let r = rule("FREQ=WEEKLY;BYDAY=MO,WE,FR");
        assert_eq!(r.raw_next(date(2026, 6, 12)), date(2026, 6, 15));
    }

    #[test]
    fn raw_next_weekly_byday_respects_interval() {
        // Every other week on Monday, starting from Monday 2026-06-08:
        // skip the 15th (week 1), land on Monday the 22nd (week 2).
        let r = rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO");
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 22));
    }

    #[test]
    fn raw_next_monthly_clamps_month_end() {
        let r = Recurrence::every(Frequency::Monthly, 1);
        assert_eq!(r.raw_next(date(2026, 1, 31)), date(2026, 2, 28));
    }

    #[test]
    fn raw_next_monthly_crosses_year() {
        let r = Recurrence::every(Frequency::Monthly, 2);
        assert_eq!(r.raw_next(date(2026, 11, 15)), date(2027, 1, 15));
    }

    #[test]
    fn raw_next_yearly_clamps_leap_day() {
        let r = Recurrence::every(Frequency::Yearly, 1);
        assert_eq!(r.raw_next(date(2028, 2, 29)), date(2029, 2, 28));
    }

    #[test]
    fn plan_next_never_repeats_forever() {
        let r = Recurrence::every(Frequency::Daily, 1);
        let (next, carried) = r.plan_next(date(2026, 6, 8)).unwrap();
        assert_eq!(next, date(2026, 6, 9));
        assert_eq!(carried.end, RecurrenceEnd::Never);
    }

    #[test]
    fn plan_next_stops_after_until() {
        let r = rule("FREQ=DAILY;UNTIL=20260608");
        assert_eq!(r.plan_next(date(2026, 6, 8)), None);
    }

    #[test]
    fn plan_next_allows_occurrence_on_until_date() {
        let r = rule("FREQ=DAILY;UNTIL=20260609");
        let (next, _) = r.plan_next(date(2026, 6, 8)).unwrap();
        assert_eq!(next, date(2026, 6, 9));
    }

    #[test]
    fn plan_next_decrements_count() {
        let r = rule("FREQ=DAILY;COUNT=3");
        let (next, carried) = r.plan_next(date(2026, 6, 8)).unwrap();
        assert_eq!(next, date(2026, 6, 9));
        assert_eq!(carried.end, RecurrenceEnd::Count(2));
    }

    #[test]
    fn plan_next_count_one_is_terminal() {
        let r = rule("FREQ=DAILY;COUNT=1");
        assert_eq!(r.plan_next(date(2026, 6, 8)), None);
    }

    #[test]
    fn plan_next_count_runs_down_to_end() {
        // COUNT=3 -> two more spawns, then stop.
        let mut r = rule("FREQ=DAILY;COUNT=3");
        let mut d = date(2026, 6, 8);
        let mut spawns = 0;
        while let Some((next, carried)) = r.plan_next(d) {
            d = next;
            r = carried;
            spawns += 1;
        }
        assert_eq!(spawns, 2);
    }

    #[test]
    fn extract_from_notes_finds_trailer() {
        let (visible, rule) = extract_from_notes("Water the plants\n[[recur:FREQ=DAILY]]");
        assert_eq!(visible, "Water the plants");
        assert_eq!(rule, Some(Recurrence::every(Frequency::Daily, 1)));
    }

    #[test]
    fn extract_from_notes_without_trailer() {
        let (visible, rule) = extract_from_notes("Just a note");
        assert_eq!(visible, "Just a note");
        assert_eq!(rule, None);
    }

    #[test]
    fn embed_in_notes_appends_trailer() {
        let r = Recurrence::every(Frequency::Weekly, 1);
        let stored = embed_in_notes("Standup", Some(&r));
        assert_eq!(stored, "Standup\n[[recur:FREQ=WEEKLY]]");
    }

    #[test]
    fn embed_in_notes_replaces_existing_trailer() {
        let weekly = Recurrence::every(Frequency::Weekly, 1);
        let first = embed_in_notes("Standup\n[[recur:FREQ=DAILY]]", Some(&weekly));
        assert_eq!(first, "Standup\n[[recur:FREQ=WEEKLY]]");
    }

    #[test]
    fn embed_in_notes_strips_trailer_when_none() {
        let stored = embed_in_notes("Standup\n[[recur:FREQ=DAILY]]", None);
        assert_eq!(stored, "Standup");
    }

    #[test]
    fn embed_in_notes_handles_empty_visible() {
        let r = Recurrence::every(Frequency::Daily, 1);
        assert_eq!(embed_in_notes("", Some(&r)), "[[recur:FREQ=DAILY]]");
    }

    #[test]
    fn embed_then_extract_round_trips() {
        let r = rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=4");
        let stored = embed_in_notes("Gym day", Some(&r));
        let (visible, parsed) = extract_from_notes(&stored);
        assert_eq!(visible, "Gym day");
        assert_eq!(parsed, Some(r));
    }

    #[test]
    fn summary_is_human_readable() {
        assert_eq!(Recurrence::every(Frequency::Daily, 1).summary(), "Daily");
        assert_eq!(
            Recurrence::every(Frequency::Monthly, 3).summary(),
            "Every 3 months"
        );
        assert_eq!(
            rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR").summary(),
            "Every 2 weeks on Mon, Wed, Fri"
        );
        assert_eq!(
            rule("FREQ=DAILY;COUNT=5").summary(),
            "Daily, 5 times"
        );
        assert_eq!(
            rule("FREQ=WEEKLY;UNTIL=20261231").summary(),
            "Weekly, until 2026-12-31"
        );
    }

    #[test]
    fn interval_floor_is_one() {
        let r = Recurrence::every(Frequency::Daily, 0);
        assert_eq!(r.interval, 1);
        assert_eq!(r.raw_next(date(2026, 6, 8)), date(2026, 6, 9));
    }
}
