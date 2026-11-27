//! A session's own timer.
//!
//! `pool-wait` in its slot writes a [`Wake`] to [`FILE`] in the session's HOME, the helper takes it from the detached
//! tree after the turn, and the park puts it in the inbox as a timer row (migration 0014).

use jiff::{Timestamp, ZonedDateTime};
use serde::{Deserialize, Serialize};

use crate::Error;

/// In the session's HOME, `/session/cur/home` in the guest.
pub const FILE: &str = ".pool-wait";
/// The largest note, as `pool-wait --note` takes it.
pub const NOTE_BYTES: usize = 4096;
/// What a wake file may hold: one line, a note at most [`NOTE_BYTES`] of it.
pub const FILE_BYTES: u64 = 8192;

/// When a parked session wakes by itself, and what its turn is told then.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wake {
    /// RFC 3339 with an offset.
    pub due_at: String,
    /// 1 to [`NOTE_BYTES`] bytes; `None` tells the turn only that its time came.
    pub note: Option<String>,
}

impl Wake {
    /// A wake at `due_at`, RFC 3339 in the one shape [`due_at`] writes and PostgreSQL reads alike:
    /// `YYYY-MM-DDTHH:MM:SS` then `Z` or `+HH:MM`/`-HH:MM`.
    ///
    /// # Errors
    /// [`Error::Wake`] for a time in another shape or before 1970, or a note that is empty, over [`NOTE_BYTES`] or
    /// holds a NUL.
    pub fn new(due_at: &str, note: Option<String>) -> Result<Self, Error> {
        let b = due_at.as_bytes();
        let shaped = b.get(10) == Some(&b'T')
            && match b.len() {
                20 => b.get(19) == Some(&b'Z'),
                25 => matches!(b.get(19), Some(b'+' | b'-')) && b.get(22) == Some(&b':'),
                _ => false,
            };
        if !(shaped
            && due_at
                .parse::<Timestamp>()
                .is_ok_and(|t| t.as_second() >= 0))
        {
            return Err(Error::Wake(format!(
                "due_at {due_at:?} is not RFC 3339 with an offset"
            )));
        }
        if let Some(n) = &note
            && (n.is_empty() || n.len() > NOTE_BYTES || n.contains('\0'))
        {
            return Err(Error::Wake(format!(
                "a note is 1 to {NOTE_BYTES} bytes with no NUL"
            )));
        }
        Ok(Self {
            due_at: due_at.to_owned(),
            note,
        })
    }

    /// A wake file's line.
    ///
    /// # Errors
    /// What does not deserialise, or what [`Wake::new`] rejects of it.
    pub fn parse(line: &str) -> Result<Self, Error> {
        let w: Self = serde_json::from_str(line)?;
        Self::new(&w.due_at, w.note)
    }
}

/// How long ago an `HH:MM` that last passed is refused, not read as the next one, a day later.
///
/// Within it, the time was more likely given in another zone (UTC is one or two hours behind Europe/Stockholm) or
/// just missed than meant as a wait of a day.
pub const RECENT_SECS: i64 = 6 * 3600;

/// `--until` or `--at` as RFC 3339 with `now`'s offset: `HH:MM` is the next such time in `now`'s zone, after `now`.
///
/// # Errors
/// [`Error::Wake`] for neither `HH:MM` nor RFC 3339 with an offset, or an `HH:MM` that last passed less than
/// [`RECENT_SECS`] ago (yesterday's included), which names the next one in RFC 3339 for a caller that means it.
pub fn due_at(spec: &str, now: &ZonedDateTime) -> Result<String, Error> {
    let bad = |e: &dyn std::fmt::Display| Error::Wake(format!("{spec:?}: {e}"));
    let rfc3339 = |at: &ZonedDateTime| at.strftime("%Y-%m-%dT%H:%M:%S%:z").to_string();
    let at = match hh_mm(spec) {
        Some((h, m)) => {
            let zoned = |t: jiff::civil::DateTime| {
                t.to_zoned_datetime(now.time_zone().clone())
                    .map_err(|e| bad(&e))
            };
            let today = now.date().at(h, m, 0, 0);
            let at = zoned(today)?;
            let (last, next) = if at.timestamp() <= now.timestamp() {
                (at, zoned(today.tomorrow().map_err(|e| bad(&e))?)?)
            } else {
                (zoned(today.yesterday().map_err(|e| bad(&e))?)?, at)
            };
            let ago = now
                .timestamp()
                .as_second()
                .saturating_sub(last.timestamp().as_second());
            if ago < RECENT_SECS {
                return Err(bad(&format!(
                    "passed {} min ago in local time (it is now {}): for that time in another zone pass RFC 3339 with \
                     its offset, for the next one {}",
                    ago / 60,
                    now.strftime("%H:%M%:z"),
                    rfc3339(&next)
                )));
            }
            next
        }
        None => spec
            .parse::<Timestamp>()
            .map_err(|_| bad(&"neither HH:MM nor RFC 3339 with an offset"))?
            .to_zoned_datetime(now.time_zone().clone()),
    };
    Ok(rfc3339(&at))
}

