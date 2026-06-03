use std::collections::{HashMap, HashSet};
use std::time::Duration as StdDuration;

use anyhow::{anyhow, bail, Context as _, Result};
use base64::Engine as _;
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use knotq_model::{
    CalendarDateTime, CalendarProvider, ExternalItemSource, GoogleOAuthAccount,
    ImportedCalendarSource, Item, ItemMarker, NodeRef, Recurrence, Scheme, SchemeId, SchemeSource,
    Workspace,
};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::MobileGoogleAuthRequest;

const GOOGLE_AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const GOOGLE_CALENDAR_LIST_URL: &str =
    "https://www.googleapis.com/calendar/v3/users/me/calendarList";
const GOOGLE_EVENTS_BASE_URL: &str = "https://www.googleapis.com/calendar/v3/calendars";
const GOOGLE_OAUTH_SCOPES: &[&str] = &[
    "openid",
    "email",
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly",
];

#[derive(Clone)]
pub(crate) struct GoogleOAuthConfig {
    pub(crate) client_id: String,
    pub(crate) client_secret: Option<String>,
}

#[derive(Clone)]
pub(crate) struct ExistingGoogleCalendarSource {
    account_id: String,
    calendar_id: String,
    sync_token: Option<String>,
}

pub(crate) struct GoogleCalendarImportResult {
    pub(crate) accounts: Vec<GoogleOAuthAccount>,
    pub(crate) calendars: Vec<ImportedGoogleCalendar>,
    pub(crate) failures: Vec<String>,
}

pub(crate) struct ImportedGoogleCalendar {
    pub(crate) account_id: String,
    pub(crate) account_email: Option<String>,
    pub(crate) calendar_id: String,
    pub(crate) name: String,
    pub(crate) color_index: u8,
    pub(crate) sync_token: Option<String>,
    pub(crate) full_sync: bool,
    pub(crate) items: Vec<Item>,
    pub(crate) deleted: Vec<GoogleExternalEventKey>,
}

#[derive(Clone, Copy)]
enum GoogleCalendarImportMode {
    MissingOnly,
    ExistingOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GoogleExternalEventKey {
    event_id: String,
    instance_id: Option<String>,
}

#[derive(Deserialize)]
struct GoogleTokenResponse {
    access_token: String,
    expires_in: Option<i64>,
    refresh_token: Option<String>,
    scope: Option<String>,
    id_token: Option<String>,
}

#[derive(Deserialize)]
struct GoogleIdClaims {
    sub: Option<String>,
    email: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleCalendarListResponse {
    next_page_token: Option<String>,
    items: Vec<GoogleCalendarListEntry>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleCalendarListEntry {
    id: String,
    summary: Option<String>,
    summary_override: Option<String>,
    background_color: Option<String>,
    hidden: Option<bool>,
    selected: Option<bool>,
    deleted: Option<bool>,
    primary: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleEventsResponse {
    next_page_token: Option<String>,
    next_sync_token: Option<String>,
    items: Vec<GoogleEvent>,
}

#[derive(Clone, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct GoogleEvent {
    id: String,
    status: Option<String>,
    summary: Option<String>,
    start: Option<GoogleEventDateTime>,
    end: Option<GoogleEventDateTime>,
    updated: Option<DateTime<Utc>>,
    recurrence: Option<Vec<String>>,
    recurring_event_id: Option<String>,
}

#[derive(Clone, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct GoogleEventDateTime {
    date: Option<NaiveDate>,
    date_time: Option<DateTime<Utc>>,
}

#[derive(Debug)]
struct GoogleApiError {
    status: Option<u16>,
    message: String,
}

impl std::fmt::Display for GoogleApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for GoogleApiError {}

pub(crate) fn google_auth_request(
    client_id: String,
    redirect_uri: String,
) -> MobileGoogleAuthRequest {
    let state = random_token(32);
    let code_verifier = random_token(96);
    let code_challenge = code_challenge(&code_verifier);
    let scope = GOOGLE_OAUTH_SCOPES.join(" ");
    let auth_url = google_auth_url(&client_id, &redirect_uri, &scope, &state, &code_challenge);
    MobileGoogleAuthRequest {
        auth_url,
        state,
        code_verifier,
        redirect_uri,
        scope,
        client_id,
    }
}

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
        config,
        vec![account],
        existing_sources,
        GoogleCalendarImportMode::MissingOnly,
    )
}

