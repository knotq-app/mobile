package com.enigmadux.knotq

// App-wide constants for the Android shell, extracted from MainActivity. Kept
// internal so the MainActivity extension files (same module) can reference them.

internal const val SYNC_SESSION_PREF = "knotq.localSyncSession"
internal const val BACKGROUND_SYNC_WORK = "knotq-background-sync"
internal const val PROD_SYNC_API_BASE = "https://api.knotq.com"
internal const val SANDBOX_SYNC_API_BASE = "https://sandbox.api.knotq.com"

// Base URL used for a *new* sign-in when no session is stored yet. The build-time
// KNOTQ_API_BASE override (see app/build.gradle) always wins; otherwise the
// default is build-aware — debug builds target the hosted sandbox so development
// never touches production, while release (Play) builds target production.
// Existing sessions keep their stored apiBase, so this never silently moves a
// signed-in account between environments.
internal fun defaultSyncApiBase(): String =
    BuildConfig.KNOTQ_API_BASE.ifBlank {
        if (BuildConfig.DEBUG) SANDBOX_SYNC_API_BASE else PROD_SYNC_API_BASE
    }
private const val PROD_WEB_BASE = "https://www.knotq.com"
private const val SANDBOX_WEB_BASE = "https://sandbox.knotq.com"

// The knotq.com site origin matching a sync API base, so a sandbox/local-dev
// build opens the sandbox site instead of production. The hosted sign-in and
// account pages also receive the API base via the allowlisted `?api=` param,
// which is what actually pins the backend (needed for local, where the site is
// the sandbox host but the API is the loopback Worker).
internal fun syncWebBase(apiBase: String): String =
    if (apiBase.contains("sandbox.api.knotq.com") ||
        apiBase.contains("127.0.0.1") ||
        apiBase.contains("localhost")
    ) {
        SANDBOX_WEB_BASE
    } else {
        PROD_WEB_BASE
    }
internal const val SYNC_SIGN_IN_REDIRECT_SCHEME = "knotq"
internal const val SYNC_SIGN_IN_REDIRECT_HOST = "auth-callback"
internal const val SYNC_SIGN_IN_REDIRECT_URI = "$SYNC_SIGN_IN_REDIRECT_SCHEME://$SYNC_SIGN_IN_REDIRECT_HOST"
internal const val SYNC_AUTH_API_BASE_PREF = "knotq.syncBrowserAuth.apiBase"
internal const val SYNC_AUTH_STATE_PREF = "knotq.syncBrowserAuth.state"
internal const val SYNC_AUTH_VERIFIER_PREF = "knotq.syncBrowserAuth.verifier"
// The Google Play subscription product id for hosted sync (Play Console).
// Matches the App Store Connect product id (AppModel.syncProductIDs on iOS) so
// both platforms share one product identifier.
internal const val SYNC_SUBSCRIPTION_PRODUCT_ID = "com.enigmadux.knotq.sync.monthly"
// Where store-managed subscriptions are re-enabled (auto-renew turned back on);
// neither the app nor our backend can flip that for Google/Apple.
internal const val PLAY_SUBSCRIPTIONS_URL = "https://play.google.com/store/account/subscriptions"
internal const val APPLE_SUBSCRIPTIONS_URL = "https://apps.apple.com/account/subscriptions"
// Desktop ("installed") OAuth client. Android drives a loopback-redirect PKCE flow
// (see startGoogleCalendarImport) rather than the iOS reverse-client-id custom scheme,
// so the redirect URI is minted at runtime as http://127.0.0.1:<port>; there is no
// static redirect constant and no client secret to embed.
internal const val GOOGLE_CLIENT_ID = "419826075228-mt7s13h76ftugo170gqs3l0q0plmldpq.apps.googleusercontent.com"
// How long the local loopback listener waits for the browser to redirect back before
// giving up on a Google sign-in attempt.
internal const val GOOGLE_OAUTH_LOOPBACK_TIMEOUT_MS = 300_000
internal const val GOOGLE_SYNC_INTERVAL_MS = 120_000L
// Debounce for the push that follows a local edit (mirrors iOS
// editSyncDebounceNanos): a burst of edits coalesces into one sync instead of
// pushing on every mutation. Desktop's sync service debounces local changes
// 30 s; the 30 s foreground poll and an onStop flush are the backstops here.
internal const val SYNC_EDIT_DEBOUNCE_MS = 5_000L
internal const val TAB_CALENDAR = 0
internal const val TAB_SCHEMES = 1
internal const val TAB_DAILY = 2
internal const val TAB_SEARCH = 3
internal const val TAB_SETTINGS = 4
internal const val TAB_HOME = 5

