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

mod apply;
mod http;
mod oauth;
mod sync;
mod types;

pub(crate) use apply::{
    apply_google_calendar_items, apply_google_calendar_metadata, google_calendar_source,
};
pub(crate) use oauth::google_auth_request;
pub(crate) use sync::{
    google_calendar_scheme_ids, google_calendar_sources, run_google_calendar_background_sync,
    run_google_calendar_import_from_callback,
};
pub(crate) use types::{
    ExistingGoogleCalendarSource, GoogleCalendarImportResult, GoogleExternalEventKey,
    GoogleOAuthConfig, GoogleRecurrenceExdate, ImportedGoogleCalendar,
};

// Re-export the internal items submodules share with one another so that each
// submodule can `use super::*` and resolve sibling symbols.
use apply::{
    collect_google_calendar_scheme_ids, google_calendar_color_index, google_calendar_name,
    google_calendar_scheme_matches, google_event_key, google_events_to_items,
    google_recurring_exception_exdates, sort_imported_items,
};
use http::{google_http_error, list_google_calendars, list_google_events};
use oauth::{
    query_encode, refresh_google_access_token_if_needed, run_google_oauth_callback, with_query,
};
use types::{
    GoogleApiError, GoogleCalendarImportMode, GoogleCalendarListEntry, GoogleCalendarListResponse,
    GoogleEvent, GoogleEventDateTime, GoogleEventsResponse, GoogleEventsSync, GoogleIdClaims,
    GoogleTokenResponse,
};

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
