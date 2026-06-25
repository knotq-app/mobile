use super::*;

pub(crate) fn google_calendar_source(calendar: &ImportedGoogleCalendar) -> SchemeSource {
    SchemeSource::ImportedCalendar(ImportedCalendarSource {
        provider: CalendarProvider::Google,
        account_id: calendar.account_id.clone(),
        account_email: calendar.account_email.clone(),
        calendar_id: calendar.calendar_id.clone(),
        sync_token: calendar.sync_token.clone(),
        read_only: true,
        last_synced_at: Some(Utc::now()),
    })
}

pub(crate) fn apply_google_calendar_metadata(
    scheme: &mut Scheme,
    calendar: &ImportedGoogleCalendar,
    should_update_name: bool,
) -> bool {
    let metadata_changed = should_update_name && scheme.name != calendar.name;
    if should_update_name {
        scheme.name = calendar.name.clone();
    }
    scheme.source = google_calendar_source(calendar);
    metadata_changed
}

pub(crate) fn apply_google_calendar_items(
    scheme: &mut Scheme,
    calendar: &ImportedGoogleCalendar,
) -> bool {
    if calendar.full_sync {
        let mut items = calendar
            .items
            .iter()
            .cloned()
            .map(|item| {
                let existing = item
                    .external
                    .as_ref()
                    .and_then(|external| find_existing_external_item(&scheme.items, external));
                merge_imported_item(existing, item)
            })
            .collect::<Vec<_>>();
        sort_imported_items(&mut items);
        if imported_item_lists_equal(&scheme.items, &items) {
            return false;
        }
        scheme.items = items;
        return true;
    }

    let mut changed = false;
    scheme.items.retain(|item| {
        let Some(external) = &item.external else {
            return true;
        };
        if external.provider != CalendarProvider::Google
            || external.account_id != calendar.account_id
            || external.calendar_id != calendar.calendar_id
        {
            return true;
        }
        let keep = !calendar
            .deleted
            .iter()
            .any(|key| external_matches_key(external, key));
        if !keep {
            changed = true;
        }
        keep
    });

    for item in calendar.items.iter().cloned() {
        let Some(external) = item.external.as_ref() else {
            continue;
        };
        if let Some(existing) = scheme.items.iter_mut().find(|candidate| {
            candidate
                .external
                .as_ref()
                .is_some_and(|candidate| external_same_event(candidate, external))
        }) {
            let updated = merge_imported_item(Some(existing), item);
            if !item_content_eq_ignoring_id(existing, &updated) {
                *existing = updated;
                changed = true;
            }
        } else {
            scheme.items.push(item);
            changed = true;
        }
    }
    if changed {
        sort_imported_items(&mut scheme.items);
    }
    changed
}

fn find_existing_external_item<'a>(
    items: &'a [Item],
    external: &ExternalItemSource,
) -> Option<&'a Item> {
    items.iter().find(|candidate| {
        candidate
            .external
            .as_ref()
            .is_some_and(|candidate| external_same_event(candidate, external))
    })
}

fn merge_imported_item(existing: Option<&Item>, mut imported: Item) -> Item {
    let Some(existing) = existing else {
        return imported;
    };
    imported.id = existing.id;
    if item_occurrence_identity_eq(existing, &imported) {
        imported.state = existing.state.clone();
    }
    imported
}

fn imported_item_lists_equal(existing: &[Item], imported: &[Item]) -> bool {
    existing.len() == imported.len()
        && existing
            .iter()
            .zip(imported)
            .all(|(left, right)| item_content_eq_ignoring_id(left, right))
}

fn item_content_eq_ignoring_id(left: &Item, right: &Item) -> bool {
    left.content == right.content
        && left.marker == right.marker
        && left.indent == right.indent
        && left.start == right.start
        && left.end == right.end
        && left.available == right.available
        && left.repeats == right.repeats
        && left.state == right.state
        && left.priority == right.priority
        && left.external == right.external
}

fn item_occurrence_identity_eq(left: &Item, right: &Item) -> bool {
    left.marker == right.marker
        && left.start == right.start
        && left.end == right.end
        && left.available == right.available
        && left.repeats == right.repeats
}

