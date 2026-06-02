//! Pure date arithmetic for one-keystroke moves.
//!
//! See `designs/RFC-008-keystroke-date-moves.md`.
//!
//! No IO. Tests pin behavior at month-end and across years.

use jiff::civil::Date;

/// What date-move the user requested.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DateMove {
    /// `today + 1 day`.
    Tomorrow,
    /// `today + 7 days`.
    NextWeek,
    /// `today + 1 month`, clamped to month-end.
    NextMonth,
    /// Clear the due date.
    Clear,
}

/// Apply `mv` relative to `today`. `None` means "clear the due date".
pub fn apply_date_move(today: Date, mv: DateMove) -> Option<Date> {
    match mv {
        DateMove::Tomorrow => Some(today.tomorrow().expect("tomorrow within Date::MAX")),
        DateMove::NextWeek => Some(
            today
                .checked_add(jiff::Span::new().days(7))
                .expect("today+7d within Date::MAX"),
        ),
        DateMove::NextMonth => Some(next_month_clamped(today)),
        DateMove::Clear => None,
    }
}

fn next_month_clamped(today: Date) -> Date {
    // Advance month by 1; if the original day overflows the target month,
    // clamp to that month's last day.
    let (year, mut month) = (today.year(), today.month());
    let mut target_year = year;
    if month == 12 {
        month = 1;
        target_year += 1;
    } else {
        month += 1;
    }
    let target_first = Date::new(target_year, month, 1).expect("valid month start");
    let last_day_of_target = target_first.last_of_month().day();
    let target_day = today.day().min(last_day_of_target);
    Date::new(target_year, month, target_day).expect("clamped date is valid")
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    #[test]
    fn tomorrow_advances_one_day() {
        assert_eq!(
            apply_date_move(date(2026, 5, 23), DateMove::Tomorrow),
            Some(date(2026, 5, 24))
        );
    }

    #[test]
    fn tomorrow_crosses_month_boundary() {
        assert_eq!(
            apply_date_move(date(2026, 1, 31), DateMove::Tomorrow),
            Some(date(2026, 2, 1))
        );
    }

    #[test]
    fn next_week_is_plus_seven_days() {
        assert_eq!(
            apply_date_move(date(2026, 5, 23), DateMove::NextWeek),
            Some(date(2026, 5, 30))
        );
    }

    #[test]
    fn next_month_clamps_at_february() {
        assert_eq!(
            apply_date_move(date(2026, 1, 31), DateMove::NextMonth),
            Some(date(2026, 2, 28))
        );
    }

    #[test]
    fn next_month_uses_leap_february_when_applicable() {
        assert_eq!(
            apply_date_move(date(2028, 1, 31), DateMove::NextMonth),
            Some(date(2028, 2, 29))
        );
    }

    #[test]
    fn next_month_crosses_year() {
        assert_eq!(
            apply_date_move(date(2026, 12, 30), DateMove::NextMonth),
            Some(date(2027, 1, 30))
        );
    }

    #[test]
    fn next_month_clamps_at_30_day_month() {
        // March → April: April has 30 days, March 31st clamps to April 30.
        assert_eq!(
            apply_date_move(date(2026, 3, 31), DateMove::NextMonth),
            Some(date(2026, 4, 30))
        );
    }

    #[test]
    fn clear_returns_none() {
        assert_eq!(apply_date_move(date(2026, 5, 23), DateMove::Clear), None);
    }

    #[test]
    fn applying_tomorrow_twice_is_two_days_apart() {
        let today = date(2026, 5, 23);
        let t = apply_date_move(today, DateMove::Tomorrow).unwrap();
        let tt = apply_date_move(t, DateMove::Tomorrow).unwrap();
        assert_eq!(tt, date(2026, 5, 25));
    }
}
