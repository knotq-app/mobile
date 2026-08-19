use super::*;

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

pub(super) fn run_google_oauth_callback(
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
    // Google reports what the user actually ticked, which can be less than what
    // was asked for. Linking an account whose grant cannot even list a calendar
    // only buys a stack of API errors later, so refuse it here instead.
    let granted_scope = token
        .scope
        .clone()
        .unwrap_or_else(|| GOOGLE_OAUTH_SCOPES.join(" "));
    if !missing_google_calendar_scopes(&granted_scope).is_empty() {
        bail!(knotq_l10n::t("google.oauth.error.calendar_scope_denied"));
    }
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
        scope: granted_scope,
        // The iOS/desktop browser flow ends with a refresh token in hand, so
        // the core renews this account's access tokens on its own.
        token_source: GoogleTokenSource::OAuthRefreshToken,
        needs_reauth: false,
    })
}

/// Builds (or updates) an account entry from a token issued by a platform
/// identity service rather than by our own OAuth exchange.
///
/// Android is the only caller today: Google blocks the loopback flow there, and
/// `AuthorizationClient` hands back a bare access token with no id_token and no
/// refresh token. The stable subject is recovered from the OpenID `userinfo`
/// endpoint so the account lands on the same `account_id` the other platforms
/// would record, keeping one account identity across devices.
pub(super) fn google_identity_account(
    identity: &MobileGoogleIdentityAccount,
) -> Result<GoogleOAuthAccount> {
    let access_token = identity.access_token.trim();
    if access_token.is_empty() {
        bail!("Google Identity did not return an access token");
    }
    let info = resolve_google_identity(access_token)?;
    let email = info
        .email
        .or_else(|| identity.email.clone())
        .filter(|email| !email.trim().is_empty());
    let account_id = info
        .sub
        .filter(|sub| !sub.trim().is_empty())
        .or_else(|| email.clone())
        .ok_or_else(|| anyhow!("Google Identity did not return an account identity"))?;

    Ok(GoogleOAuthAccount {
        account_id,
        email,
        client_id: identity.client_id.clone(),
        access_token: access_token.to_string(),
        // Deliberately empty: there is no refresh token to store, and
        // `can_self_refresh()` keys off that to keep the core away from the
        // OAuth refresh endpoint for these accounts.
        refresh_token: String::new(),
        expires_at: Some(google_platform_token_expiry(identity.expires_in_secs)),
        scope: identity
            .scope
            .clone()
            .filter(|scope| !scope.trim().is_empty())
            .unwrap_or_else(|| GOOGLE_OAUTH_SCOPES.join(" ")),
        token_source: GoogleTokenSource::PlatformIdentity,
        needs_reauth: false,
    })
}

/// When a platform-issued access token should be treated as spent.
///
/// The identity service is the only thing that can renew these, so the core must
/// not hold one past its life; when no lifetime is reported, assume a short one
/// rather than none at all — an account with no expiry at all would be refused
/// by `refresh_google_access_token_if_needed` the moment it was stored.
pub(crate) fn google_platform_token_expiry(expires_in_secs: Option<i64>) -> DateTime<Utc> {
    let seconds = expires_in_secs
        .filter(|seconds| *seconds > 0)
        .unwrap_or(GOOGLE_PLATFORM_TOKEN_ASSUMED_TTL_SECS);
    Utc::now() + Duration::seconds(seconds)
}

/// Reads the OpenID subject/email behind a platform-issued access token. The
/// token must carry the `openid` and `email` scopes.
pub(super) fn resolve_google_identity(access_token: &str) -> Result<GoogleUserInfo> {
    ureq::get(GOOGLE_USERINFO_URL)
        .timeout(StdDuration::from_secs(30))
        .set("Authorization", &format!("Bearer {access_token}"))
        .call()
        .map_err(google_http_error)?
        .into_json::<GoogleUserInfo>()
        .context("parse Google userinfo response")
}

pub(super) fn exchange_auth_code(
    config: &GoogleOAuthConfig,
    redirect_uri: &str,
    code: &str,
    code_verifier: &str,
) -> Result<GoogleTokenResponse> {
    let form = vec![
        ("client_id", config.client_id.as_str()),
        ("code", code),
        ("code_verifier", code_verifier),
        ("grant_type", "authorization_code"),
        ("redirect_uri", redirect_uri),
    ];

    ureq::post(GOOGLE_TOKEN_URL)
        .timeout(StdDuration::from_secs(30))
        .send_form(&form)
        .map_err(google_http_error)?
        .into_json::<GoogleTokenResponse>()
        .context("parse Google OAuth token response")
}

pub(super) fn refresh_google_access_token_if_needed(
    account: &mut GoogleOAuthAccount,
) -> Result<()> {
    let still_valid = account
        .expires_at
        .is_some_and(|expires_at| expires_at > Utc::now() + Duration::seconds(60));
    if still_valid {
        return Ok(());
    }

    // Platform-identity accounts (Android Google Identity) have no refresh
    // token: the shell hands the core a fresh access token before each sync.
    // Posting to the refresh endpoint with an empty token would just be a
    // guaranteed 400, so surface the reconnect state instead.
    // Unlabelled on purpose: the caller prefixes the account it is reporting,
    // and prefixing here too produced "user@example.com: user@example.com: ...".
    if !account.can_self_refresh() {
        bail!(knotq_l10n::t("google.calendar.reconnect_title"));
    }

    let form = vec![
        ("client_id", account.client_id.as_str()),
        ("grant_type", "refresh_token"),
        ("refresh_token", account.refresh_token.as_str()),
    ];

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
    // A grant can be narrowed after the fact from the user's Google account
    // page, and the refresh response is where that first shows up. A refresh
    // token cannot buy back a permission the user took away, so this is a
    // reconnect, not a retry.
    if !missing_google_calendar_scopes(&account.scope).is_empty() {
        account.needs_reauth = true;
        bail!(google_permission_denied_message(account));
    }
    account.needs_reauth = false;
    Ok(())
}

pub(super) fn google_auth_url(
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

pub(super) fn random_token(target_len: usize) -> String {
    let mut out = String::new();
    while out.len() < target_len {
        out.push_str(&uuid::Uuid::new_v4().simple().to_string());
    }
    out.truncate(target_len);
    out
}

pub(super) fn code_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

pub(super) fn decode_id_token_claims(id_token: &str) -> Option<GoogleIdClaims> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub(super) fn query_params(url: &str) -> Result<HashMap<String, String>> {
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

pub(super) fn with_query(base: &str, params: &[(&str, String)]) -> String {
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

pub(super) fn query_encode(value: &str) -> String {
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

pub(super) fn query_decode(value: &str) -> Result<String> {
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
