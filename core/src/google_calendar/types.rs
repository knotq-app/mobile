use super::*;

#[derive(Clone)]
pub(crate) struct GoogleOAuthConfig {
    pub(crate) client_id: String,
}

#[derive(Clone)]
pub(crate) struct ExistingGoogleCalendarSource {
    pub(super) account_id: String,
    pub(super) calendar_id: String,
    pub(super) sync_token: Option<String>,
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
    pub(crate) recurrence_exdates: Vec<GoogleRecurrenceExdate>,
}

#[derive(Clone, Copy)]
pub(super) enum GoogleCalendarImportMode {
    MissingOnly,
    ExistingOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GoogleExternalEventKey {
    pub(super) event_id: String,
    pub(super) instance_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GoogleRecurrenceExdate {
    pub(super) event_id: String,
    pub(super) original_start: CalendarDateTime,
}

#[derive(Deserialize)]
pub(super) struct GoogleTokenResponse {
    pub(super) access_token: String,
    pub(super) expires_in: Option<i64>,
    pub(super) refresh_token: Option<String>,
    pub(super) scope: Option<String>,
    pub(super) id_token: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct GoogleIdClaims {
    pub(super) sub: Option<String>,
    pub(super) email: Option<String>,
}

/// OpenID `userinfo` response. Used to recover a stable account identity from a
/// bare access token, which is all a platform identity service hands back.
#[derive(Deserialize)]
pub(super) struct GoogleUserInfo {
    pub(super) sub: Option<String>,
    pub(super) email: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoogleCalendarListResponse {
    pub(super) next_page_token: Option<String>,
    pub(super) items: Vec<GoogleCalendarListEntry>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoogleCalendarListEntry {
    pub(super) id: String,
    pub(super) summary: Option<String>,
    pub(super) summary_override: Option<String>,
    pub(super) background_color: Option<String>,
    pub(super) hidden: Option<bool>,
    pub(super) selected: Option<bool>,
    pub(super) deleted: Option<bool>,
    pub(super) primary: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoogleEventsResponse {
    pub(super) next_page_token: Option<String>,
    pub(super) next_sync_token: Option<String>,
    pub(super) items: Vec<GoogleEvent>,
}

#[derive(Clone, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoogleEvent {
    pub(super) id: String,
    pub(super) status: Option<String>,
    pub(super) summary: Option<String>,
    pub(super) start: Option<GoogleEventDateTime>,
    pub(super) end: Option<GoogleEventDateTime>,
    pub(super) updated: Option<DateTime<Utc>>,
    pub(super) recurrence: Option<Vec<String>>,
    pub(super) recurring_event_id: Option<String>,
    pub(super) original_start_time: Option<GoogleEventDateTime>,
}

#[derive(Clone, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoogleEventDateTime {
    pub(super) date: Option<NaiveDate>,
    pub(super) date_time: Option<DateTime<Utc>>,
}

#[derive(Debug)]
pub(super) struct GoogleApiError {
    pub(super) status: Option<u16>,
    pub(super) message: String,
}

impl std::fmt::Display for GoogleApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for GoogleApiError {}

pub(super) struct GoogleEventsSync {
    pub(super) events: Vec<GoogleEvent>,
    pub(super) sync_token: Option<String>,
    pub(super) full_sync: bool,
}
