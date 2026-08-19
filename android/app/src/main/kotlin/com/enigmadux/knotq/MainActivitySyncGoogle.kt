package com.enigmadux.knotq

import android.accounts.Account
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.AccountPicker
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.tasks.Tasks
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

// Google Calendar authorization on Android.
//
// Google blocks the loopback redirect flow on Android ("Error 400:
// invalid_request — The loopback flow has been blocked"), and neither a custom
// URI scheme nor any other browser-driven OAuth flow is a supported substitute
// there. The supported path is Google Identity Services: Play Services holds the
// user's Google accounts and issues short-lived access tokens for the scopes the
// user grants, with no redirect URI, no authorization code, and no client
// secret. The app is identified by package name + signing certificate.
//
// The consequence for the core is that Android never receives a refresh token,
// so it cannot renew an access token on its own the way desktop/iOS do. Instead
// the shell obtains a fresh token before each sync and hands it over through the
// `*_with_identity` core entry points; the core marks those accounts
// `PlatformIdentity` and never calls the OAuth refresh endpoint for them.

/** Why a Google authorization attempt did not produce a usable token. */
internal sealed class GoogleAuthorizationError(message: String) : Exception(message) {
    /** The user dismissed the consent screen. */
    object Canceled : GoogleAuthorizationError("Google Calendar authorization was canceled.")

    /** Google needs the user to grant (or re-grant) consent interactively. */
    object ConsentRequired :
        GoogleAuthorizationError("Google Calendar needs to be reconnected.")

    /** The scopes we need were not all granted. */
    object ScopesDeclined :
        GoogleAuthorizationError("KnotQ needs read access to your Google calendars.")

    /** No Google account is available on the device. */
    object NoAccount :
        GoogleAuthorizationError("Add a Google account to this device, then try again.")
}

internal fun MainActivity.startGoogleCalendarImport(parentId: String? = null) {
    if (googleAuthInProgress) return
    val unavailable = googlePlayServicesProblem()
    if (unavailable != null) {
        showError("Google Calendar", unavailable)
        return
    }

    // Adding a *second* account has to start by asking which one. Play Services
    // answers an authorization request for an account it has already authorized
    // without showing anything, so without this step "Connect another account"
    // silently re-links the account that is already connected and looks like it
    // did nothing but resync.
    if (connectedGoogleAccounts().length() > 0) {
        pendingGoogleParentId = parentId
        if (chooseGoogleAccount()) return
        // No chooser on this device: fall through and let Play Services pick.
        pendingGoogleParentId = null
    }

    beginGoogleCalendarImport(accountEmail = null, parentId = parentId)
}

/**
 * Runs the authorization + link for one account, showing consent when Google
 * asks for it. [accountEmail] pins the account the user picked; null lets Play
 * Services choose, which is what a first link wants.
 */
private fun MainActivity.beginGoogleCalendarImport(accountEmail: String?, parentId: String?) {
    googleAuthInProgress = true
    pendingGoogleParentId = parentId
    render()

    // A link always needs the consent screen, so resolution is allowed.
    requestGoogleAuthorization(accountEmail = accountEmail, allowConsent = true) { result ->
        result.onSuccess { authorization ->
            completeGoogleCalendarImport(authorization, parentId)
        }.onFailure { error ->
            googleAuthInProgress = false
            pendingGoogleParentId = null
            if (error is GoogleAuthorizationError.Canceled) {
                googleCalendarStatus = error.message
            } else {
                showError("Google Calendar", googleAuthorizationMessage(error))
            }
            // Always re-render: the row reads "Connecting…" off this flag, and a
            // failure that only raised a dialog used to leave it saying that
            // forever.
            render()
        }
    }
}

/**
 * Opens the system Google account chooser, including its "Add account" entry.
 * Returns false when no chooser could be launched, so the caller can fall back
 * to letting Play Services pick.
 */
