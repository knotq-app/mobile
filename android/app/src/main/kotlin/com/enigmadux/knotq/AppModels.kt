package com.enigmadux.knotq

import android.view.View
import android.widget.TextView
import java.net.HttpURLConnection
import org.json.JSONObject

// Small value types + onboarding step data shared across the MainActivity
// extension files, extracted from MainActivity. All internal (same module).

internal fun refreshApiErrorCode(connection: HttpURLConnection): String {
    val raw = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
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
        "Your calendar holds events, assignments, and reminders. Tap to add a reminder, long-press for an assignment, or drag to block out an event.",
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
