use std::str::FromStr;

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use knotq_commands::{DateEditScope, DateKind, EventDeleteScope};
use knotq_model::{ItemMarker, MarkerFamily, OccurrenceId, Recurrence, ThemeMode, TimeFormat};

use crate::{MOBILE_DAILY_DEFAULT_HISTORY_DAYS, MOBILE_DAILY_MAX_HISTORY_DAYS};

// Small string/date parsing + normalization helpers shared by MobileCore,
// extracted from lib.rs. Not part of the UniFFI surface.

pub(crate) fn parse_id<T>(raw: &str) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    raw.parse::<T>().with_context(|| format!("parse id {raw}"))
}

pub(crate) fn parse_marker(raw: Option<&str>) -> Result<ItemMarker> {
    Ok(match raw.unwrap_or("blank") {
        "blank" => ItemMarker::Blank,
        "bullet" => ItemMarker::Bullet,
        "numbered" => ItemMarker::Numbered,
        "checkbox" => ItemMarker::Checkbox,
        other => return Err(anyhow!("unknown marker {other}")),
    })
}

pub(crate) fn parse_marker_spec(raw: Option<&str>) -> Result<(ItemMarker, MarkerFamily)> {
    let raw = raw.unwrap_or("blank");
    let (marker, suffix) = raw.split_once('.').map_or((raw, "standard"), |(m, s)| (m, s));
    let marker = parse_marker(Some(marker))?;
    let family = MarkerFamily::from_suffix(suffix);
    if !family.is_valid_for(marker) { return Err(anyhow!("marker family {suffix} is not valid for {marker:?}")); }
    Ok((marker, family))
}

pub(crate) fn parse_date_kind(raw: &str) -> Result<DateKind> {
    Ok(match raw {
        "start" => DateKind::Start,
        "end" => DateKind::End,
        other => return Err(anyhow!("unknown date kind {other}")),
    })
}

pub(crate) fn parse_date_edit_scope(raw: &str) -> Result<DateEditScope> {
    Ok(match raw {
        "this_event" => DateEditScope::ThisEvent,
        "all_future" => DateEditScope::AllFuture,
        "all_events" => DateEditScope::AllEvents,
        other => return Err(anyhow!("unknown event edit scope {other}")),
    })
}

pub(crate) fn parse_event_delete_scope(raw: &str) -> Result<EventDeleteScope> {
    Ok(match raw {
        "this_event" => EventDeleteScope::ThisEvent,
        "all_future" => EventDeleteScope::AllFuture,
        "all_events" => EventDeleteScope::AllEvents,
        other => return Err(anyhow!("unknown event delete scope {other}")),
    })
}

pub(crate) fn parse_occurrence_json(raw: &str) -> Result<OccurrenceId> {
    serde_json::from_str(raw).with_context(|| "parse occurrence")
}

pub(crate) fn recurrence_from_rrule(rrule: Option<String>) -> Option<Recurrence> {
    match rrule {
        Some(rule) if !rule.trim().is_empty() => Some(Recurrence {
            rrules: vec![rule.trim().to_string()],
            ..Recurrence::default()
        }),
        _ => None,
    }
}

pub(crate) fn parse_theme_mode(raw: &str) -> Result<ThemeMode> {
    Ok(match raw {
        "system" => ThemeMode::System,
        "dark" => ThemeMode::Dark,
        "light" => ThemeMode::Light,
        other => return Err(anyhow!("unknown theme mode {other}")),
    })
}

pub(crate) fn parse_time_format(raw: &str) -> Result<TimeFormat> {
    Ok(match raw {
        "twelve_hour" => TimeFormat::TwelveHour,
        "twenty_four_hour" => TimeFormat::TwentyFourHour,
        other => return Err(anyhow!("unknown time format {other}")),
    })
}

pub(crate) fn parse_date_or_today(raw: Option<&str>) -> Result<NaiveDate> {
    match raw {
        Some(raw) if !raw.is_empty() => Ok(NaiveDate::parse_from_str(raw, "%Y-%m-%d")?),
        _ => Ok(default_today()),
    }
}

pub(crate) fn normalize_daily_history_days(days: i32) -> i64 {
    i64::from(days.clamp(
        MOBILE_DAILY_DEFAULT_HISTORY_DAYS,
        MOBILE_DAILY_MAX_HISTORY_DAYS,
    ))
}

pub(crate) fn parse_datetime_opt(raw: Option<&str>) -> Result<Option<DateTime<Utc>>> {
    match raw {
        Some(raw) if !raw.is_empty() => Ok(Some(parse_datetime(raw)?)),
        _ => Ok(None),
    }
}

pub(crate) fn parse_datetime(raw: &str) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(raw)?.with_timezone(&Utc))
}

pub(crate) fn default_today() -> NaiveDate {
    Local::now().date_naive()
}

pub(crate) fn local_midnight_utc(date: NaiveDate) -> Result<DateTime<Utc>> {
    let naive = date
        .and_hms_opt(0, 0, 0)
        .ok_or_else(|| anyhow!("invalid midnight for {date}"))?;
    let local = Local
        .from_local_datetime(&naive)
        .single()
        .or_else(|| Local.from_local_datetime(&naive).earliest())
        .or_else(|| Local.from_local_datetime(&naive).latest())
        .ok_or_else(|| anyhow!("invalid local midnight for {date}"))?;
    Ok(local.with_timezone(&Utc))
}

pub(crate) fn notification_tomorrow_morning_utc() -> DateTime<Utc> {
    let tomorrow = Local::now().date_naive() + Duration::days(1);
    let Some(naive) = tomorrow.and_hms_opt(9, 0, 0) else {
        return Utc::now() + Duration::days(1);
    };
    let local = Local
        .from_local_datetime(&naive)
        .single()
        .or_else(|| Local.from_local_datetime(&naive).earliest())
        .or_else(|| Local.from_local_datetime(&naive).latest())
        .unwrap_or_else(|| Local::now() + Duration::days(1));
    local.with_timezone(&Utc)
}