private fun MainActivity.chooseGoogleAccount(): Boolean {
    val intent = AccountPicker.newChooseAccountIntent(
        AccountPicker.AccountChooserOptions.Builder()
            .setAllowableAccountsTypes(listOf("com.google"))
            // Show the list even when the device holds a single account: the user
            // asked to connect *another* one, and the picker is where they add it.
            .setAlwaysShowAccountPicker(true)
            .setOptionsForAddingAccount(Bundle())
            .build()
    )
    return try {
        startActivityForResult(intent, REQUEST_GOOGLE_CHOOSE_ACCOUNT)
        true
    } catch (error: android.content.ActivityNotFoundException) {
        false
    }
}

/** Resumes the link once the user has picked (or added) the account to connect. */
internal fun MainActivity.onGoogleAccountChosen(resultCode: Int, data: Intent?) {
    val parentId = pendingGoogleParentId
    pendingGoogleParentId = null
    if (resultCode != android.app.Activity.RESULT_OK) return
    val email = data?.getStringExtra(android.accounts.AccountManager.KEY_ACCOUNT_NAME)
    beginGoogleCalendarImport(accountEmail = email?.takeIf { it.isNotBlank() }, parentId = parentId)
}

/**
 * Links the account behind [authorization] and imports its calendars.
 *
 * The core resolves the authoritative account identity from the token itself
 * (OpenID `userinfo`), so the email here is only a hint for the case where the
 * token turns out not to carry it.
 */
internal fun MainActivity.completeGoogleCalendarImport(
    authorization: AuthorizationResult,
    parentId: String?
) {
    googleAuthInProgress = true
    val identity = googleIdentityJson(
        accountId = null,
        accessToken = authorization.accessToken,
        email = authorization.toGoogleSignInAccount()?.email,
        grantedScopes = authorization.grantedScopes
    )
    Thread {
        val result = runCatching {
            bridge.request(
                obj(
                    "type" to "import_google_calendars_with_identity",
                    "account" to identity,
                    "parent_id" to parentId
                )
            )
        }
        // Read the snapshot back on this thread too. It is another trip through
        // the core's lock, and taking it on the main thread right after an import
        // is how "Connecting…" turned into an ANR: the import (or a sync running
        // beside it) still holds the lock, and the UI thread waits behind it.
        val refreshed = result.map { snapshotFromCore() }
        runOnUiThread {
            googleAuthInProgress = false
            pendingGoogleParentId = null
            result.onSuccess { response ->
                googleCalendarStatus = response.optString("message")
                refreshed.getOrNull()?.let { snapshot = it }
                configureGoogleSyncPolling()
                render()
                // After the repaint, not before: rescheduling walks every pending
                // occurrence and re-registers the alarms, and doing that first is
                // what kept the row on "Connecting…" while the work ran.
                rescheduleNotifications()
                if (syncSession != null) syncOnce()
            }.onFailure { error ->
                showError("Google Calendar", error.message)
                // The row reads "Connecting…" off the flag above, so it has to be
                // repainted even when all the user sees is the error dialog.
                render()
            }
        }
    }.start()
}

/**
 * Periodic/manual refresh of every linked account.
 *
 * Each connected account gets a *silent* authorization request first — pinned to
 * that account so multiple linked Google accounts each refresh independently. An
 * account Google will not renew without interaction is flagged in the core so the
 * settings page can offer a reconnect instead of failing quietly forever.
 */