fn external_matches_key(external: &ExternalItemSource, key: &GoogleExternalEventKey) -> bool {
    external.event_id == key.event_id && external.instance_id == key.instance_id
}

fn external_same_event(left: &ExternalItemSource, right: &ExternalItemSource) -> bool {
    left.provider == right.provider
        && left.account_id == right.account_id
        && left.calendar_id == right.calendar_id
        && left.event_id == right.event_id
        && left.instance_id == right.instance_id
}

pub(super) fn collect_google_calendar_scheme_ids(
    workspace: &Workspace,
    folder_id: knotq_model::FolderId,
    account_id: &str,
    calendar_id: &str,
    seen_folders: &mut HashSet<knotq_model::FolderId>,
    seen_schemes: &mut HashSet<SchemeId>,
    out: &mut Vec<SchemeId>,
) {
    if !seen_folders.insert(folder_id) {
        return;
    }
    let Some(folder) = workspace.folders.get(&folder_id) else {
        return;
    };
    for child in &folder.children {
        match *child {
            NodeRef::Scheme(id) => {
                seen_schemes.insert(id);
                if google_calendar_scheme_matches(workspace, id, account_id, calendar_id) {
                    out.push(id);
                }
            }
            NodeRef::Folder(id) => collect_google_calendar_scheme_ids(
                workspace,
                id,
                account_id,
                calendar_id,
                seen_folders,
                seen_schemes,
                out,
            ),
        }
    }
}

pub(super) fn google_calendar_scheme_matches(
    workspace: &Workspace,
    scheme_id: SchemeId,
    account_id: &str,
    calendar_id: &str,
) -> bool {
    if workspace.is_scheme_deleted(scheme_id) {
        return false;
    }
    let Some(scheme) = workspace.schemes.get(&scheme_id) else {
        return false;
    };
    let SchemeSource::ImportedCalendar(source) = &scheme.source else {
        return false;
    };
    source.provider == CalendarProvider::Google
        && source.account_id == account_id
        && source.calendar_id == calendar_id
}

pub(super) fn google_event_to_item(
    account: &GoogleOAuthAccount,
    calendar_id: &str,
    event: &GoogleEvent,
) -> Option<Item> {
    if event.status.as_deref() == Some("cancelled") {
        return None;
    }
    let start = event.start.as_ref().and_then(google_event_datetime_to_utc);
    let end = event.end.as_ref().and_then(google_event_datetime_to_utc);
    if start.is_none() && end.is_none() {
        return None;
    }

    let mut item = Item::new(
        event
            .summary
            .as_deref()
            .filter(|summary| !summary.trim().is_empty())
            .unwrap_or("(untitled)"),
    );
    item.marker = ItemMarker::Checkbox;
    item.start = start;
    item.end = end;
    item.repeats = google_event_recurrence(event);
    let key = google_event_key(event);
    item.external = Some(ExternalItemSource {
        provider: CalendarProvider::Google,
        account_id: account.account_id.clone(),
        calendar_id: calendar_id.to_string(),
        event_id: key.event_id,
        instance_id: key.instance_id,
        updated_at: event.updated,
    });
    Some(item)
}

pub(super) fn google_event_key(event: &GoogleEvent) -> GoogleExternalEventKey {
    GoogleExternalEventKey {
        event_id: event
            .recurring_event_id
            .clone()
            .unwrap_or_else(|| event.id.clone()),
        instance_id: event.recurring_event_id.as_ref().map(|_| event.id.clone()),
    }
}

fn google_event_datetime_to_utc(datetime: &GoogleEventDateTime) -> Option<DateTime<Utc>> {
    datetime
        .date_time
        .or_else(|| datetime.date.and_then(local_date_midnight_utc))
}

fn local_date_midnight_utc(date: NaiveDate) -> Option<DateTime<Utc>> {
    let local = date.and_hms_opt(0, 0, 0)?;
    Local
        .from_local_datetime(&local)
        .earliest()
        .map(|datetime| datetime.with_timezone(&Utc))
}

