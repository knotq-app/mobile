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