internal fun MainActivity.syncGoogleCalendars(silent: Boolean = false) {
    if (googleSyncInProgress) return
    val accounts = connectedGoogleAccounts()
    if (accounts.length() == 0) return
    googleSyncInProgress = true
    Thread {
        val identities = JSONArray()
        val reconnect = ArrayList<String>()
        for (index in 0 until accounts.length()) {
            val account = accounts.optJSONObject(index) ?: continue
            val accountId = account.optString("id").takeIf { it.isNotBlank() } ?: continue
            val email = account.optString("email").takeIf { it.isNotBlank() }
            // No consent screen from a background refresh: the user did not ask
            // for one here, and a periodic sync must never steal focus.
            val token = runCatching { awaitGoogleAuthorization(email) }.getOrNull()
            if (token == null || !usableSilentAuthorization(token)) {
                reconnect.add(accountId)
                continue
            }
            identities.put(
                googleIdentityJson(
                    accountId = accountId,
                    accessToken = token.accessToken,
                    email = token.toGoogleSignInAccount()?.email ?: email,
                    grantedScopes = token.grantedScopes
                )
            )
        }

        // Record the reconnect state before syncing, so an account that needs
        // attention is flagged even if the sync itself then fails.
        reconnect.forEach { accountId ->
            runCatching {
                bridge.request(
                    obj(
                        "type" to "set_google_account_needs_reauth",
                        "account_id" to accountId,
                        "needs_reauth" to true
                    )
                )
            }
        }

        val result = runCatching {
            bridge.request(
                obj(
                    "type" to "sync_google_calendars_with_identity",
                    "accounts" to identities
                )
            )
        }
        runOnUiThread {
            googleSyncInProgress = false
            result.onSuccess { response ->
                googleCalendarStatus = response.optString("message")
                loadSnapshot()
                rescheduleNotifications()
                render()
                if (syncSession != null) syncOnce()
            }.onFailure { error ->
                if (silent) {
                    googleCalendarStatus = error.message
                } else {
                    showError("Google Calendar", error.message)
                }
            }
        }
    }.start()
}

/**
 * Re-runs interactive consent for one already-linked account and clears its
 * reconnect flag on success.
 */
internal fun MainActivity.reconnectGoogleAccount(accountId: String, email: String?) {
    if (googleAuthInProgress) return
    val unavailable = googlePlayServicesProblem()
    if (unavailable != null) {
        showError("Google Calendar", unavailable)
        return
    }
    googleAuthInProgress = true
    render()
    requestGoogleAuthorization(accountEmail = email, allowConsent = true) { result ->
        result.onSuccess { authorization ->
            googleAuthInProgress = false
            mutate(
                obj(
                    "type" to "set_google_account_needs_reauth",
                    "account_id" to accountId,
                    "needs_reauth" to false
                )
            )
            // The token from this grant is used immediately by the sync below.
            syncGoogleCalendars()
        }.onFailure { error ->
            googleAuthInProgress = false
            if (error is GoogleAuthorizationError.Canceled) {
                googleCalendarStatus = error.message
                render()
            } else {
                showError("Google Calendar", googleAuthorizationMessage(error))
            }
        }
    }
}

/** The linked accounts as reported by the core's settings snapshot. */
internal fun MainActivity.connectedGoogleAccounts(): JSONArray =
    snapshot.optJSONObject("settings")?.optJSONArray("google_accounts") ?: JSONArray()

/** Accounts Google will not renew without the user granting consent again. */
internal fun MainActivity.googleAccountsNeedingReconnect(): List<JSONObject> {
    val accounts = connectedGoogleAccounts()
    val out = ArrayList<JSONObject>()
    for (index in 0 until accounts.length()) {
        val account = accounts.optJSONObject(index) ?: continue
        if (account.optBoolean("needs_reauth", false)) out.add(account)
    }
    return out
}

/**
 * Asks Google Identity to authorize the Calendar scopes.
 *
 * Play Services answers immediately when the grant already exists. Otherwise it
 * hands back a [android.app.PendingIntent] for the consent screen, which is only
 * launched when [allowConsent] is set — a background refresh reports
 * [GoogleAuthorizationError.ConsentRequired] instead of interrupting the user.
 * [onResult] always runs on the main thread.
 */
