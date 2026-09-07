use std::collections::HashSet;
use std::path::Path;

use anyhow::{anyhow, Result};
use chrono::{DateTime, Duration, Local, NaiveDate, Utc};
use knotq_commands::recurrence_can_delete_future;
use knotq_date_util::DateRange;
use knotq_index::IndexedWorkspace;
use knotq_model::{
    ColumnId, GoogleOAuthAccount, ImageAssetFormat, ImageInline, ImportedCalendarSource, Inline,
    Item, ItemContent, ItemId, ItemKind, ItemMarker, NotificationDefaults, OccurrenceId,
    Recurrence, RowId, Scheme, Table, TableCell, TableColumn, TableRow, ThemeMode, TimeFormat,
    UpcomingDisplaySettings, Workspace,
};
use knotq_notifications::{NotificationLeadTimes, ScheduledNotification};
use sha2::{Digest, Sha256};

use crate::media_sync::{mobile_item_image_assets, mobile_media_to_item_media};
use crate::parsing::{parse_datetime_opt, parse_id, parse_marker_spec};
use crate::{
    MobileCellLine, MobileInline, MobileItem, MobileItemMedia, MobileNode,
    MobileNotificationRequest, MobileOccurrence, MobileTable, MobileTableCell, MobileTableColumn,
    MobileTableRow,
};

// Conversions between the domain model (`knotq_model`) and the UniFFI-facing
// `Mobile*` records, plus the small formatting/lookup helpers they rely on.
// The `Mobile*` types themselves are declared in the UDL and defined in lib.rs;
// only their inherent impls and the free helper fns live here.

impl MobileItem {
    pub(crate) fn from_item(item: &Item, image_assets_dir: &Path) -> Self {
        // A line is single-content; flatten to the inline run the bridge speaks
        // (one element, or empty for a blank text line).
        let inlines = item.content.to_inlines();
        Self {
            id: item.id.to_string(),
            text: item.text(),
            marker: format!("{}{}", marker_str(item.marker), item.marker_family.as_suffix().map_or(String::new(), |s| format!(".{s}"))),
            indent: i32::from(item.indent),
            kind: item_kind_str(item.kind()).to_string(),
            done: item.single_state().is_done(),
            start: item.start.map(format_datetime),
            end: item.end.map(format_datetime),
            notification_offset_secs: item
                .single_state()
                .notification_offset_secs
                .map(offset_to_i32),
            repeat_rule: recurrence_rule(item.repeats.as_ref()),
            media: mobile_item_image_assets(item)
                .iter()
                .filter_map(|media| MobileItemMedia::from_media(media, image_assets_dir))
                .collect(),
            tables: inlines
                .iter()
                .filter_map(|inline| match inline {
                    Inline::Table(table) => Some(MobileTable::from_table(table, image_assets_dir)),
                    _ => None,
                })
                .collect(),
            content: inlines
                .iter()
                .filter_map(|inline| MobileInline::from_inline(inline, image_assets_dir))
                .collect(),
        }
    }
}

impl MobileInline {
    /// Maps a domain `Inline` to its mobile representation. Returns `None` for an
    /// image whose asset cannot be resolved on disk (matching the flat `media`
    /// path, which also drops unresolved assets).
    pub(crate) fn from_inline(inline: &Inline, image_assets_dir: &Path) -> Option<Self> {
        match inline {
            Inline::Text { text } => Some(MobileInline::Text { text: text.clone() }),
            Inline::Image(image) => MobileItemMedia::from_media(image, image_assets_dir)
                .map(|media| MobileInline::Image { media }),
            Inline::Table(table) => Some(MobileInline::Table {
                table: MobileTable::from_table(table, image_assets_dir),
            }),
        }
    }
}

pub(crate) fn mobile_inlines_to_inlines(
    content: &[MobileInline],
    image_assets_dir: &Path,
) -> Result<Vec<Inline>> {
    content
        .iter()
        .map(|inline| match inline {
            MobileInline::Text { text } => Ok(Inline::Text { text: text.clone() }),
            MobileInline::Image { media } => mobile_media_to_item_media(media, image_assets_dir)
                .map(Inline::Image)
                .ok_or_else(|| anyhow!("invalid inline image media")),
            MobileInline::Table { table } => Ok(Inline::Table(table.to_table(image_assets_dir)?)),
        })
        .collect()
}

/// Extracts the first RRULE body from a recurrence for display on the client.
pub(crate) fn recurrence_rule(repeats: Option<&Recurrence>) -> Option<String> {
    repeats.and_then(|r| r.rrules.first().cloned())
}

