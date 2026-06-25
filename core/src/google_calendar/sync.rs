use super::*;

pub(crate) fn run_google_calendar_import_from_callback(
    config: GoogleOAuthConfig,
    redirect_uri: &str,
    state: &str,
    code_verifier: &str,
    callback_url: &str,
    existing_sources: Vec<ExistingGoogleCalendarSource>,
) -> Result<GoogleCalendarImportResult> {
    let account = run_google_oauth_callback(
        config.clone(),
        redirect_uri,
        state,
        code_verifier,
        callback_url,
    )?;
    run_google_calendar_sync(
        vec![account],
        existing_sources,
        GoogleCalendarImportMode::MissingOnly,
    )
}

pub(crate) fn run_google_calendar_background_sync(
    existing_accounts: Vec<GoogleOAuthAccount>,
    existing_sources: Vec<ExistingGoogleCalendarSource>,
) -> Result<GoogleCalendarImportResult> {
    if existing_accounts.is_empty() || existing_sources.is_empty() {
        return Ok(GoogleCalendarImportResult {
            accounts: Vec::new(),
            calendars: Vec::new(),
            failures: Vec::new(),
        });
    }
    run_google_calendar_sync(
        existing_accounts,
        existing_sources,
        GoogleCalendarImportMode::ExistingOnly,
    )
}

pub(crate) fn google_calendar_sources(workspace: &Workspace) -> Vec<ExistingGoogleCalendarSource> {
    workspace
        .schemes
        .values()
        .filter(|scheme| !workspace.is_scheme_deleted(scheme.id))
        .filter_map(|scheme| {
            let SchemeSource::ImportedCalendar(source) = &scheme.source else {
                return None;
            };
            if source.provider != CalendarProvider::Google {
                return None;
            }
            Some(ExistingGoogleCalendarSource {
                account_id: source.account_id.clone(),
                calendar_id: source.calendar_id.clone(),
                sync_token: source.sync_token.clone(),
            })
        })
        .collect()
}

pub(crate) fn google_calendar_scheme_ids(
    workspace: &Workspace,
    account_id: &str,
    calendar_id: &str,
) -> Vec<SchemeId> {
    let mut ids = Vec::new();
    let mut seen_folders = HashSet::new();
    let mut seen_schemes = HashSet::new();
    collect_google_calendar_scheme_ids(
        workspace,
        workspace.root,
        account_id,
        calendar_id,
        &mut seen_folders,
        &mut seen_schemes,
        &mut ids,
    );

    let mut unreferenced = workspace
        .schemes
        .keys()
        .copied()
        .filter(|id| !seen_schemes.contains(id))
        .filter(|id| google_calendar_scheme_matches(workspace, *id, account_id, calendar_id))
        .collect::<Vec<_>>();
    unreferenced.sort_by_key(|id| id.to_string());
    ids.extend(unreferenced);
    ids
}

fn run_google_calendar_sync(
    accounts: Vec<GoogleOAuthAccount>,
    existing_sources: Vec<ExistingGoogleCalendarSource>,
    mode: GoogleCalendarImportMode,
) -> Result<GoogleCalendarImportResult> {
    let mut updated_accounts = Vec::new();
    let mut calendars = Vec::new();
    let mut failures = Vec::new();

    for mut account in accounts {
        if let Err(err) = refresh_google_access_token_if_needed(&mut account) {
            failures.push(format!(
                "{}: {err:#}",
                account.email.as_deref().unwrap_or(&account.account_id)
            ));
            continue;
        }

        match import_google_account_calendars(&account, &existing_sources, mode) {
            Ok((mut imported, mut account_failures)) => {
                calendars.append(&mut imported);
                failures.append(&mut account_failures);
            }
            Err(err) => failures.push(format!(
                "{}: {err:#}",
                account.email.as_deref().unwrap_or(&account.account_id)
            )),
        }
        updated_accounts.push(account);
    }

    Ok(GoogleCalendarImportResult {
        accounts: updated_accounts,
        calendars,
        failures,
    })
}

fn import_google_account_calendars(
    account: &GoogleOAuthAccount,
    existing_sources: &[ExistingGoogleCalendarSource],
    mode: GoogleCalendarImportMode,
) -> Result<(Vec<ImportedGoogleCalendar>, Vec<String>)> {
    let calendars = list_google_calendars(&account.access_token)?;
    let fallback_count = calendars.len().max(1);
    let mut imported = Vec::new();
    let mut failures = Vec::new();

    for (index, calendar) in calendars.into_iter().enumerate() {
        let existing = existing_sources.iter().find(|source| {
            source.account_id == account.account_id && source.calendar_id == calendar.id
        });
        match mode {
            GoogleCalendarImportMode::ExistingOnly if existing.is_none() => continue,
            GoogleCalendarImportMode::MissingOnly if existing.is_some() => continue,
            _ => {}
        }
        let sync_token = existing.and_then(|source| source.sync_token.clone());
        let events = match list_google_events(&account.access_token, &calendar.id, sync_token) {
            Ok(events) => events,
            Err(err) => {
                failures.push(format!("{}: {err}", google_calendar_name(&calendar)));
                continue;
            }
        };

        let mut items = events
            .events
            .iter()
            .filter_map(|event| google_event_to_item(account, &calendar.id, event))
            .collect::<Vec<_>>();
        sort_imported_items(&mut items);

        let deleted = events
            .events
            .iter()
            .filter(|event| event.status.as_deref() == Some("cancelled"))
            .map(google_event_key)
            .collect();

        imported.push(ImportedGoogleCalendar {
            account_id: account.account_id.clone(),
            account_email: account.email.clone(),
            calendar_id: calendar.id.clone(),
            name: google_calendar_name(&calendar),
            color_index: google_calendar_color_index(
                calendar.background_color.as_deref(),
                index % fallback_count,
            ),
            sync_token: events.sync_token,
            full_sync: events.full_sync,
            items,
            deleted,
        });
    }

    Ok((imported, failures))
}