private fun MainActivity.requestGoogleAuthorization(
    accountEmail: String?,
    allowConsent: Boolean,
    onResult: (Result<AuthorizationResult>) -> Unit
) {
    Identity.getAuthorizationClient(this)
        .authorize(googleAuthorizationRequest(accountEmail))
        .addOnSuccessListener { authorization ->
            val pending = authorization.pendingIntent
            if (pending == null) {
                onResult(googleAuthorizationOutcome(authorization))
                return@addOnSuccessListener
            }
            if (!allowConsent) {
                onResult(Result.failure(GoogleAuthorizationError.ConsentRequired))
                return@addOnSuccessListener
            }
            // Resumed in onActivityResult; see pendingGoogleAuthorizationCallback.
            pendingGoogleAuthorizationCallback = onResult
            try {
                startIntentSenderForResult(pending.intentSender, REQUEST_GOOGLE_AUTHORIZE, null, 0, 0, 0)
            } catch (error: IntentSender.SendIntentException) {
                pendingGoogleAuthorizationCallback = null
                onResult(Result.failure(error))
            }
        }
        .addOnFailureListener { error -> onResult(Result.failure(error)) }
}

/**
 * Blocking, non-interactive variant used by the background refresh loop, which
 * walks the connected accounts one at a time off the main thread.
 */
private fun MainActivity.awaitGoogleAuthorization(accountEmail: String?): AuthorizationResult? {
    val authorization = Tasks.await(
        Identity.getAuthorizationClient(this).authorize(googleAuthorizationRequest(accountEmail)),
        GOOGLE_AUTHORIZE_TIMEOUT_MS,
        TimeUnit.MILLISECONDS
    )
    // A resolution here means consent is required, which a background refresh
    // must not raise — the caller turns this into a reconnect prompt.
    return if (authorization.pendingIntent != null) null else authorization
}

private fun MainActivity.googleAuthorizationRequest(accountEmail: String?): AuthorizationRequest {
    val scopes = (GOOGLE_IDENTITY_SCOPES + GOOGLE_CALENDAR_SCOPES).map { com.google.android.gms.common.api.Scope(it) }
    val builder = AuthorizationRequest.builder().setRequestedScopes(scopes)
    // Pinning the account keeps a multi-account setup refreshing each linked
    // account rather than whichever one Play Services would pick by default.
    accountEmail?.takeIf { it.isNotBlank() }?.let { builder.setAccount(Account(it, "com.google")) }
    return builder.build()
}

/** Validates an authorization that came back without a resolution. */
private fun googleAuthorizationOutcome(authorization: AuthorizationResult): Result<AuthorizationResult> {
    if (authorization.accessToken.isNullOrBlank()) {
        return Result.failure(GoogleAuthorizationError.ConsentRequired)
    }
    if (!grantsCalendarScopes(authorization.grantedScopes)) {
        return Result.failure(GoogleAuthorizationError.ScopesDeclined)
    }
    return Result.success(authorization)
}

/**
 * Whether a *silent* authorization can be spent on a sync.
 *
 * Play Services can hand back a cached token without repeating the scopes it was
 * granted for, and reading that empty list as "the user declined" is what put a
 * perfectly healthy account into "Authorization expired". A grant that really is
 * too narrow now surfaces from the Calendar API itself, which the core turns into
 * a reconnect prompt.
 */
private fun usableSilentAuthorization(authorization: AuthorizationResult?): Boolean {
    if (authorization?.accessToken.isNullOrBlank()) return false
    val granted = authorization?.grantedScopes
    return granted.isNullOrEmpty() || grantsCalendarScopes(granted)
}

private fun grantsCalendarScopes(granted: List<String>?): Boolean {
    val scopes = granted ?: return false
    return GOOGLE_CALENDAR_SCOPES.all { scopes.contains(it) }
}