fn google_event_recurrence(event: &GoogleEvent) -> Option<Recurrence> {
    let mut recurrence = Recurrence::default();
    for raw in event.recurrence.as_ref()? {
        let Some((kind, value)) = raw.split_once(':') else {
            continue;
        };
        match kind.to_ascii_uppercase().as_str() {
            "RRULE" => recurrence.rrules.push(value.to_string()),
            "RDATE" => {
                recurrence
                    .rdates
                    .extend(parse_google_calendar_date_times(value));
            }
            "EXDATE" => {
                recurrence
                    .exdates
                    .extend(parse_google_calendar_date_times(value));
            }
            _ => {}
        }
    }
    if recurrence.rrules.is_empty() && recurrence.rdates.is_empty() && recurrence.exdates.is_empty()
    {
        None
    } else {
        recurrence.raw_import =
            serde_json::to_string(event)
                .ok()
                .map(|data| knotq_model::RawCalendarPayload {
                    content_type: "application/vnd.google.calendar.event+json".to_string(),
                    data,
                });
        Some(recurrence)
    }
}

fn parse_google_calendar_date_times(raw: &str) -> Vec<CalendarDateTime> {
    raw.split(',')
        .filter_map(|part| {
            let value = part
                .split_once(':')
                .map(|(_, value)| value)
                .unwrap_or(part)
                .trim();
            DateTime::parse_from_rfc3339(value)
                .map(|datetime| CalendarDateTime::utc(datetime.with_timezone(&Utc)))
                .ok()
                .or_else(|| {
                    chrono::NaiveDateTime::parse_from_str(value, "%Y%m%dT%H%M%SZ")
                        .ok()
                        .map(|datetime| {
                            CalendarDateTime::utc(DateTime::from_naive_utc_and_offset(
                                datetime, Utc,
                            ))
                        })
                })
                .or_else(|| {
                    NaiveDate::parse_from_str(value, "%Y%m%d")
                        .ok()
                        .map(|date| CalendarDateTime::Date { date })
                })
        })
        .collect()
}

pub(super) fn sort_imported_items(items: &mut [Item]) {
    items.sort_by(|left, right| {
        let left_date = left.start.or(left.end);
        let right_date = right.start.or(right.end);
        left_date
            .cmp(&right_date)
            .then_with(|| left.text().cmp(&right.text()))
            .then_with(|| left.id.0.cmp(&right.id.0))
    });
}

pub(super) fn google_calendar_name(calendar: &GoogleCalendarListEntry) -> String {
    calendar
        .summary_override
        .as_deref()
        .or(calendar.summary.as_deref())
        .filter(|summary| !summary.trim().is_empty())
        .unwrap_or("Google Calendar")
        .to_string()
}

pub(super) fn google_calendar_color_index(background: Option<&str>, fallback: usize) -> u8 {
    const PALETTE: [u32; 6] = [0xff453a, 0xff9f0a, 0x30d158, 0x0a84ff, 0xbf5af2, 0xffd60a];
    let Some(rgb) = background.and_then(parse_google_hex_color) else {
        return (fallback % PALETTE.len()) as u8;
    };

    PALETTE
        .iter()
        .enumerate()
        .min_by_key(|(_, palette)| rgb_distance(rgb, **palette))
        .map(|(idx, _)| idx as u8)
        .unwrap_or((fallback % PALETTE.len()) as u8)
}

fn parse_google_hex_color(raw: &str) -> Option<u32> {
    let value = raw.trim().strip_prefix('#').unwrap_or(raw.trim());
    if value.len() != 6 {
        return None;
    }
    u32::from_str_radix(value, 16).ok()
}

fn rgb_distance(left: u32, right: u32) -> u32 {
    let channels = |rgb: u32| {
        (
            ((rgb >> 16) & 0xff) as i32,
            ((rgb >> 8) & 0xff) as i32,
            (rgb & 0xff) as i32,
        )
    };
    let (lr, lg, lb) = channels(left);
    let (rr, rg, rb) = channels(right);
    ((lr - rr).pow(2) + (lg - rg).pow(2) + (lb - rb).pow(2)) as u32
}
