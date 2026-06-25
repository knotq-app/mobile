use super::*;

pub(super) fn list_google_calendars(access_token: &str) -> Result<Vec<GoogleCalendarListEntry>> {
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

pub(super) fn list_google_events(
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

pub(super) fn google_http_error(err: ureq::Error) -> anyhow::Error {
    match err {
        ureq::Error::Status(status, response) => {
            let body = response.into_string().unwrap_or_default();
            anyhow!("Google OAuth HTTP {status}: {body}")
        }
        ureq::Error::Transport(err) => anyhow!("Google OAuth request failed: {err}"),
    }
}