/** Resumes a consent flow launched through [android.app.PendingIntent]. */
internal fun MainActivity.onGoogleAuthorizationResult(resultCode: Int, data: Intent?) {
    val callback = pendingGoogleAuthorizationCallback
    pendingGoogleAuthorizationCallback = null
    if (callback == null) {
        // The activity was recreated while consent was on screen, so the
        // in-flight flow is gone. Reset rather than leaving the UI spinning.
        googleAuthInProgress = false
        pendingGoogleParentId = null
        render()
        return
    }
    if (resultCode != android.app.Activity.RESULT_OK) {
        callback(Result.failure(GoogleAuthorizationError.Canceled))
        return
    }
    val authorization = runCatching {
        Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(data)
    }
    callback(authorization.mapCatching { googleAuthorizationOutcome(it).getOrThrow() })
}

/** Whether Play Services can serve an authorization request at all. */
private fun MainActivity.googlePlayServicesProblem(): String? {
    val availability = GoogleApiAvailability.getInstance()
    return when (val status = availability.isGooglePlayServicesAvailable(this)) {
        ConnectionResult.SUCCESS -> null
        else -> availability.getErrorString(status)
            ?: "Google Play services is required to connect Google Calendar."
    }
}

/** Turns a Play Services failure into something worth showing a user. */
private fun googleAuthorizationMessage(error: Throwable): String? = when {
    error is GoogleAuthorizationError -> error.message
    error is ApiException && error.statusCode == CommonStatusCodes.SIGN_IN_REQUIRED ->
        GoogleAuthorizationError.NoAccount.message
    error is ApiException && error.statusCode == CommonStatusCodes.DEVELOPER_ERROR ->
        "This build is not registered for Google sign-in."
    else -> error.message
}

private fun googleIdentityJson(
    accountId: String?,
    accessToken: String?,
    email: String?,
    grantedScopes: List<String>?
): JSONObject = JSONObject()
    .put("account_id", accountId ?: JSONObject.NULL)
    .put("client_id", GOOGLE_CLIENT_ID)
    .put("access_token", accessToken ?: "")
    .put("email", email ?: JSONObject.NULL)
    .put("scope", grantedScopes?.joinToString(" ") ?: JSONObject.NULL)
    // Play Services does not expose the token lifetime, so leave it unset: the
    // core then treats the token as needing renewal on the next sync, which is
    // exactly right when only the shell can renew it.
    .put("expires_in_secs", JSONObject.NULL)

/**
 * The Google Calendar page behind the settings row.
 *
 * That row used to *run a sync* while wearing a navigation chevron, so tapping
 * it looked like nothing happened at all. Everything about a linked account now
 * lives here instead: what is connected, syncing on demand, reconnecting,
 * unlinking (which the shell had no way to reach before), and adding another.
 */
internal fun MainActivity.renderGoogleCalendarPage(): LinearLayout {
    val root = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(theme.bgApp)
    }
    root.addView(LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(12), 0, dp(12), 0)
        background = underline(theme.bgApp)
        addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@renderGoogleCalendarPage, "common.back"), iconSize = 20) {
            settingsShowingGoogle = false
            render()
        })
        addView(text(L10n.t(this@renderGoogleCalendarPage, "settings.google_calendar.section"), theme.textPrimary, 16f, true).apply {
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(0, -1, 1f))
        addView(View(this@renderGoogleCalendarPage), LinearLayout.LayoutParams(dp(32), dp(28)))
    }, LinearLayout.LayoutParams(-1, dp(44)))

    val body = page()
    val accounts = connectedGoogleAccounts()
    if (accounts.length() == 0) {
        body.addView(settingsGroup(
            settingsLinkRow(
                if (googleAuthInProgress) L10n.t(this, "mobile.settings.google_connecting")
                else L10n.t(this, "mobile.settings.connect_google_calendar")
            ) { startGoogleCalendarImport() }
        ))
    } else {
        body.addView(settingsSection(L10n.t(this, "settings.google_calendar.accounts_heading")))
        val accountRows = ArrayList<View>()
        for (index in 0 until accounts.length()) {
            val account = accounts.optJSONObject(index) ?: continue
            val accountId = account.optString("id").takeIf { it.isNotBlank() } ?: continue
            val label = account.optString("title").ifEmpty { account.optString("email") }
            val needsReauth = account.optBoolean("needs_reauth", false)
            val detail = if (needsReauth) "Authorization expired" else account.optString("detail")
            accountRows.add(
                settingsLinkRow(label, detail) {
                    showGoogleAccountActions(
                        accountId = accountId,
                        label = label,
                        email = account.optString("email").takeIf { it.isNotBlank() },
                        needsReauth = needsReauth
                    )
                }
            )
        }
        body.addView(settingsGroup(*accountRows.toTypedArray()))

        body.addView(settingsSection(L10n.t(this, "settings.google_calendar.calendars_heading")))
        body.addView(settingsGroup(
            settingsLinkRow(
                if (googleSyncInProgress) L10n.t(this, "mobile.settings.google_syncing")
                else L10n.t(this, "mobile.settings.sync_google_calendars")
            ) { syncGoogleCalendars() },
            settingsLinkRow(
                if (googleAuthInProgress) L10n.t(this, "mobile.settings.google_connecting")
                else L10n.t(this, "mobile.settings.connect_another_google_account")
            ) { startGoogleCalendarImport() }
        ))
    }

    googleCalendarStatus?.takeIf { it.isNotBlank() }?.let { status ->
        body.addView(text(status, theme.textMuted, 12f, false).apply {
            setPadding(dp(8), dp(10), dp(8), dp(2))
        })
    }
    root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
    return root
}