pub(crate) fn run_google_calendar_background_sync(
    config: GoogleOAuthConfig,
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
        config,
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

fn run_google_oauth_callback(
    config: GoogleOAuthConfig,
    redirect_uri: &str,
    expected_state: &str,
    code_verifier: &str,
    callback_url: &str,
) -> Result<GoogleOAuthAccount> {
    let params = query_params(callback_url)?;
    if params.get("state").map(String::as_str) != Some(expected_state) {
        bail!("Google OAuth returned an unexpected state");
    }
    if let Some(error) = params.get("error") {
        bail!("Google OAuth error: {error}");
    }
    let code = params
        .get("code")
        .cloned()
        .ok_or_else(|| anyhow!("Google OAuth callback did not include a code"))?;
    let token = exchange_auth_code(&config, redirect_uri, &code, code_verifier)?;
    let refresh_token = token
        .refresh_token
        .clone()
        .ok_or_else(|| anyhow!("Google did not return a refresh token"))?;
    let claims = token.id_token.as_deref().and_then(decode_id_token_claims);
    let account_id = claims
        .as_ref()
        .and_then(|claims| claims.sub.clone())
        .or_else(|| claims.as_ref().and_then(|claims| claims.email.clone()))
        .unwrap_or_else(|| "google".to_string());
    let expires_at = token
        .expires_in
        .map(|seconds| Utc::now() + Duration::seconds(seconds));

    Ok(GoogleOAuthAccount {
        account_id,
        email: claims.and_then(|claims| claims.email),
        client_id: config.client_id,
        access_token: token.access_token,
        refresh_token,
        expires_at,
        scope: token.scope.unwrap_or_else(|| GOOGLE_OAUTH_SCOPES.join(" ")),
    })
}

fn run_google_calendar_sync(
    config: GoogleOAuthConfig,
    accounts: Vec<GoogleOAuthAccount>,
    existing_sources: Vec<ExistingGoogleCalendarSource>,
    mode: GoogleCalendarImportMode,
) -> Result<GoogleCalendarImportResult> {
    let mut updated_accounts = Vec::new();
    let mut calendars = Vec::new();
    let mut failures = Vec::new();

    for mut account in accounts {
        if let Err(err) = refresh_google_access_token_if_needed(&config, &mut account) {
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

struct GoogleEventsSync {
    events: Vec<GoogleEvent>,
    sync_token: Option<String>,
    full_sync: bool,
}

fn list_google_calendars(access_token: &str) -> Result<Vec<GoogleCalendarListEntry>> {
    let mut page_token: Option<String> = None;
    let mut calendars = Vec::new();

    loop {
        let mut params = vec![
            ("maxResults", "250".to_string()),
            ("minAccessRole", "reader".to_string()),
        ];
        if let Some(token) = &page_token {
            params.push(("pageToken", token.clone()));
        }
        let url = with_query(GOOGLE_CALENDAR_LIST_URL, &params);
        let response: GoogleCalendarListResponse = google_get_json(&url, access_token)?;
        calendars.extend(
            response
                .items
                .into_iter()
                .filter(|calendar| calendar.deleted != Some(true) && calendar.hidden != Some(true)),
        );
        page_token = response.next_page_token;
        if page_token.is_none() {
            break;
        }
    }

    let visible = calendars
        .iter()
        .filter(|calendar| calendar.selected != Some(false) || calendar.primary == Some(true))
        .cloned()
        .collect::<Vec<_>>();
    if visible.is_empty() {
        Ok(calendars)
    } else {
        Ok(visible)
    }
}

fn list_google_events(
    access_token: &str,
    calendar_id: &str,
    sync_token: Option<String>,
) -> Result<GoogleEventsSync> {
    match list_google_events_once(access_token, calendar_id, sync_token.clone()) {
        Ok(events) => Ok(events),
        Err(err) if err.status == Some(410) && sync_token.is_some() => {
            Ok(list_google_events_once(access_token, calendar_id, None)?)
        }
        Err(err) => Err(anyhow!(err)),
    }
}

fn list_google_events_once(
    access_token: &str,
    calendar_id: &str,
    sync_token: Option<String>,
) -> std::result::Result<GoogleEventsSync, GoogleApiError> {
    let base = format!(
        "{GOOGLE_EVENTS_BASE_URL}/{}/events",
        query_encode(calendar_id)
    );
    let mut page_token: Option<String> = None;
    let full_sync = sync_token.is_none();
    let mut events = Vec::new();
    let mut next_sync_token = sync_token.clone();

    loop {
        let mut params = vec![
            ("maxResults", "2500".to_string()),
            ("singleEvents", "false".to_string()),
        ];
        if let Some(token) = &sync_token {
            params.push(("syncToken", token.clone()));
            params.push(("showDeleted", "true".to_string()));
        } else {
            params.push(("showDeleted", "false".to_string()));
        }
        if let Some(token) = &page_token {
            params.push(("pageToken", token.clone()));
        }

        let url = with_query(&base, &params);
        let response: GoogleEventsResponse = google_get_json(&url, access_token)?;
        events.extend(response.items);
        if let Some(token) = response.next_sync_token {
            next_sync_token = Some(token);
        }
        page_token = response.next_page_token;
        if page_token.is_none() {
            break;
        }
    }

    Ok(GoogleEventsSync {
        events,
        sync_token: next_sync_token,
        full_sync,
    })
}

fn exchange_auth_code(
    config: &GoogleOAuthConfig,
    redirect_uri: &str,
    code: &str,
    code_verifier: &str,
) -> Result<GoogleTokenResponse> {
    let mut form = vec![
        ("client_id", config.client_id.as_str()),
        ("code", code),
        ("code_verifier", code_verifier),
        ("grant_type", "authorization_code"),
        ("redirect_uri", redirect_uri),
    ];
    if let Some(secret) = &config.client_secret {
        form.push(("client_secret", secret.as_str()));
    }

    ureq::post(GOOGLE_TOKEN_URL)
        .timeout(StdDuration::from_secs(30))
        .send_form(&form)
        .map_err(google_http_error)?
        .into_json::<GoogleTokenResponse>()
        .context("parse Google OAuth token response")
}

fn refresh_google_access_token_if_needed(
    config: &GoogleOAuthConfig,
    account: &mut GoogleOAuthAccount,
) -> Result<()> {
    let still_valid = account
        .expires_at
        .is_some_and(|expires_at| expires_at > Utc::now() + Duration::seconds(60));
    if still_valid {
        return Ok(());
    }

    let mut form = vec![
        ("client_id", account.client_id.as_str()),
        ("grant_type", "refresh_token"),
        ("refresh_token", account.refresh_token.as_str()),
    ];
    if let Some(secret) = &config.client_secret {
        form.push(("client_secret", secret.as_str()));
    }

    let token = ureq::post(GOOGLE_TOKEN_URL)
        .timeout(StdDuration::from_secs(30))
        .send_form(&form)
        .map_err(google_http_error)?
        .into_json::<GoogleTokenResponse>()
        .context("parse Google OAuth refresh response")?;

    account.access_token = token.access_token;
    account.expires_at = token
        .expires_in
        .map(|seconds| Utc::now() + Duration::seconds(seconds));
    if let Some(scope) = token.scope {
        account.scope = scope;
    }
    Ok(())
}

fn google_get_json<T: DeserializeOwned>(
    url: &str,
    access_token: &str,
) -> std::result::Result<T, GoogleApiError> {
    let auth = format!("Bearer {access_token}");
    let response = ureq::get(url)
        .timeout(StdDuration::from_secs(30))
        .set("Authorization", &auth)
        .call()
        .map_err(google_api_error)?;
    response.into_json::<T>().map_err(|err| GoogleApiError {
        status: None,
        message: format!("parse Google Calendar response: {err}"),
    })
}

fn google_api_error(err: ureq::Error) -> GoogleApiError {
    match err {
        ureq::Error::Status(status, response) => {
            let body = response.into_string().unwrap_or_default();
            GoogleApiError {
                status: Some(status),
                message: format!("Google Calendar HTTP {status}: {body}"),
            }
        }
        ureq::Error::Transport(err) => GoogleApiError {
            status: None,
            message: format!("Google Calendar request failed: {err}"),
        },
    }
}

fn google_http_error(err: ureq::Error) -> anyhow::Error {
    match err {
        ureq::Error::Status(status, response) => {
            let body = response.into_string().unwrap_or_default();
            anyhow!("Google OAuth HTTP {status}: {body}")
        }
        ureq::Error::Transport(err) => anyhow!("Google OAuth request failed: {err}"),
    }
}

fn google_auth_url(
    client_id: &str,
    redirect_uri: &str,
    scope: &str,
    state: &str,
    code_challenge: &str,
) -> String {
    with_query(
        GOOGLE_AUTH_URL,
        &[
            ("client_id", client_id.to_string()),
            ("redirect_uri", redirect_uri.to_string()),
            ("response_type", "code".to_string()),
            ("scope", scope.to_string()),
            ("state", state.to_string()),
            ("code_challenge", code_challenge.to_string()),
            ("code_challenge_method", "S256".to_string()),
            ("access_type", "offline".to_string()),
            ("prompt", "consent".to_string()),
        ],
    )
}

fn random_token(target_len: usize) -> String {
    let mut out = String::new();
    while out.len() < target_len {
        out.push_str(&uuid::Uuid::new_v4().simple().to_string());
    }
    out.truncate(target_len);
    out
}

fn code_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

fn decode_id_token_claims(id_token: &str) -> Option<GoogleIdClaims> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn query_params(url: &str) -> Result<HashMap<String, String>> {
    let query = url
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or("")
        .split('#')
        .next()
        .unwrap_or("");
    let mut params = HashMap::new();
    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        params.insert(query_decode(key)?, query_decode(value)?);
    }
    Ok(params)
}

fn with_query(base: &str, params: &[(&str, String)]) -> String {
    if params.is_empty() {
        return base.to_string();
    }
    let query = params
        .iter()
        .map(|(key, value)| format!("{key}={}", query_encode(value)))
        .collect::<Vec<_>>()
        .join("&");
    format!("{base}?{query}")
}

fn query_encode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn query_decode(value: &str) -> Result<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3])?;
                out.push(u8::from_str_radix(hex, 16)?);
                i += 3;
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    Ok(String::from_utf8(out)?)
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
    left.text == right.text
        && left.media == right.media
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

fn collect_google_calendar_scheme_ids(
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

fn google_calendar_scheme_matches(
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

fn google_event_to_item(
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

fn google_event_key(event: &GoogleEvent) -> GoogleExternalEventKey {
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

fn sort_imported_items(items: &mut [Item]) {
    items.sort_by(|left, right| {
        let left_date = left.start.or(left.end);
        let right_date = right.start.or(right.end);
        left_date
            .cmp(&right_date)
            .then_with(|| left.text.cmp(&right.text))
            .then_with(|| left.id.0.cmp(&right.id.0))
    });
}

fn google_calendar_name(calendar: &GoogleCalendarListEntry) -> String {
    calendar
        .summary_override
        .as_deref()
        .or(calendar.summary.as_deref())
        .filter(|summary| !summary.trim().is_empty())
        .unwrap_or("Google Calendar")
        .to_string()
}

fn google_calendar_color_index(background: Option<&str>, fallback: usize) -> u8 {
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
