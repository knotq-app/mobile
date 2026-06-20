package com.enigmadux.knotq

// App-wide constants for the Android shell, extracted from MainActivity. Kept
// internal so the MainActivity extension files (same module) can reference them.

internal const val SYNC_SESSION_PREF = "knotq.localSyncSession"
internal const val BACKGROUND_SYNC_WORK = "knotq-background-sync"
internal const val DEFAULT_SYNC_API_BASE = "https://api.knotq.com"
internal const val SYNC_SIGN_IN_PAGE_URL = "https://www.knotq.com/signin.html"
internal const val SYNC_ACCOUNT_PAGE_URL = "https://www.knotq.com/account.html#signin"
internal const val SYNC_SIGN_IN_REDIRECT_SCHEME = "knotq"
internal const val SYNC_SIGN_IN_REDIRECT_HOST = "auth-callback"
internal const val SYNC_SIGN_IN_REDIRECT_URI = "$SYNC_SIGN_IN_REDIRECT_SCHEME://$SYNC_SIGN_IN_REDIRECT_HOST"
internal const val SYNC_AUTH_API_BASE_PREF = "knotq.syncBrowserAuth.apiBase"
internal const val SYNC_AUTH_STATE_PREF = "knotq.syncBrowserAuth.state"
internal const val SYNC_AUTH_VERIFIER_PREF = "knotq.syncBrowserAuth.verifier"
// The Google Play subscription product id for hosted sync (Play Console).
internal const val SYNC_SUBSCRIPTION_PRODUCT_ID = "knotq.sync.monthly"
// Where store-managed subscriptions are re-enabled (auto-renew turned back on);
// neither the app nor our backend can flip that for Google/Apple.
internal const val PLAY_SUBSCRIPTIONS_URL = "https://play.google.com/store/account/subscriptions"
internal const val APPLE_SUBSCRIPTIONS_URL = "https://apps.apple.com/account/subscriptions"
internal const val GOOGLE_CLIENT_ID = "419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld.apps.googleusercontent.com"
internal const val GOOGLE_REDIRECT_SCHEME = "com.googleusercontent.apps.419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld"
internal const val GOOGLE_REDIRECT_URI = "$GOOGLE_REDIRECT_SCHEME:/oauth2redirect"
internal const val GOOGLE_SYNC_INTERVAL_MS = 120_000L
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
