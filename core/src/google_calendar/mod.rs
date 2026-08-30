use std::collections::{HashMap, HashSet};
use std::time::Duration as StdDuration;

use anyhow::{anyhow, bail, Context as _, Result};
use base64::Engine as _;
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use knotq_model::{
    CalendarDateTime, CalendarProvider, ExternalItemSource, GoogleOAuthAccount, GoogleTokenSource,
    ImportedCalendarSource, Item, ItemMarker, NodeRef, Recurrence, Scheme, SchemeId, SchemeSource,
    Workspace,
};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::{MobileGoogleAuthRequest, MobileGoogleIdentityAccount};

mod apply;
mod http;
mod oauth;
mod sync;
mod types;

pub(crate) use apply::{
    apply_google_calendar_items, apply_google_calendar_metadata,
    archived_google_calendar_scheme_id, google_calendar_source,
};
pub(crate) use oauth::{
    google_auth_request, google_platform_token_expiry as platform_token_expiry,
};
pub(crate) use sync::{
    google_calendar_scheme_ids, google_calendar_sources, run_google_calendar_background_sync,
    run_google_calendar_import_from_callback, run_google_calendar_import_with_identity,
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
    GoogleTokenResponse, GoogleUserInfo,
};

const GOOGLE_AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
// OpenID userinfo. A platform-issued access token carrying `openid`+`email` is
// all we get from Google Identity on Android (there is no id_token), so the
// stable `sub` that identifies the account is read back from here — the same
// subject the desktop/iOS flows pull out of their id_token.
const GOOGLE_USERINFO_URL: &str = "https://www.googleapis.com/oauth2/v3/userinfo";
const GOOGLE_CALENDAR_LIST_URL: &str =
    "https://www.googleapis.com/calendar/v3/users/me/calendarList";
const GOOGLE_EVENTS_BASE_URL: &str = "https://www.googleapis.com/calendar/v3/calendars";
// How long a platform-issued access token is assumed usable when the identity
// service does not report a lifetime (Play Services does not). Google's tokens
// last about an hour; this only has to cover the sync run that the shell just
// fetched the token for, so it is deliberately short — an expired assumption
// costs one reconnect prompt, an over-long one costs silent 401s.
const GOOGLE_PLATFORM_TOKEN_ASSUMED_TTL_SECS: i64 = 300;
const GOOGLE_OAUTH_SCOPES: &[&str] = &[
    "openid",
    "email",
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly",
];
/// Calendar reads the import cannot work without, each paired with the broader
/// scopes Google treats as covering it — an account linked back when KnotQ asked
/// for `calendar.readonly` keeps working without another consent round.
const GOOGLE_REQUIRED_CALENDAR_SCOPES: &[(&str, &[&str])] = &[
    (
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        &[
            "https://www.googleapis.com/auth/calendar.calendarlist",
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/calendar",
        ],
    ),
    (
        "https://www.googleapis.com/auth/calendar.events.readonly",
        &[
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/calendar",
        ],
    ),
];

/// The calendar scopes KnotQ asked for that a grant does not actually cover.
///
/// Google's consent screen lists each calendar permission as its own checkbox,
/// and a user can finish the flow having ticked none of them: the exchange still
/// succeeds, with `openid`/`email` alone, and every Calendar call afterwards
/// fails with `ACCESS_TOKEN_SCOPE_INSUFFICIENT`. Comparing what was granted
/// against what is needed is what turns that into something the user can act on.
pub(crate) fn missing_google_calendar_scopes(granted: &str) -> Vec<&'static str> {
    let granted = granted.split_whitespace().collect::<HashSet<_>>();
    GOOGLE_REQUIRED_CALENDAR_SCOPES
        .iter()
        .filter(|(scope, broader)| {
            !granted.contains(scope) && !broader.iter().any(|scope| granted.contains(scope))
        })
        .map(|(scope, _)| *scope)
        .collect()
}

/// The message shown when an account's grant no longer covers the import.
pub(crate) fn google_permission_denied_message(account: &GoogleOAuthAccount) -> String {
    let label = account.email.as_deref().unwrap_or(&account.account_id);
    knotq_l10n::t_with(
        "google.calendar.error.permission_denied",
        &[("account", label)],
    )
}