/** Per-account actions: reconnect when Google wants consent again, sync, unlink. */
private fun MainActivity.showGoogleAccountActions(
    accountId: String,
    label: String,
    email: String?,
    needsReauth: Boolean
) {
    val actions = ArrayList<String>()
    val handlers = ArrayList<() -> Unit>()
    if (needsReauth) {
        actions.add(L10n.t(this, "google.calendar.reconnect_title"))
        handlers.add { reconnectGoogleAccount(accountId, email) }
    }
    actions.add(L10n.t(this, "sync.action.sync_now"))
    handlers.add { syncGoogleCalendars() }
    actions.add(L10n.t(this, "settings.google_calendar.unlink_button"))
    handlers.add { confirmUnlinkGoogleAccount(accountId, label) }

    AlertDialog.Builder(this)
        .setTitle(label)
        .setItems(actions.toTypedArray()) { _, which -> handlers[which]() }
        .setNegativeButton(L10n.t(this, "common.close"), null)
        .show()
}

/** Unlinking drops the local credentials, so it is worth one confirmation. */
private fun MainActivity.confirmUnlinkGoogleAccount(accountId: String, label: String) {
    AlertDialog.Builder(this)
        .setTitle(L10n.t(this, "settings.google_calendar.unlink_confirm_title"))
        .setMessage(L10n.t(this, "settings.google_calendar.unlink_confirm_message", mapOf("name" to label)))
        .setNegativeButton(L10n.t(this, "settings.google_calendar.keep_account"), null)
        .setPositiveButton(L10n.t(this, "settings.google_calendar.unlink_button")) { _, _ ->
            mutate(obj("type" to "unlink_google_account", "account_id" to accountId))
            googleCalendarStatus = null
        }
        .show()
}

internal fun MainActivity.configureGoogleSyncPolling() {
    val accountCount = snapshot.optJSONObject("settings")?.optInt("google_account_count", 0) ?: 0
    if (accountCount <= 0) {
        googleSyncPollingActive = false
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        return
    }
    if (googleSyncPollingActive) return
    googleSyncPollingActive = true
    googleSyncHandler.postDelayed(googleSyncRunnable, GOOGLE_SYNC_INTERVAL_MS)
}

internal fun MainActivity.clearPendingGoogleAuth() {
    pendingGoogleAuthorizationCallback = null
    pendingGoogleParentId = null
    getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
        .remove("knotq.googleAuthRequest")
        .remove("knotq.googleAuthParentId")
        .apply()
}
