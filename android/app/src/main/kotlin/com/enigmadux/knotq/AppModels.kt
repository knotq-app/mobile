package com.enigmadux.knotq

import android.view.View
import android.widget.TextView
import java.net.HttpURLConnection
import java.io.InputStream
import java.net.URI
import org.json.JSONObject

// Small value types + onboarding step data shared across the MainActivity
// extension files, extracted from MainActivity. All internal (same module).

internal const val MAX_HTTP_RESPONSE_BYTES = 1L * 1024L * 1024L

/** Read a small JSON/control-plane response without allowing an untrusted peer to OOM the app. */
internal fun InputStream.readUtf8Capped(maxBytes: Long = MAX_HTTP_RESPONSE_BYTES): String =
    readBytesCapped(maxBytes).toString(Charsets.UTF_8)

/**
 * Sync credentials must never be sent to a plaintext or ambiguous endpoint.
 * Plain HTTP remains available only for local loopback workers used by tests.
 */
internal fun isSecureSyncApiBase(raw: String): Boolean {
    val normalized = raw.trim().trimEnd('/')
    if (normalized.isEmpty()) return false
    val uri = runCatching { URI(normalized) }.getOrNull() ?: return false
    if (uri.userInfo != null || uri.query != null || uri.fragment != null) return false
    val host = uri.host?.lowercase() ?: return false
    return when (uri.scheme?.lowercase()) {
        "https" -> true
        "http" -> host.trim('[', ']') in setOf("127.0.0.1", "localhost", "::1")
        else -> false
    }
}

internal fun MainActivity.validatedSyncApiBase(raw: String): String {
    val normalized = normalizeApiBase(raw)
    if (!isSecureSyncApiBase(normalized)) {
        throw IllegalArgumentException(L10n.t(this, "sync.error.api_url_https_required"))
    }
    return normalized
}

internal fun refreshApiErrorCode(connection: HttpURLConnection): String {
    val raw = connection.errorStream?.use { it.readUtf8Capped() }.orEmpty()
    return runCatching { JSONObject(raw).optString("code") }.getOrDefault("")
}

internal fun isTerminalRefreshErrorCode(code: String): Boolean =
    code == "invalid_refresh_token" ||
        code == "refresh_token_reused" ||
        code == "account_closed"

// A guided-tour step: navigates to `tab` (opening the first scheme for SCHEMES,
// ensuring today's queue for DAILY) and, when `ringsContent`, spotlights the main
// content area behind the scrim. Welcome is a centered intro with no cutout.
internal data class OnboardingStepDef(
    val title: String,
    val body: String,
    val tab: Int,
    val ringsContent: Boolean
)

internal val ONBOARDING_STEPS = listOf(
    OnboardingStepDef(
        "Welcome to KnotQ",
        "KnotQ is a single app for calendar events, reminders, assignments, and general notes. It aims to be simple yet functional.",
        TAB_HOME,
        ringsContent = false
    ),
    OnboardingStepDef(
        "Calendar",
        "Your calendar holds events, assignments, and reminders. Long-press to add a task.",
        TAB_CALENDAR,
        ringsContent = true
    ),
    OnboardingStepDef(
        "Schemes",
        "Schemes are editable outlines for projects, notes, and plans. Add start and end times to any line to turn it into a calendar item.",
        TAB_SCHEMES,
        ringsContent = true
    ),
    OnboardingStepDef(
        "Daily",
        "Daily is a special, default scheme. Write an optimistic task list each day and check off the ones you complete.",
        TAB_DAILY,
        ringsContent = true
    ),
    OnboardingStepDef(
        "Upcoming",
        "Upcoming gathers nearby events, assignments, and reminders. You can mark tasks complete right from here.",
        TAB_HOME,
        ringsContent = true
    )
)

/**
 * Restored UI state can outlive a tutorial revision. Keep all consumers on a
 * valid step rather than allowing an old negative or too-large index to crash
 * the overlay while the activity is being recreated.
 */
internal fun clampedOnboardingStep(step: Int, stepCount: Int): Int {
    if (stepCount <= 0) return 0
    return step.coerceIn(0, stepCount - 1)
}

internal data class SyncSession(
    val apiBase: String,
    val userId: String,
    val email: String,
    val supportsSync: Boolean,
    // Short-lived access token; `expiresAt` is its expiry.
    val bearerToken: String,
    val expiresAt: String,
    // Long-lived, rotated-on-refresh credential and its (sliding) expiry.
    val refreshToken: String,
    val refreshExpiresAt: String? = null
)

internal data class SyncLoginChallenge(
    val apiBase: String,
    val email: String,
    val challengeId: String,
    val devCode: String?
)

internal data class SyncLoginStart(
    val challenge: SyncLoginChallenge?,
    val session: SyncSession?
)

internal sealed interface SyncRefreshResult {
    class Ready(val session: SyncSession) : SyncRefreshResult
    object Deferred : SyncRefreshResult
    object SessionDead : SyncRefreshResult
}

internal data class PendingSyncBrowserAuth(
    val apiBase: String,
    val state: String,
    val codeVerifier: String
)

internal data class FolderDestination(val id: String, val name: String, val depth: Int)
internal data class NavRowMeta(
    val node: JSONObject,
    val id: String,
    val kind: String,
    val parentId: String,
    val siblingIndex: Int,
    val depth: Int,
    val childCount: Int
)
internal data class DialogField(val view: View, val label: TextView, val value: TextView)