internal const val ICON_DOCK_SIZE_SP = 20f
internal const val ICON_CHIP_SIZE_SP = 13f
internal const val ICON_CHIP_WIDTH_DP = 32
internal const val ICON_CHIP_HEIGHT_DP = 28
internal const val ICON_SQUARE_SIZE_SP = 15f
internal const val ICON_TOOL_SIZE_SP = 13f
internal const val ICON_FORMAT_SIZE_SP = 12f
internal const val ICON_FORMAT_WIDTH_DP = 29
internal const val ICON_FORMAT_HEIGHT_DP = 27
internal const val ICON_FLOATING_SIZE_SP = 22f
internal const val ICON_FLOATING_WIDTH_DP = 56
internal const val ICON_FLOATING_VECTOR_SIZE_DP = 25
internal const val ICON_ROW_SIZE_SP = 16f
internal const val ICON_SEARCH_SIZE_SP = 17f
internal const val ICON_SEARCH_VECTOR_SIZE_DP = 19
internal const val ICON_DOCK_BUTTON_WIDTH_DP = 46
internal const val ICON_DOCK_BUTTON_HEIGHT_DP = 48
internal const val ICON_DOCK_VECTOR_SIZE_DP = 23

internal const val CALENDAR_INTERACTION_NONE = 0
internal const val CALENDAR_INTERACTION_DRAG = 1
internal const val CALENDAR_INTERACTION_CREATE = 2

internal const val REQUEST_ATTACH_IMAGE = 7311
internal const val REVIEW_FIRST_LAUNCH_AT_PREF = "knotq.reviewFirstLaunchAt.v1"
internal const val REVIEW_PROMPTED_PREF = "knotq.reviewPrompted.v1"
internal const val REVIEW_MIN_USAGE_MS = 14L * 24L * 60L * 60L * 1000L

internal const val GLYPH_HOME = "⌂"
internal const val GLYPH_CALENDAR = "◷"
internal const val GLYPH_SETTINGS = "⚙"
internal const val GLYPH_SEARCH = "⌕"
internal const val GLYPH_ADD = "＋"
internal const val GLYPH_EDIT = "✎"
internal const val GLYPH_TICK = "✓"
internal const val GLYPH_MORE = "⋯"
internal const val GLYPH_BULLET = "•"
internal const val GLYPH_NUMBERED = "1."
internal const val GLYPH_TEXT = "▢"
internal const val GLYPH_FOLDER = "🗀"
internal const val GLYPH_OUTDENT = "⇤"
internal const val GLYPH_INDENT = "⇥"
internal const val GLYPH_LEFT = "‹"
internal const val GLYPH_RIGHT = "›"
internal const val GLYPH_CHEVRON_LEFT = "‹"
internal const val GLYPH_CHEVRON_RIGHT = "›"
internal const val GLYPH_DOWN = "▾"
internal const val GLYPH_COMMIT = "⏎"
internal const val GLYPH_THEME_LIGHT = "☀"
internal const val GLYPH_THEME_DARK = "◐"
internal const val GLYPH_CLOCK = "◷"
internal const val GLYPH_BELL = "🔔"
internal const val GLYPH_CLOUD = "☁"

// First-run onboarding (mirrors the desktop/iOS spotlight tour). The flow has an
// account-choice phase followed by a guided tour that navigates into each pane and
// rings its content, rather than pointing at chrome.
internal const val ONBOARDING_PREF = "knotq.onboardingCompleted.v1"
internal const val ONBOARDING_ACCOUNT = 0
internal const val ONBOARDING_GUIDE = 1