fn hh_mm(spec: &str) -> Option<(i8, i8)> {
    let (h, m) = spec.split_once(':')?;
    let two = |s: &str| {
        (s.len() == 2 && s.bytes().all(|b| b.is_ascii_digit()))
            .then(|| s.parse::<i8>().ok())
            .flatten()
    };
    let (h, m) = (two(h)?, two(m)?);
    (h < 24 && m < 60).then_some((h, m))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, reason = "a failure is the test failing")]

    use jiff::civil::date;
    use jiff::tz::{Offset, TimeZone};

    use super::*;

    fn at(h: i8, m: i8) -> ZonedDateTime {
        date(2026, 11, 24)
            .at(h, m, 30, 0)
            .to_zoned_datetime(TimeZone::fixed(Offset::constant(1)))
            .unwrap()
    }

    #[test]
    fn hh_mm_is_the_next_one_after_now_and_rfc3339_takes_nows_offset() {
        assert_eq!(
            due_at("09:00", &at(8, 0)).unwrap(),
            "2026-11-24T09:00:00+01:00"
        );
        let six_hours_on = date(2026, 11, 24)
            .at(15, 0, 0, 0)
            .to_zoned_datetime(TimeZone::fixed(Offset::constant(1)))
            .unwrap();
        assert_eq!(
            due_at("09:00", &six_hours_on).unwrap(),
            "2026-11-25T09:00:00+01:00",
            "passed six hours ago to the second: tomorrow's"
        );
        let err = due_at("09:00", &at(9, 0)).unwrap_err().to_string();
        assert!(
            err.contains("passed 0 min ago") && err.contains("2026-11-25T09:00:00+01:00"),
            "this minute has begun: {err}"
        );
        assert!(due_at("09:00", &at(14, 59)).is_err());
        let err = due_at("23:59", &at(0, 30)).unwrap_err().to_string();
        assert!(
            err.contains("passed 31 min ago") && err.contains("2026-11-24T23:59:00+01:00"),
            "yesterday's, just passed: {err}"
        );
        assert_eq!(
            due_at("18:00", &at(0, 30)).unwrap(),
            "2026-11-24T18:00:00+01:00"
        );
        assert_eq!(
            due_at("2026-12-01T06:00:00Z", &at(8, 0)).unwrap(),
            "2026-12-01T07:00:00+01:00"
        );
        for bad in [
            "9:00",
            "24:00",
            "09:60",
            "0900",
            "2026-12-01T06:00:00",
            "soon",
            "",
        ] {
            assert!(due_at(bad, &at(8, 0)).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_wake_file_parses_only_whole_and_bounded() {
        let w =
            Wake::parse(r#"{"due_at": "2026-11-24T09:00:00+01:00", "note": "check CI"}"#).unwrap();
        assert_eq!(
            (w.due_at.as_str(), w.note.as_deref()),
            ("2026-11-24T09:00:00+01:00", Some("check CI"))
        );
        assert_eq!(
            Wake::parse(r#"{"due_at": "2026-11-24T09:00:00+01:00", "note": null}"#)
                .unwrap()
                .note,
            None
        );
        let long = format!(
            r#"{{"due_at": "2026-11-24T09:00:00Z", "note": "{}"}}"#,
            "x".repeat(NOTE_BYTES + 1)
        );
        for bad in [
            r#"{"due_at": "2026-11-24T09:00:00", "note": null}"#,
            r#"{"due_at": "2026-11-24T09:00:00Z", "note": ""}"#,
            r#"{"due_at": "2026-11-24T09:00:00Z", "note": null, "slot": "x"}"#,
            r#"{"due_at": "10000-01-01T00:00:00Z", "note": null}"#,
            r#"{"due_at": "2026-11-24T09:00+01:00", "note": null}"#,
            r#"{"due_at": "1969-12-31T23:59:59Z", "note": null}"#,
            r#"{"due_at": "09:00", "note": null}"#,
            "not json",
            &long,
        ] {
            assert!(Wake::parse(bad).is_err(), "{bad}");
        }
    }
}