impl MobileItemMedia {
    pub(crate) fn from_media(media: &ImageInline, image_assets_dir: &Path) -> Option<Self> {
        Some(Self {
            kind: "image".to_string(),
            path: Some(
                image_assets_dir
                    .join(format!("{}.{}", media.asset, media.format.extension()))
                    .display()
                    .to_string(),
            ),
            format: image_format_str(media.format).to_string(),
            width: media.width.and_then(|value| i32::try_from(value).ok()),
            height: media.height.and_then(|value| i32::try_from(value).ok()),
        })
    }
}

impl MobileTable {
    pub(crate) fn from_table(table: &Table, image_assets_dir: &Path) -> Self {
        Self {
            columns: table
                .columns
                .iter()
                .map(|column| MobileTableColumn {
                    id: column.id.to_string(),
                    name: column.name.clone(),
                })
                .collect(),
            rows: table
                .rows
                .iter()
                .map(|row| MobileTableRow {
                    id: row.id.to_string(),
                    cells: row
                        .cells
                        .iter()
                        .map(|cell| MobileTableCell {
                            text: cell.summary_text(),
                            lines: cell
                                .items
                                .iter()
                                .map(|item| MobileCellLine::from_item(item, image_assets_dir))
                                .collect(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    pub(crate) fn to_table(&self, image_assets_dir: &Path) -> Result<Table> {
        let mut table = Table {
            columns: self
                .columns
                .iter()
                .map(|column| {
                    Ok(TableColumn {
                        id: parse_id::<ColumnId>(&column.id)?,
                        name: column.name.clone(),
                        width: None,
                    })
                })
                .collect::<Result<Vec<_>>>()?,
            rows: self
                .rows
                .iter()
                .map(|row| {
                    Ok(TableRow {
                        id: parse_id::<RowId>(&row.id)?,
                        cells: row
                            .cells
                            .iter()
                            .map(|cell| cell.to_table_cell(image_assets_dir))
                            .collect::<Result<Vec<_>>>()?,
                    })
                })
                .collect::<Result<Vec<_>>>()?,
        };
        table.normalize();
        Ok(table)
    }
}

impl MobileTableCell {
    pub(crate) fn to_table_cell(&self, image_assets_dir: &Path) -> Result<TableCell> {
        Ok(TableCell::from_items(
            self.lines
                .iter()
                .map(|line| line.to_item(image_assets_dir))
                .collect::<Result<Vec<_>>>()?,
        ))
    }
}

impl MobileCellLine {
    pub(crate) fn from_item(item: &Item, image_assets_dir: &Path) -> Self {
        Self {
            id: item.id.to_string(),
            text: item.text(),
            marker: marker_str(item.marker).to_string(),
            done: item.single_state().is_done(),
            start: item.start.map(format_datetime),
            end: item.end.map(format_datetime),
            media: item
                .images()
                .filter_map(|media| MobileItemMedia::from_media(media, image_assets_dir))
                .collect(),
        }
    }

    pub(crate) fn to_item(&self, image_assets_dir: &Path) -> Result<Item> {
        let mut item = Item::new(self.text.clone());
        item.id = parse_id::<ItemId>(&self.id)?;
        let (marker, family) = parse_marker_spec(Some(&self.marker))?;
        item.marker = marker;
        item.marker_family = family;
        item.start = parse_datetime_opt(self.start.as_deref())?;
        item.end = parse_datetime_opt(self.end.as_deref())?;
        // Legacy cell line: text plus optional media collapses to single-content
        // (a block wins, so a cell line with media is an image line).
        let mut inlines = item.content.to_inlines();
        inlines.extend(
            self.media
                .iter()
                .filter_map(|media| mobile_media_to_item_media(media, image_assets_dir))
                .map(Inline::Image),
        );
        item.content = ItemContent::from_inlines(inlines);
        if item.marker == ItemMarker::Checkbox {
            let state = item.state_for_occurrence_mut(OccurrenceId::Single);
            state.progress = if self.done { -1 } else { 0 };
            item.normalize_state();
        }
        item.enforce_marker_constraints();
        Ok(item)
    }
}

impl MobileOccurrence {
    pub(crate) fn from_context(
        workspace: &Workspace,
        context: knotq_index::calendar::OccurrenceWithContext,
    ) -> Self {
        let item = workspace
            .scheme(context.scheme_id)
            .and_then(|scheme| scheme.item(context.item_id));
        let title = item.map(|item| item.text()).unwrap_or_default();
        let repeat_rule = item.and_then(|item| recurrence_rule(item.repeats.as_ref()));
        let can_delete_future = item
            .and_then(|item| item.repeats.as_ref())
            .is_some_and(recurrence_can_delete_future);
        let local_date = context
            .occurrence
            .start
            .or(context.occurrence.end)
            .map(|dt| dt.with_timezone(&Local).date_naive().to_string());
        let occurrence_json = serde_json::to_string(&context.occurrence.id).unwrap_or_default();
        let occurrence_index =
            i32::try_from(context.occurrence.occurrence_index).unwrap_or(i32::MAX);
        Self {
            scheme_id: context.scheme_id.to_string(),
            item_id: context.item_id.to_string(),
            occurrence_json,
            occurrence_index,
            is_recurring: !context.occurrence.id.is_single(),
            can_delete_future,
            scheme_name: context.scheme_name,
            color_index: i32::from(context.color_index),
            is_read_only: workspace.is_scheme_read_only(context.scheme_id),
            title,
            kind: item_kind_str(context.occurrence.kind).to_string(),
            done: context.occurrence.state.is_done(),
            start: context.occurrence.start.map(format_datetime),
            end: context.occurrence.end.map(format_datetime),
            notification_offset_secs: context
                .occurrence
                .state
                .notification_offset_secs
                .map(offset_to_i32),
            local_date,
            repeat_rule,
        }
    }
}

impl MobileNotificationRequest {
    pub(crate) fn from_scheduled(notification: ScheduledNotification) -> Self {
        let occurrence_json = serde_json::to_string(&notification.occurrence).unwrap_or_default();
        let notification_key = notification.key;
        Self {
            id: mobile_notification_id(&notification_key),
            notification_key,
            fire_at: format_datetime(notification.fire_at),
            expires_at: notification.expires_at.map(format_datetime),
            end_at: notification.end_at.map(format_datetime),
            title: notification.title,
            body: notification.body,
            kind: match notification.kind {
                knotq_notifications::NotificationKind::Reminder => "reminder",
                knotq_notifications::NotificationKind::Event => "event",
                knotq_notifications::NotificationKind::Assignment => "assignment",
            }
            .to_string(),
            scheme_id: notification.scheme_id.to_string(),
            item_id: notification.item_id.to_string(),
            occurrence_json,
            trigger_at: format_datetime(notification.trigger_at),
        }
    }
}

pub(crate) fn mobile_upcoming(
    indexed: &IndexedWorkspace,
    from: DateTime<Utc>,
    lookahead: UpcomingDisplaySettings,
    limit: usize,
) -> Vec<knotq_index::calendar::OccurrenceWithContext> {
    let maximum_days = lookahead
        .event_lookahead_days
        .max(lookahead.reminder_lookahead_days)
        .max(lookahead.assignment_lookahead_days);
    let mut occurrences = indexed.calendar_query().range(DateRange {
        start: from,
        end: from + Duration::days(i64::from(maximum_days)),
    });
    occurrences.retain(|event| {
        let days = match event.occurrence.kind {
            ItemKind::Event => lookahead.event_lookahead_days,
            ItemKind::Reminder => lookahead.reminder_lookahead_days,
            ItemKind::Assignment => lookahead.assignment_lookahead_days,
            ItemKind::Procedure => return false,
        };
        occurrence_anchor(event)
            .is_some_and(|anchor| anchor >= from && anchor < from + Duration::days(i64::from(days)))
    });

    let mut seen_recurring_items = HashSet::new();
    let mut out = Vec::new();
    for event in occurrences {
        if !event.occurrence.id.is_single()
            && !seen_recurring_items.insert((event.scheme_id, event.item_id))
        {
            continue;
        }
        out.push(event);
        if out.len() >= limit {
            break;
        }
    }
    out
}

pub(crate) fn occurrence_anchor(
    event: &knotq_index::calendar::OccurrenceWithContext,
) -> Option<DateTime<Utc>> {
    event
        .occurrence
        .start
        .or(event.occurrence.end)
        .or(event.occurrence.available)
}

pub(crate) fn archived_scheme_node(scheme: &Scheme) -> MobileNode {
    MobileNode {
        kind: "scheme".to_string(),
        id: scheme.id.to_string(),
        name: scheme.name.clone(),
        color_index: Some(i32::from(scheme.color_index)),
        is_daily_queue: false,
        is_read_only: scheme.is_read_only(),
        children: Vec::new(),
    }
}

pub(crate) fn format_datetime(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

pub(crate) fn format_daily_label(date: NaiveDate) -> String {
    // chrono's %a/%b always emit English; route the names through the catalog.
    use chrono::{Datelike, Month, Weekday};
    let weekday = match date.weekday() {
        Weekday::Mon => "common.weekday_short.mon",
        Weekday::Tue => "common.weekday_short.tue",
        Weekday::Wed => "common.weekday_short.wed",
        Weekday::Thu => "common.weekday_short.thu",
        Weekday::Fri => "common.weekday_short.fri",
        Weekday::Sat => "common.weekday_short.sat",
        Weekday::Sun => "common.weekday_short.sun",
    };
    let month = match Month::try_from(date.month() as u8).unwrap_or(Month::January) {
        Month::January => "common.month_short.jan",
        Month::February => "common.month_short.feb",
        Month::March => "common.month_short.mar",
        Month::April => "common.month_short.apr",
        Month::May => "common.month_short.may",
        Month::June => "common.month_short.jun",
        Month::July => "common.month_short.jul",
        Month::August => "common.month_short.aug",
        Month::September => "common.month_short.sep",
        Month::October => "common.month_short.oct",
        Month::November => "common.month_short.nov",
        Month::December => "common.month_short.dec",
    };
    format!(
        "{}, {} {}",
        knotq_l10n::t(weekday),
        knotq_l10n::t(month),
        date.day()
    )
}

pub(crate) fn marker_str(marker: ItemMarker) -> &'static str {
    match marker {
        ItemMarker::Blank => "blank",
        ItemMarker::Bullet => "bullet",
        ItemMarker::Numbered => "numbered",
        ItemMarker::Checkbox => "checkbox",
    }
}

pub(crate) fn item_kind_str(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Reminder => "reminder",
        ItemKind::Assignment => "assignment",
        ItemKind::Event => "event",
        ItemKind::Procedure => "procedure",
    }
}

pub(crate) fn image_format_str(format: ImageAssetFormat) -> &'static str {
    match format {
        ImageAssetFormat::Png => "png",
        ImageAssetFormat::Jpeg => "jpeg",
        ImageAssetFormat::Webp => "webp",
        ImageAssetFormat::Gif => "gif",
        ImageAssetFormat::Svg => "svg",
        ImageAssetFormat::Bmp => "bmp",
        ImageAssetFormat::Tiff => "tiff",
    }
}

pub(crate) fn theme_mode_str(theme_mode: ThemeMode) -> &'static str {
    match theme_mode {
        ThemeMode::System => "system",
        ThemeMode::Dark => "dark",
        ThemeMode::Light => "light",
    }
}

pub(crate) fn time_format_str(time_format: TimeFormat) -> &'static str {
    match time_format {
        TimeFormat::TwelveHour => "twelve_hour",
        TimeFormat::TwentyFourHour => "twenty_four_hour",
    }
}

pub(crate) fn mobile_notification_lead_times(
    defaults: NotificationDefaults,
) -> NotificationLeadTimes {
    NotificationLeadTimes {
        reminder_offset_secs: 0,
        event_offset_secs: defaults.event_offset_secs,
        assignment_offset_secs: defaults.assignment_offset_secs,
    }
}

pub(crate) fn offset_to_i32(offset_secs: i64) -> i32 {
    offset_secs.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

pub(crate) fn mobile_notification_id(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    format!(
        "knotq-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7]
    )
}

pub(crate) fn next_color_index(workspace: &Workspace) -> u8 {
    let count = workspace
        .iter_schemes()
        .filter(|scheme| !workspace.is_daily_queue_scheme(scheme.id))
        .count();
    (count % 10) as u8
}

pub(crate) fn non_empty(value: String, label: &str) -> Result<String> {
    let value = value.trim().to_string();
    if value.is_empty() {
        Err(anyhow!("{label} is required"))
    } else {
        Ok(value)
    }
}

pub(crate) fn opt_position(position: Option<i32>) -> Result<Option<usize>> {
    position.map(position_from_i32).transpose()
}

pub(crate) fn position_from_i32(position: i32) -> Result<usize> {
    usize::try_from(position).map_err(|_| anyhow!("position cannot be negative: {position}"))
}

pub(crate) fn as_u8(value: i32, label: &str) -> Result<u8> {
    u8::try_from(value).map_err(|_| anyhow!("{label} must be between 0 and 255: {value}"))
}

pub(crate) fn as_u16(value: i32, label: &str) -> Result<u16> {
    u16::try_from(value).map_err(|_| anyhow!("{label} must be between 0 and 65535: {value}"))
}

pub(crate) fn google_account_matches_calendar_source(
    account: &GoogleOAuthAccount,
    source: &ImportedCalendarSource,
) -> bool {
    if account.account_id == source.account_id {
        return true;
    }
    let Some(account_email) = account.email.as_deref() else {
        return false;
    };
    let source_email = source.account_email.as_deref().or_else(|| {
        source
            .account_id
            .contains('@')
            .then_some(source.account_id.as_str())
    });
    source_email.is_some_and(|source_email| emails_match(account_email, source_email))
}

pub(crate) fn emails_match(left: &str, right: &str) -> bool {
    left.trim().eq_ignore_ascii_case(right.trim())
}
