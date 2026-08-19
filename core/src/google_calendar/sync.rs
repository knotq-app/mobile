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

/// Initial link + import for an account whose access token came from a platform
/// identity service (Android Google Identity).
///
/// Mirrors [`run_google_calendar_import_from_callback`] but skips the OAuth code
/// exchange entirely: the shell already holds a usable access token, so all this
/// does is resolve the account identity behind it and import the calendars that
/// are not linked yet.
pub(crate) fn run_google_calendar_import_with_identity(
    identity: &MobileGoogleIdentityAccount,
    existing_sources: Vec<ExistingGoogleCalendarSource>,
) -> Result<GoogleCalendarImportResult> {
    let account = oauth::google_identity_account(identity)?;
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
                sync_token: if google_calendar_scheme_needs_exception_repair(scheme) {
                    None
                } else {
                    source.sync_token.clone()
                },
            })
        })
        .collect()
}

fn google_calendar_scheme_needs_exception_repair(scheme: &Scheme) -> bool {
    scheme.items.iter().any(|item| {
        let Some(external) = item.external.as_ref() else {
            return false;
        };
        if external.provider != CalendarProvider::Google || external.instance_id.is_some() {
            return false;
        }
        let Some(recurrence) = item.repeats.as_ref() else {
            return false;
        };
        if recurrence.rrules.is_empty() {
            return false;
        }
        let Some(raw_import) = recurrence.raw_import.as_ref() else {
            return true;
        };
        raw_import.content_type == "application/vnd.google.calendar.event+json"
            && !raw_import.data.contains("\"originalStartTime\"")
    })
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
            // A platform-identity account can only be renewed by the shell, so
            // any failure there is the user's to resolve. An OAuth account holds
            // a refresh token that survives a network blip, so it is flagged
            // only when Google says the grant itself is gone — and only that
            // case is a lost *grant*, so only it earns the reconnect wording.
            let grant_gone = google_refresh_grant_rejected(&err);
            let rejected =
                account.token_source == GoogleTokenSource::PlatformIdentity || grant_gone;
            failures.push(google_account_failure(&account, &err, grant_gone));
            // Keep the account in the list either way, so a flag set here is
            // persisted rather than dropped.
            mark_google_reauth(&mut account, rejected);
            updated_accounts.push(account);
            continue;
        }

        match import_google_account_calendars(&account, &existing_sources, mode) {
            Ok((mut imported, mut account_failures)) => {
                calendars.append(&mut imported);
                failures.append(&mut account_failures);
                // Reaching the Calendar API proves the grant is live, so any
                // earlier reconnect prompt for this account can stand down.
                mark_google_reauth(&mut account, false);
            }
            Err(err) => {
                // `import_google_account_calendars` fails as a unit only when
                // the calendar *list* call fails, which means the granted
                // authorization no longer covers us.
                let rejected = google_authorization_rejected(&err);
                mark_google_reauth(&mut account, rejected);
                failures.push(google_account_failure(&account, &err, rejected));
            }
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

        let recurrence_exdates = google_recurring_exception_exdates(&events.events);
        let mut items =
            google_events_to_items(account, &calendar.id, &events.events, &recurrence_exdates);
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
            recurrence_exdates,
        });
    }

    Ok((imported, failures))
}

/// Records (or clears) the reconnect state.
///
/// This is not a platform-identity concern only: a refresh token cannot buy back
/// a calendar permission the user declined on the consent screen or revoked
/// afterwards, so an OAuth account can need consent again just as much as an
/// Android one.
fn mark_google_reauth(account: &mut GoogleOAuthAccount, needs_reauth: bool) {
    account.needs_reauth = needs_reauth;
}

/// Whether a Calendar API failure means the user has to re-consent rather than
/// that the request merely failed. A bare 403 is not enough — Google also spends
/// it on rate limits, which retrying does fix.
fn google_authorization_rejected(err: &anyhow::Error) -> bool {
    let Some(api) = err.downcast_ref::<GoogleApiError>() else {
        return false;
    };
    match api.status {
        Some(401) => true,
        Some(403) => {
            api.message.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
                || api.message.contains("insufficientPermissions")
        }
        _ => false,
    }
}

/// Whether a token refresh failed because the grant is gone rather than because
/// the request did not get through. Google answers a revoked or expired refresh
/// token with `invalid_grant`.
fn google_refresh_grant_rejected(err: &anyhow::Error) -> bool {
    format!("{err:#}").contains("invalid_grant")
}

/// What the user is told about a failed account. Google's raw JSON error body
/// says nothing anyone can act on, so a lost grant is reported as the reconnect
/// it actually is; everything else keeps the underlying error.
fn google_account_failure(
    account: &GoogleOAuthAccount,
    err: &anyhow::Error,
    authorization_rejected: bool,
) -> String {
    if authorization_rejected {
        return google_permission_denied_message(account);
    }
    format!(
        "{}: {err:#}",
        account.email.as_deref().unwrap_or(&account.account_id)
    )
}
