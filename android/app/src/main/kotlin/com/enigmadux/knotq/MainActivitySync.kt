package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextPaint
import android.text.TextUtils
import android.text.TextWatcher
import android.util.Base64
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Gravity
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.TimePicker
import android.widget.Toast
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.google.android.play.core.review.ReviewManagerFactory
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.TextStyle
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Sync / auth / billing / Google-calendar integration for MainActivity,
// extracted as extension functions (same module) to shrink MainActivity.kt.

internal fun MainActivity.showSyncAccountDialog() {
    if (syncSession != null) {
        val session = syncSession ?: return
        // Lead with the action that matters for the current state: syncing when
        // it is on, subscribing when it is off. Destructive actions stay last.
        val subscriptionAction =
            if (syncSubscriptionCancelled) "Re-enable subscription" else "Cancel subscription"
        val needsVerification = !session.supportsSync && syncEmailVerified == false
        val actions = if (session.supportsSync) {
            // "Resync" is the dedicated card button (iOS parity), so this menu is
            // just account housekeeping.
            mutableListOf(subscriptionAction, "Sign out", "Delete account")
        } else if (needsVerification) {
            // Subscribing is blocked until the email is verified, so offer the resend
            // instead of a Subscribe entry that would fail.
            mutableListOf(
                "Resend verification email",
                "Restore purchases",
                "Sign out",
                "Delete account"
            )
        } else {
            mutableListOf(
                "Subscribe with Google Play",
                "Restore purchases",
                "Sign out",
                "Delete account"
            )
        }
        val stateLine = when {
            syncOffline -> "Offline - sync will retry when your connection is back."
            session.supportsSync && syncSubscriptionCancelled ->
                "Cancelled - sync stays active until the billing period ends."
            session.supportsSync -> "Sync is on for this account."
            needsVerification -> "Verify your email to subscribe - check your inbox."
            else -> "Sync is off - subscribe to turn it on."
        }
        // NOTE: AlertDialog shows EITHER a message OR an items list, not both
        // (message wins). This is the "Manage" menu, so the actions must render —
        // the email + state (Enabled/Offline/Cancelled badge) already show on the
        // sync card, so carry only a concise state line in the title here.
        AlertDialog.Builder(this)
            .setTitle(stateLine)
            .setItems(actions.toTypedArray()) { _, which ->
                when (actions[which]) {
                    "Sync now" -> syncOnce()
                    "Subscribe with Google Play" -> startGooglePlaySubscribe()
                    "Resend verification email" -> resendVerificationEmail()
                    "Restore purchases" -> restoreGooglePlayPurchases()
                    "Cancel subscription" -> cancelSubscriptionAction()
                    "Re-enable subscription" -> reEnableSyncSubscription()
                    "Sign out" -> signOutSync()
                    "Delete account" -> confirmDeleteSyncAccount()
                }
            }
            .setNegativeButton("Close", null)
            .show()
        // Re-check the lifecycle so a cancellation made elsewhere is reflected.
        refreshAccountStatus()
        return
    }

    syncLoginChallenge = null

    AlertDialog.Builder(this)
        .setTitle("Sync account")
        .setMessage("KnotQ will open your browser to sign in, then return here automatically.")
        .setNegativeButton("Cancel", null)
        .setNeutralButton("Create account") { _, _ -> beginBrowserSyncAuth(createAccount = true) }
        .setPositiveButton("Sign in") { _, _ -> beginBrowserSyncAuth(createAccount = false) }
        .show()
}

internal fun MainActivity.beginBrowserSyncAuth(createAccount: Boolean) {
    if (syncAuthInProgress) return
    val apiBase = normalizeApiBase(syncSession?.apiBase ?: defaultSyncApiBase())
    val state = randomUrlToken(24)
    val verifier = pkceVerifier()
    val challenge = pkceChallenge(verifier)
    val authUrl = Uri.parse("${syncWebBase(apiBase)}/signin.html").buildUpon()
        .appendQueryParameter("redirect_uri", SYNC_SIGN_IN_REDIRECT_URI)
        .appendQueryParameter("state", state)
        .appendQueryParameter("mode", if (createAccount) "create" else "signin")
        .appendQueryParameter("api", apiBase)
        .appendQueryParameter("code_challenge", challenge)
        .appendQueryParameter("code_challenge_method", "S256")
        .build()

    savePendingSyncBrowserAuth(PendingSyncBrowserAuth(apiBase, state, verifier))
    syncAuthInProgress = true
    try {
        startActivity(Intent(Intent.ACTION_VIEW, authUrl))
        Toast.makeText(this, "Continue in your browser.", Toast.LENGTH_SHORT).show()
    } catch (error: ActivityNotFoundException) {
        clearPendingSyncBrowserAuth()
        showError("Sign in failed", error.message)
    } finally {
        syncAuthInProgress = false
    }
}

internal fun MainActivity.handleIncomingAuthIntent(uri: Uri?) {
    // Only the hosted sync sign-in still comes back via a deep link. Google Calendar
    // now uses a loopback redirect captured directly on a local socket, so it never
    // arrives through an intent.
    handleSyncBrowserCallback(uri)
}

internal fun MainActivity.handleSyncBrowserCallback(uri: Uri?): Boolean {
    if (uri == null || uri.scheme != SYNC_SIGN_IN_REDIRECT_SCHEME || uri.host != SYNC_SIGN_IN_REDIRECT_HOST) {
        return false
    }
    // Android can deliver the same callback more than once (onCreate *and*
    // onNewIntent, or the intent stored by setIntent() being replayed when the
    // activity is recreated on rotation). The authorization code is single-use, so
    // a duplicate exchange would 400 and surface a spurious "Sign in failed" even
    // though the first exchange succeeded. Ignore a duplicate while one is in flight,
    // and treat a callback with no pending request as an already-handled duplicate
    // (or a stray deep link) rather than a failure.
    if (syncAuthInProgress) return true
    val pending = loadPendingSyncBrowserAuth() ?: return true
    val state = uri.getQueryParameter("state").orEmpty()
    if (state != pending.state) {
        clearPendingSyncBrowserAuth()
        showError("Sign in failed", "Sign-in could not be verified. Please try again.")
        return true
    }
    val errorCode = uri.getQueryParameter("error").orEmpty()
    if (errorCode.isNotEmpty()) {
        clearPendingSyncBrowserAuth()
        showError("Sign in failed", authorizeErrorMessage(errorCode))
        return true
    }
    val code = uri.getQueryParameter("code").orEmpty()
    if (code.isEmpty()) {
        clearPendingSyncBrowserAuth()
        showError("Sign in failed", "Sign-in did not complete.")
        return true
    }

    // Claim the exchange and consume the pending request up front so any duplicate
    // delivery (see above) sees no pending request and bails silently instead of
    // re-spending the now-consumed authorization code.
    syncAuthInProgress = true
    clearPendingSyncBrowserAuth()
    Thread {
        val result = runCatching {
            parseSyncSession(
                httpJson(
                    "${pending.apiBase}/v1/auth/authorize/exchange",
                    "POST",
                    JSONObject()
                        .put("code", code)
                        .put("code_verifier", pending.codeVerifier),
                    authorizeAction = true
                ),
                pending.apiBase
            )
        }
        runOnUiThread {
            syncAuthInProgress = false
            result.onSuccess { session ->
                syncLoginChallenge = null
                installSyncSession(session)
                Toast.makeText(this, "Signed in as ${session.email}", Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError("Sign in failed", error.message)
            }
        }
    }.start()
    return true
}

internal fun MainActivity.savePendingSyncBrowserAuth(auth: PendingSyncBrowserAuth) {
    getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
        .putString(SYNC_AUTH_API_BASE_PREF, auth.apiBase)
        .putString(SYNC_AUTH_STATE_PREF, auth.state)
        .putString(SYNC_AUTH_VERIFIER_PREF, auth.codeVerifier)
        .apply()
}

internal fun MainActivity.loadPendingSyncBrowserAuth(): PendingSyncBrowserAuth? {
    val prefs = getSharedPreferences("knotq", Context.MODE_PRIVATE)
    val apiBase = prefs.getString(SYNC_AUTH_API_BASE_PREF, null)?.takeIf { it.isNotBlank() }
        ?: return null
    val state = prefs.getString(SYNC_AUTH_STATE_PREF, null)?.takeIf { it.isNotBlank() }
        ?: return null
    val verifier = prefs.getString(SYNC_AUTH_VERIFIER_PREF, null)?.takeIf { it.isNotBlank() }
        ?: return null
    return PendingSyncBrowserAuth(apiBase, state, verifier)
}

internal fun MainActivity.clearPendingSyncBrowserAuth() {
    getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
        .remove(SYNC_AUTH_API_BASE_PREF)
        .remove(SYNC_AUTH_STATE_PREF)
        .remove(SYNC_AUTH_VERIFIER_PREF)
        .apply()
}

internal fun MainActivity.pkceVerifier(): String =
    randomUrlToken(32)

internal fun MainActivity.pkceChallenge(verifier: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8))
    return base64UrlNoPad(digest)
}

internal fun MainActivity.randomUrlToken(byteCount: Int): String {
    val bytes = ByteArray(byteCount)
    SecureRandom().nextBytes(bytes)
    return base64UrlNoPad(bytes)
}

internal fun MainActivity.base64UrlNoPad(bytes: ByteArray): String =
    Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

internal fun MainActivity.signInToSync(apiBaseRaw: String, emailRaw: String, password: String) {
    if (syncAuthInProgress) return
    val apiBase = normalizeApiBase(apiBaseRaw)
    val email = emailRaw.trim()
    if (apiBase.isEmpty() || email.isEmpty() || password.isEmpty()) {
        showError("Sign in failed", "Enter your sync API, email, and password")
        return
    }
    syncAuthInProgress = true
    Thread {
        val result = runCatching { requestSyncLoginStart(apiBase, email, password) }
        runOnUiThread {
            syncAuthInProgress = false
            result.onSuccess { start ->
                val session = start.session
                if (session != null) {
                    installSyncSession(session)
                    Toast.makeText(this, "Signed in as ${session.email}", Toast.LENGTH_SHORT).show()
                } else if (start.challenge != null) {
                    syncLoginChallenge = start.challenge
                    showLoginCodeDialog(start.challenge)
                }
            }.onFailure { error ->
                showError("Sign in failed", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.createSyncAccount(apiBaseRaw: String, emailRaw: String, password: String) {
    if (syncAuthInProgress) return
    val apiBase = normalizeApiBase(apiBaseRaw)
    val email = emailRaw.trim()
    if (apiBase.isEmpty() || email.isEmpty() || password.isEmpty()) {
        showError("Account creation failed", "Enter your sync API, email, and password")
        return
    }
    syncAuthInProgress = true
    Thread {
        val result = runCatching {
            parseSyncSession(
                httpJson("$apiBase/v1/auth/signup", "POST", JSONObject().put("email", email).put("password", password)),
                apiBase
            )
        }
        runOnUiThread {
            syncAuthInProgress = false
            result.onSuccess { session ->
                syncLoginChallenge = null
                installSyncSession(session)
                Toast.makeText(this, "Signed in as ${session.email}", Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError("Account creation failed", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.showLoginCodeDialog(challenge: SyncLoginChallenge) {
    val form = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), 0)
    }
    form.addView(text("Enter the code sent to ${challenge.email}.", theme.textDim, 13f, false), spaced())
    val code = EditText(this).apply {
        hint = "Code"
        setText(challenge.devCode.orEmpty())
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        setSingleLine(true)
    }
    form.addView(code)
    val dialog = AlertDialog.Builder(this)
        .setTitle("Verify sign in")
        .setView(form)
        .setNegativeButton("Cancel", null)
        .setNeutralButton("Different account", null)
        .setPositiveButton("Verify", null)
        .create()
    dialog.setOnShowListener {
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            dialog.dismiss()
            verifyLoginCode(code.text.toString())
        }
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
            syncLoginChallenge = null
            dialog.dismiss()
            showSyncAccountDialog()
        }
    }
    dialog.show()
}

internal fun MainActivity.verifyLoginCode(codeRaw: String) {
    val challenge = syncLoginChallenge ?: return
    val code = codeRaw.trim()
    if (code.isEmpty()) {
        showError("Verification failed", "Enter the code we emailed you.")
        return
    }
    syncAuthInProgress = true
    Thread {
        val result = runCatching {
            parseSyncSession(
                httpJson(
                    "${challenge.apiBase}/v1/auth/login/verify",
                    "POST",
                    JSONObject().put("challenge_id", challenge.challengeId).put("code", code)
                ),
                challenge.apiBase
            )
        }
        runOnUiThread {
            syncAuthInProgress = false
            result.onSuccess { session ->
                syncLoginChallenge = null
                installSyncSession(session)
                Toast.makeText(this, "Signed in as ${session.email}", Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError("Verification failed", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.installSyncSession(session: SyncSession) {
    syncSession = session
    syncOffline = false
    syncFailureNotified = false
    saveSyncSession(session)
    startSyncPolling()
    scheduleBackgroundSyncWork()
    render()
    if (session.supportsSync) refreshAccountStatus()
    // Signing in during the onboarding account step advances to the tour.
    if (onboardingActive && onboardingPhase == ONBOARDING_ACCOUNT) {
        startOnboardingGuide()
    }
}

internal fun MainActivity.signOutSync() {
    syncSession = null
    syncLoginChallenge = null
    syncSubscriptionCancelled = false
    syncSubscriptionProvider = null
    syncEmailVerified = null
    resendVerificationCooldown = 0
    resendVerificationInProgress = false
    syncOffline = false
    syncFailureNotified = false
    saveSyncSession(null)
    syncPollHandler.removeCallbacks(syncPollRunnable)
    syncPollHandler.removeCallbacks(syncEditRunnable)
    syncEditPending = false
    cancelBackgroundSyncWork()
    render()
}

/// Read the authoritative subscription lifecycle so Settings can reflect a
/// cancelled-but-active subscription and offer to re-enable it.
internal fun MainActivity.refreshAccountStatus() {
    if (syncInProgress) return
    val session = syncSession ?: return
    syncInProgress = true
    Thread {
        val statusResult = runCatching {
            val active = when (val refreshed = refreshSyncSessionIfNeeded(session)) {
                is SyncRefreshResult.Ready -> {
                    persistRotatedSyncSession(session, refreshed.session)
                    refreshed.session
                }
                SyncRefreshResult.Deferred -> {
                    runOnUiThread {
                        syncOffline = true
                        render()
                    }
                    return@runCatching null
                }
                SyncRefreshResult.SessionDead -> {
                    runOnUiThread { expireSyncSession() }
                    return@runCatching null
                }
            }
            httpJson(
                "${active.apiBase}/v1/auth/account/status",
                "GET",
                JSONObject(),
                bearerToken = active.bearerToken
            )
        }
        runOnUiThread {
            syncInProgress = false
            statusResult.exceptionOrNull()?.let { error ->
                if (isLikelyNetworkError(error) || isTransientSyncError(error)) {
                    syncOffline = true
                    render()
                }
                return@runOnUiThread
            }
            val result = statusResult.getOrNull() ?: return@runOnUiThread
            syncOffline = false
            syncSubscriptionProvider = result.optString("subscription_provider").ifEmpty { null }
            syncEmailVerified =
                if (result.has("email_verified")) result.optBoolean("email_verified", false) else null
            syncSubscriptionCancelled =
                result.optBoolean("supports_sync", true) &&
                    result.optString("subscription_state").equals("cancelled", ignoreCase = true)
            render()
        }
    }.start()
}

/// Re-check the sync entitlement + subscription lifecycle from the backend so a
/// subscription bought (or changed) while the app was closed — the common
/// "subscribe, reopen the app, see it" flow — shows up without waiting for the
/// access token to expire. One forced token refresh re-reads supports_sync; the
/// status read then runs on the rotated token, all on a single thread, so the
/// single-use refresh token is never replayed concurrently. Guarded by the poll
/// loop's in-progress flag for the same reason.
internal fun MainActivity.refreshSubscriptionStatus() {
    if (syncInProgress) return
    val session = syncSession ?: return
    if (session.refreshToken.isEmpty()) return
    syncInProgress = true
    Thread {
        val refresh = refreshSyncSessionIfNeeded(session, force = true)
        val active = (refresh as? SyncRefreshResult.Ready)?.session
        val status = active?.let {
            runCatching {
                httpJson(
                    "${it.apiBase}/v1/auth/account/status",
                    "GET",
                    JSONObject(),
                    bearerToken = it.bearerToken
                )
            }.getOrNull()
        }
        runOnUiThread {
            syncInProgress = false
            if (refresh is SyncRefreshResult.Deferred) {
                syncOffline = true
                render()
                return@runOnUiThread
            }
            if (refresh is SyncRefreshResult.SessionDead) {
                // Refresh token revoked/expired: drop the session like the poll loop.
                expireSyncSession()
                return@runOnUiThread
            }
            if (active != null && active !== session) {
                syncSession = active
                syncOffline = false
                syncFailureNotified = false
                saveSyncSession(active)
                scheduleBackgroundSyncWork()
                // A just-granted entitlement: pull the workspace promptly instead
                // of waiting on the 30s poll.
                if (active.supportsSync) requestSyncSoon()
            }
            if (status != null) {
                syncSubscriptionProvider = status.optString("subscription_provider").ifEmpty { null }
                syncEmailVerified =
                    if (status.has("email_verified")) status.optBoolean("email_verified", false) else null
                syncSubscriptionCancelled =
                    status.optBoolean("supports_sync", true) &&
                        status.optString("subscription_state").equals("cancelled", ignoreCase = true)
            }
            render()
        }
    }.start()
}

/// Undo a pending cancellation so the subscription renews again. Web
/// subscriptions un-cancel through our backend; Google/Apple renewals can only be
/// turned back on in their stores, so for those we open the store's
/// manage-subscriptions page. On Android the subscription is normally a Google
/// Play one, so an unknown provider routes to Google Play.
internal fun MainActivity.reEnableSyncSubscription() {
    when ((syncSubscriptionProvider ?: "").lowercase()) {
        "apple" -> {
            openSubscriptionStorePage(APPLE_SUBSCRIPTIONS_URL)
            return
        }
        "web" -> {}
        else -> {
            openSubscriptionStorePage(PLAY_SUBSCRIPTIONS_URL)
            return
        }
    }
    val session = syncSession ?: return
    if (syncAccountActionInProgress || syncInProgress) return
    syncAccountActionInProgress = true
    syncInProgress = true
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            parseSyncSession(
                httpJson(
                    "${active.apiBase}/v1/auth/subscription/resume",
                    "POST",
                    JSONObject(),
                    bearerToken = active.bearerToken,
                    accountAction = true
                ),
                active.apiBase
            )
        }
        runOnUiThread {
            syncAccountActionInProgress = false
            syncInProgress = false
            result.onSuccess { updated ->
                installSyncSession(updated)
                showError("Subscription re-enabled", "Your subscription will renew again.")
            }.onFailure { error ->
                showError("Could not update account", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.openSubscriptionStorePage(url: String) {
    try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    } catch (error: ActivityNotFoundException) {
        showError("Could not open subscriptions", error.message)
    }
}

internal fun MainActivity.openSyncAccountPage() {
    val apiBase = normalizeApiBase(syncSession?.apiBase ?: defaultSyncApiBase())
    // Match the configured backend (and pass `?api=`) so a sandbox/local build
    // manages the sandbox account, not production.
    val accountUri = Uri.parse("${syncWebBase(apiBase)}/account.html").buildUpon()
        .appendQueryParameter("api", apiBase)
        .fragment("signin")
        .build()
    try {
        startActivity(Intent(Intent.ACTION_VIEW, accountUri))
        Toast.makeText(this, "Continue on knotq.com.", Toast.LENGTH_SHORT).show()
    } catch (error: ActivityNotFoundException) {
        showError("Could not open account page", error.message)
    }
}

/// Native account-deletion flow (iOS parity). Confirms the account email + current
/// password, warns when an active store subscription would keep billing after
/// deletion, then calls DELETE /v1/auth/account. Deletion is scheduled with a
/// 14-day grace period; signing back in within that window cancels it.
internal fun MainActivity.confirmDeleteSyncAccount() {
    val session = syncSession ?: return
    // A live Google Play subscription keeps charging through the store even after the
    // KnotQ account is deleted — deletion does not cancel store billing. Lead with a
    // prominent warning and a shortcut to Play's manage page when that applies.
    val hasActiveStoreSub = session.supportsSync && !syncSubscriptionCancelled &&
        (syncSubscriptionProvider ?: "").lowercase() != "web"

    val form = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), 0)
    }
    if (hasActiveStoreSub) {
        form.addView(
            text(
                "Cancel your Google Play subscription first. Deleting your account does NOT cancel store billing — Google Play keeps charging you until you cancel it there.",
                theme.accent,
                13f,
                true
            ),
            spaced()
        )
    }
    form.addView(
        text(
            "This schedules your sync account and cloud data for deletion after a 14-day grace period. Your local workspace stays on this device. Sign in again within 14 days to cancel the deletion.",
            theme.textDim,
            13f,
            false
        ),
        spaced()
    )
    val emailField = EditText(this).apply {
        hint = "Email (${session.email})"
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
        setSingleLine(true)
    }
    form.addView(emailField, spaced())
    val passwordField = EditText(this).apply {
        hint = "Current password"
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        setSingleLine(true)
    }
    form.addView(passwordField)

    val builder = AlertDialog.Builder(this)
        .setTitle("Delete account")
        .setView(form)
        .setNegativeButton("Cancel", null)
    if (hasActiveStoreSub) {
        builder.setNeutralButton("Manage subscription") { _, _ ->
            openSubscriptionStorePage(PLAY_SUBSCRIPTIONS_URL)
        }
    }
    val dialog = builder
        .setPositiveButton("Delete", null)
        .create()
    dialog.setOnShowListener {
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val confirmEmail = emailField.text.toString().trim()
            if (!confirmEmail.equals(session.email, ignoreCase = true)) {
                showError("Email did not match", "Type your account email to confirm deletion.")
                return@setOnClickListener
            }
            val password = passwordField.text.toString()
            if (password.isEmpty()) {
                showError("Password required", "Enter your current password to delete this account.")
                return@setOnClickListener
            }
            dialog.dismiss()
            deleteSyncAccount(confirmEmail, password)
        }
    }
    dialog.show()
}

// Step 1 of 2: re-authenticate (account email + current password). On success the
// backend emails a one-time code; we then collect it to confirm. Nothing is
// scheduled until the code is verified (deleteSyncAccountVerify).
internal fun MainActivity.deleteSyncAccount(confirmEmail: String, password: String) {
    val session = syncSession ?: return
    if (syncAccountActionInProgress || syncInProgress) return
    syncAccountActionInProgress = true
    syncInProgress = true
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            httpJson(
                "${active.apiBase}/v1/auth/account",
                "DELETE",
                JSONObject()
                    .put("confirm_email", confirmEmail)
                    .put("password", password),
                bearerToken = active.bearerToken,
                accountAction = true
            )
        }
        runOnUiThread {
            syncAccountActionInProgress = false
            syncInProgress = false
            result.onSuccess { response ->
                val challengeId = response.optString("challenge_id")
                if (challengeId.isEmpty()) {
                    showError("Could not delete account", "The sync API did not return a confirmation code.")
                } else {
                    showDeletionCodeDialog(challengeId, response.optString("dev_code").ifEmpty { null })
                }
            }.onFailure { error ->
                showError("Could not delete account", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.showDeletionCodeDialog(challengeId: String, devCode: String?) {
    val session = syncSession ?: return
    val form = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), 0)
    }
    form.addView(
        text(
            "Enter the 6-digit code we emailed to ${session.email} to schedule deletion of your account.",
            theme.textDim,
            13f,
            false
        ),
        spaced()
    )
    val codeField = EditText(this).apply {
        hint = "Code"
        setText(devCode.orEmpty())
        inputType = InputType.TYPE_CLASS_NUMBER
        setSingleLine(true)
    }
    form.addView(codeField)
    val dialog = AlertDialog.Builder(this)
        .setTitle("Confirm account deletion")
        .setView(form)
        .setNegativeButton("Cancel", null)
        .setPositiveButton("Delete account", null)
        .create()
    dialog.setOnShowListener {
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val code = codeField.text.toString().trim()
            if (code.length != 6) {
                showError("Enter the code", "Enter the 6-digit code we emailed you.")
                return@setOnClickListener
            }
            dialog.dismiss()
            deleteSyncAccountVerify(challengeId, code)
        }
    }
    dialog.show()
}

// Step 2 of 2: submit the emailed code to schedule the deletion + sign out.
internal fun MainActivity.deleteSyncAccountVerify(challengeId: String, code: String) {
    val session = syncSession ?: return
    if (syncAccountActionInProgress || syncInProgress) return
    syncAccountActionInProgress = true
    syncInProgress = true
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            httpJson(
                "${active.apiBase}/v1/auth/account/delete/verify",
                "POST",
                JSONObject()
                    .put("challenge_id", challengeId)
                    .put("code", code),
                bearerToken = active.bearerToken,
                accountAction = true
            )
        }
        runOnUiThread {
            syncAccountActionInProgress = false
            syncInProgress = false
            result.onSuccess {
                signOutSync()
                showError(
                    "Account deletion scheduled",
                    "Your account and cloud data are scheduled for deletion. Sign in again within 14 days to cancel. Your local workspace stays on this device."
                )
            }.onFailure { error ->
                showError("Could not delete account", error.message)
            }
        }
    }.start()
}

/// Store-managed (Apple/Google) subscriptions can't be cancelled server-side —
/// Apple has no cancel API — so open the store's manage page directly instead of
/// a backend call that fails. Web subscriptions cancel through the backend.
internal fun MainActivity.cancelSubscriptionAction() {
    when ((syncSubscriptionProvider ?: "").lowercase()) {
        "apple" -> openSubscriptionStorePage(APPLE_SUBSCRIPTIONS_URL)
        "google" -> openSubscriptionStorePage(PLAY_SUBSCRIPTIONS_URL)
        else -> confirmCancelSyncSubscription()
    }
}

internal fun MainActivity.confirmCancelSyncSubscription() {
    AlertDialog.Builder(this)
        .setTitle("Cancel sync subscription?")
        .setMessage("Your local workspace stays on this device. Paid sync may remain available until the current billing period ends.")
        .setNegativeButton("Keep sync", null)
        .setPositiveButton("Cancel subscription") { _, _ -> cancelSyncSubscription() }
        .show()
}

internal fun MainActivity.cancelSyncSubscription() {
    val session = syncSession ?: return
    if (syncAccountActionInProgress || syncInProgress) return
    syncAccountActionInProgress = true
    syncInProgress = true
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            parseSyncSession(
                httpJson(
                    "${active.apiBase}/v1/auth/subscription/cancel",
                    "POST",
                    JSONObject(),
                    bearerToken = active.bearerToken,
                    accountAction = true
                ),
                active.apiBase
            )
        }
        runOnUiThread {
            syncAccountActionInProgress = false
            syncInProgress = false
            result.onSuccess { updated ->
                installSyncSession(updated)
                if (updated.supportsSync) {
                    showError("Subscription cancelled", "Sync remains available until the current billing period ends.")
                } else {
                    showError("Sync turned off", "Your local workspace stays on this device, and you can sign in again later to re-enable sync.")
                }
                refreshAccountStatus()
            }.onFailure { error ->
                showError("Could not update account", error.message)
            }
        }
    }.start()
}

/// Resend the email-verification link to the signed-in account. Soft-rate-limited
/// on the client with a 60s cooldown (the backend rate-limits too).
internal fun MainActivity.resendVerificationEmail() {
    val session = syncSession ?: return
    if (resendVerificationInProgress || resendVerificationCooldown > 0) return
    resendVerificationInProgress = true
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            httpJson(
                "${active.apiBase}/v1/auth/email/verify/resend",
                "POST",
                JSONObject(),
                bearerToken = active.bearerToken,
                accountAction = true
            )
        }
        runOnUiThread {
            resendVerificationInProgress = false
            result.onSuccess {
                showError("Verification email sent", "Check your inbox, then reopen Settings.")
                startResendCooldown(60)
            }.onFailure { error ->
                showError("Could not resend", error.message)
            }
            render()
        }
    }.start()
}

internal fun MainActivity.startResendCooldown(seconds: Int) {
    resendVerificationCooldown = seconds
    val handler = Handler(Looper.getMainLooper())
    val tick = object : Runnable {
        override fun run() {
            if (resendVerificationCooldown <= 0) return
            resendVerificationCooldown -= 1
            render()
            if (resendVerificationCooldown > 0) handler.postDelayed(this, 1_000)
        }
    }
    handler.postDelayed(tick, 1_000)
}

// --- Google Play billing ---

internal fun MainActivity.ensureBillingClient(onReady: (BillingClient) -> Unit) {
    val existing = billingClient
    if (existing != null && existing.isReady) {
        onReady(existing)
        return
    }
    val client = existing ?: BillingClient.newBuilder(this)
        .setListener(purchasesUpdatedListener)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
        )
        .build()
    billingClient = client
    client.startConnection(object : BillingClientStateListener {
        override fun onBillingSetupFinished(result: BillingResult) {
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                onReady(client)
            } else {
                runOnUiThread {
                    purchaseInProgress = false
                    showError("Store unavailable", result.debugMessage.ifEmpty { "Google Play billing is unavailable." })
                }
            }
        }

        override fun onBillingServiceDisconnected() {
            // Reconnected lazily on the next billing action.
        }
    })
}

internal fun MainActivity.startGooglePlaySubscribe() {
    val session = syncSession ?: return
    if (purchaseInProgress) return
    // Subscribing is gated on a confirmed email (the backend rejects the verify call
    // otherwise); stop here with a clear prompt rather than launch a billing flow the
    // account can't redeem.
    if (syncEmailVerified == false) {
        showError(
            "Verify your email",
            "Verify your email before subscribing — check your inbox for the link."
        )
        return
    }
    purchaseInProgress = true
    ensureBillingClient { client ->
        val product = QueryProductDetailsParams.Product.newBuilder()
            .setProductId(SYNC_SUBSCRIPTION_PRODUCT_ID)
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(listOf(product))
            .build()
        client.queryProductDetailsAsync(params) { result, productDetailsList ->
            val details = productDetailsList.firstOrNull()
            val offerToken = details?.subscriptionOfferDetails?.firstOrNull()?.offerToken
            if (result.responseCode != BillingClient.BillingResponseCode.OK || details == null || offerToken == null) {
                runOnUiThread {
                    purchaseInProgress = false
                    showError("Subscription unavailable", "The sync subscription isn't available on this device yet.")
                }
                return@queryProductDetailsAsync
            }
            val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(details)
                .setOfferToken(offerToken)
                .build()
            val flowParams = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(productParams))
                // Maps the purchase back to this account server-side (= our user id).
                .setObfuscatedAccountId(session.userId)
                .build()
            runOnUiThread { client.launchBillingFlow(this, flowParams) }
        }
    }
}

internal fun MainActivity.restoreGooglePlayPurchases() {
    if (syncSession == null || purchaseInProgress) return
    ensureBillingClient { client ->
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        client.queryPurchasesAsync(params) { result, purchases ->
            val active = purchases.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
            if (result.responseCode == BillingClient.BillingResponseCode.OK && active != null) {
                purchaseInProgress = true
                verifyGooglePlayPurchase(active)
            } else {
                runOnUiThread {
                    showError("Nothing to restore", "No active Google Play subscription was found for this Google account.")
                }
            }
        }
    }
}

// Send a completed Play purchase to the backend, which reads authoritative state
// from the Play Developer API, grants the entitlement, and acknowledges the
// purchase. The returned (now sync-enabled) session replaces the current one.
internal fun MainActivity.verifyGooglePlayPurchase(purchase: Purchase) {
    val session = syncSession
    if (session == null) {
        runOnUiThread { purchaseInProgress = false }
        return
    }
    Thread {
        val result = runCatching {
            val active = activeSyncSessionForAccountAction(session)
            val productId = purchase.products.firstOrNull() ?: SYNC_SUBSCRIPTION_PRODUCT_ID
            parseSyncSession(
                httpJson(
                    "${active.apiBase}/v1/billing/google/verify",
                    "POST",
                    JSONObject()
                        .put("purchase_token", purchase.purchaseToken)
                        .put("product_id", productId),
                    bearerToken = active.bearerToken,
                    accountAction = true
                ),
                active.apiBase
            )
        }
        runOnUiThread {
            purchaseInProgress = false
            result.onSuccess { updated ->
                installSyncSession(updated)
                if (updated.supportsSync) {
                    showError("Subscribed", "Sync is now enabled on this account.")
                }
            }.onFailure { error ->
                showError("Could not verify purchase", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.startSyncPolling() {
    syncPollHandler.removeCallbacks(syncPollRunnable)
    if (syncSession != null) {
        syncOnce()
        syncPollHandler.postDelayed(syncPollRunnable, 30_000)
    }
}

/// Debounced sync after a local edit, matching desktop's local-change debounce:
/// a burst of edits coalesces into one push (SYNC_EDIT_DEBOUNCE_MS) instead of
/// syncing on every mutation. Leading-window — the first edit of a burst arms
/// the timer and later edits don't postpone it, so continuous typing still
/// pushes within the window (the 30s poll and the onStop flush are the
/// backstops; the in-progress guard handles overlap with the poll).
internal fun MainActivity.requestSyncSoon() {
    if (syncSession == null) return
    if (syncEditPending) return
    syncEditPending = true
    syncPollHandler.postDelayed(syncEditRunnable, SYNC_EDIT_DEBOUNCE_MS)
}

/// Periodic background refresh while signed in — the Android counterpart of
/// the iOS BGAppRefreshTask (3h cadence, network required).
internal fun MainActivity.scheduleBackgroundSyncWork() {
    val workManager = runCatching { WorkManager.getInstance(this) }.getOrNull() ?: return
    val session = syncSession
    if (session == null || !session.supportsSync) {
        workManager.cancelUniqueWork(BACKGROUND_SYNC_WORK)
        return
    }
    val request = PeriodicWorkRequest.Builder(BackgroundSyncWorker::class.java, 3, TimeUnit.HOURS)
        .setConstraints(
            Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        )
        .build()
    workManager.enqueueUniquePeriodicWork(BACKGROUND_SYNC_WORK, ExistingPeriodicWorkPolicy.KEEP, request)
}

internal fun MainActivity.cancelBackgroundSyncWork() {
    runCatching { WorkManager.getInstance(this).cancelUniqueWork(BACKGROUND_SYNC_WORK) }
}

internal fun MainActivity.syncOnce() {
    // The in-progress guard also serializes refresh: two concurrent refreshes
    // would replay the same single-use refresh token and trip the server's
    // reuse detection, revoking the session.
    if (syncInProgress) return
    val session = syncSession ?: return
    if (!session.supportsSync) return
    syncInProgress = true
    Thread {
        // Refresh the short-lived access token if near expiry (rotating +
        // persisting the new credentials). If refresh is temporarily unavailable,
        // skip this tick instead of syncing with an expired bearer token.
        val active = when (val refresh = refreshSyncSessionIfNeeded(session)) {
            is SyncRefreshResult.Ready -> refresh.session
            SyncRefreshResult.Deferred -> {
                runOnUiThread {
                    syncInProgress = false
                    syncOffline = true
                    render()
                }
                return@Thread
            }
            SyncRefreshResult.SessionDead -> {
                runOnUiThread {
                    syncInProgress = false
                    expireSyncSession()
                }
                return@Thread
            }
        }
        if (active !== session) {
            runOnUiThread {
                syncSession = active
                syncOffline = false
                syncFailureNotified = false
                saveSyncSession(active)
            }
        }
        val result = runCatching {
            bridge.request(
                obj(
                    "type" to "sync_once",
                    "api_base" to active.apiBase,
                    "bearer_token" to active.bearerToken
                )
            )
        }
        runOnUiThread {
            syncInProgress = false
            result.onSuccess { response ->
                syncFailureNotified = false
                syncOffline = false
                val changed = response.optBoolean("changed", false)
                if (changed) {
                    loadSnapshot()
                    rescheduleNotifications()
                    render()
                }
                val notice = response.optString("notice", "")
                if (notice.isNotEmpty()) {
                    toast(notice)
                }
            }.onFailure { error ->
                // Non-blocking like the iOS banner, and only on the first
                // failure so an offline session isn't toasted every poll. Transient
                // backend conditions (429 rate-limit, 5xx) are treated like being
                // offline so a brief throttle doesn't surface a scary error toast.
                if (isLikelyNetworkError(error) || isTransientSyncError(error)) {
                    syncOffline = true
                    render()
                    return@onFailure
                }
                if (!syncFailureNotified) {
                    syncFailureNotified = true
                    toast(error.message ?: "Sync failed")
                }
            }
        }
    }.start()
}

internal fun MainActivity.activeSyncSessionForAccountAction(session: SyncSession): SyncSession {
    return when (val refresh = refreshSyncSessionIfNeeded(session)) {
        is SyncRefreshResult.Ready -> {
            persistRotatedSyncSession(session, refresh.session)
            refresh.session
        }
        SyncRefreshResult.Deferred -> throw RuntimeException("Sync is offline. Try again when your connection is back.")
        SyncRefreshResult.SessionDead -> {
            runOnUiThread { expireSyncSession(showMessage = false) }
            throw RuntimeException(accountActionErrorMessage("unauthorized"))
        }
    }
}

internal fun MainActivity.persistRotatedSyncSession(previous: SyncSession, active: SyncSession) {
    if (active === previous || active.refreshToken == previous.refreshToken) return
    saveSyncSession(active)
    runOnUiThread {
        if (syncSession?.refreshToken == previous.refreshToken) {
            syncSession = active
            syncOffline = false
            syncFailureNotified = false
            scheduleBackgroundSyncWork()
            render()
        }
    }
}

internal fun MainActivity.expireSyncSession(showMessage: Boolean = true) {
    syncSession = null
    syncOffline = false
    syncEmailVerified = null
    resendVerificationCooldown = 0
    resendVerificationInProgress = false
    saveSyncSession(null)
    syncPollHandler.removeCallbacks(syncPollRunnable)
    syncPollHandler.removeCallbacks(syncEditRunnable)
    syncEditPending = false
    cancelBackgroundSyncWork()
    if (showMessage) {
        showError("Sync session expired", "Please sign in again.")
    }
    render()
}

// Runs on a background thread (blocking HTTP). SessionDead is only returned
// when the refresh token is explicitly rejected by the auth endpoint. Deferred
// means the current token may be expired but the refresh could not be completed yet.
internal fun MainActivity.refreshSyncSessionIfNeeded(session: SyncSession, force: Boolean = false): SyncRefreshResult {
    val refreshToken = session.refreshToken
    if (refreshToken.isEmpty()) return SyncRefreshResult.Deferred
    if (!force && !tokenNeedsRefresh(session.expiresAt)) return SyncRefreshResult.Ready(session)
    try {
        val connection =
            (URL("${session.apiBase}/v1/auth/refresh").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        val body = JSONObject().put("refresh_token", refreshToken).toString().toByteArray(Charsets.UTF_8)
        connection.outputStream.use { it.write(body) }
        val status = connection.responseCode
        if (isTerminalRefreshErrorCode(refreshApiErrorCode(connection))) {
            return SyncRefreshResult.SessionDead
        }
        if (status !in 200..299) return SyncRefreshResult.Deferred
        val raw = connection.inputStream.bufferedReader().use { it.readText() }
        val json = JSONObject(raw)
        return SyncRefreshResult.Ready(session.copy(
            bearerToken = requiredString(json, "bearer_token"),
            expiresAt = requiredString(json, "expires_at"),
            refreshToken = requiredString(json, "refresh_token"),
            refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null },
            supportsSync = json.optBoolean("supports_sync", true)
        ))
    } catch (error: Exception) {
        // Network/parse hiccup: keep the current token, retry next tick.
        return SyncRefreshResult.Deferred
    }
}

internal fun MainActivity.isLikelyNetworkError(error: Throwable): Boolean {
    var current: Throwable? = error
    while (current != null) {
        if (current is java.io.IOException) return true
        current = current.cause
    }
    val message = error.message.orEmpty().lowercase()
    return listOf(
        "network",
        "request failed",
        "timeout",
        "timed out",
        "unable to resolve",
        "failed to connect",
        "no address associated with hostname"
    ).any(message::contains)
}

// A 429 (rate-limited) or 5xx from the sync backend is transient: the next poll
// should simply retry. The core surfaces these as "sync backend rejected request:
// <code>" (a numeric status when the body wasn't a JSON error, e.g. a Cloudflare
// edge throttle, or "rate_limit_exceeded" from the Worker limiter). Treat them like
// being offline — quiet backoff — instead of toasting an error the user can't act on.
internal fun MainActivity.isTransientSyncError(error: Throwable): Boolean {
    val message = error.message.orEmpty().lowercase()
    if ("rate_limit" in message) return true
    return listOf("429", "500", "502", "503", "504").any { message.endsWith(": $it") }
}

internal fun MainActivity.tokenNeedsRefresh(expiresAt: String): Boolean {
    val expiry = runCatching { java.time.Instant.parse(expiresAt) }.getOrNull() ?: return true
    return expiry.isBefore(java.time.Instant.now().plusSeconds(120))
}

internal fun MainActivity.requestSyncLoginStart(apiBase: String, email: String, password: String): SyncLoginStart {
    val json = httpJson(
        "$apiBase/v1/auth/login",
        "POST",
        JSONObject().put("email", email).put("password", password)
    )
    val challengeId = json.optString("challenge_id")
    if (challengeId.isNotEmpty()) {
        return SyncLoginStart(
            challenge = SyncLoginChallenge(
                apiBase = apiBase,
                email = email,
                challengeId = challengeId,
                devCode = json.optString("dev_code").ifEmpty { null }
            ),
            session = null
        )
    }
    return SyncLoginStart(challenge = null, session = parseSyncSession(json, apiBase))
}

internal fun MainActivity.parseSyncSession(json: JSONObject, apiBase: String): SyncSession =
    SyncSession(
        apiBase = apiBase,
        userId = requiredString(json, "user_id"),
        email = requiredString(json, "email"),
        supportsSync = json.optBoolean("supports_sync", true),
        bearerToken = requiredString(json, "bearer_token"),
        expiresAt = requiredString(json, "expires_at"),
        refreshToken = requiredString(json, "refresh_token"),
        refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
    )

internal fun MainActivity.requiredString(json: JSONObject, key: String): String =
    json.optString(key).takeIf { it.isNotEmpty() }
        ?: throw RuntimeException("Sync API response missing $key.")

internal fun MainActivity.httpJson(
    urlString: String,
    method: String,
    body: JSONObject,
    bearerToken: String? = null,
    accountAction: Boolean = false,
    authorizeAction: Boolean = false
): JSONObject {
    val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
        requestMethod = method
        connectTimeout = 10_000
        readTimeout = 10_000
        doInput = true
        doOutput = method != "GET"
        setRequestProperty("Content-Type", "application/json")
        bearerToken?.let { setRequestProperty("Authorization", "Bearer $it") }
    }
    if (method != "GET") {
        connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
    }
    val status = connection.responseCode
    val raw = if (status in 200..299) {
        connection.inputStream.bufferedReader().use { it.readText() }
    } else {
        connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }
    if (status !in 200..299) {
        val code = runCatching { JSONObject(raw).optString("code") }.getOrDefault("")
        throw RuntimeException(
            when {
                accountAction -> accountActionErrorMessage(code)
                authorizeAction -> authorizeErrorMessage(code)
                else -> syncErrorMessage(code)
            }
        )
    }
    return if (raw.isBlank()) JSONObject() else JSONObject(raw)
}

internal fun MainActivity.loadSyncSession(): SyncSession? {
    val raw = getSharedPreferences("knotq", Context.MODE_PRIVATE).getString(SYNC_SESSION_PREF, null)
        ?: return null
    return runCatching {
        val json = JSONObject(raw)
        SyncSession(
            apiBase = normalizeApiBase(json.optString("api_base")),
            userId = json.optString("user_id"),
            email = json.optString("email"),
            supportsSync = json.optBoolean("supports_sync", true),
            bearerToken = json.optString("bearer_token"),
            expiresAt = json.optString("expires_at"),
            refreshToken = json.optString("refresh_token").takeIf { it.isNotEmpty() }
                ?: throw RuntimeException("stored sync session missing refresh token"),
            refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
        )
    }.getOrNull()
}

internal fun MainActivity.saveSyncSession(session: SyncSession?) {
    val prefs = getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
    if (session == null) {
        prefs.remove(SYNC_SESSION_PREF)
    } else {
        prefs.putString(
            SYNC_SESSION_PREF,
            JSONObject()
                .put("api_base", session.apiBase)
                .put("user_id", session.userId)
                .put("email", session.email)
                .put("supports_sync", session.supportsSync)
                .put("bearer_token", session.bearerToken)
                .put("expires_at", session.expiresAt)
                .put("refresh_token", session.refreshToken)
                .put("refresh_expires_at", session.refreshExpiresAt ?: JSONObject.NULL)
                .toString()
        )
    }
    prefs.apply()
}

internal fun MainActivity.normalizeApiBase(raw: String): String =
    raw.trim().trimEnd('/')

internal fun MainActivity.syncErrorMessage(code: String): String = when (code) {
    "account_exists" -> "An account already exists for that email."
    "invalid_email" -> "Enter a valid email address."
    "password_too_short" -> "Use a password with at least 12 characters."
    "unauthorized" -> "Email or password is incorrect."
    "password_too_long" -> "Password is too long."
    "invalid_code" -> "That code is incorrect."
    "code_expired", "invalid_or_expired_code" -> "That code has expired. Sign in again to get a new one."
    "too_many_attempts" -> "Too many incorrect codes. Sign in again to get a new one."
    else -> "Sync account request failed."
}

internal fun MainActivity.authorizeErrorMessage(code: String): String = when (code) {
    "invalid_authorization_code", "authorization_code_expired", "invalid_code_challenge" ->
        "Sign-in could not be completed. Please try signing in again."
    else -> "Sign in failed."
}

internal fun MainActivity.accountActionErrorMessage(code: String): String = when (code) {
    "unauthorized" -> "Your sync session expired. Sign in again, then retry."
    "delete_confirmation_mismatch" -> "Could not confirm the account. Please try again."
    "billing_api_not_configured" -> "Subscription cancellation is not configured yet."
    "cancel_in_app_store" -> "Manage this App Store subscription from your account subscriptions."
    "cancel_in_play_store" -> "Manage this subscription from your Google Play subscriptions."
    "resume_in_app_store" -> "Re-enable this subscription from your Apple account subscriptions."
    "resume_in_play_store" -> "Re-enable this subscription from your Google Play subscriptions."
    "no_active_subscription" -> "There's no active web subscription to change."
    "invalid_code" -> "That code is incorrect."
    "code_expired", "invalid_or_expired_code" -> "That code has expired. Start the deletion again to get a new one."
    "too_many_attempts" -> "Too many incorrect codes. Start the deletion again to get a new one."
    else -> "The request to the sync API failed."
}

internal fun MainActivity.startGoogleCalendarImport(parentId: String? = null) {
    if (googleAuthInProgress) return
    googleAuthInProgress = true
    Thread {
        // Loopback-redirect PKCE flow, mirroring the desktop Google OAuth path: bind a
        // local socket on 127.0.0.1, hand Google "http://127.0.0.1:<port>" as the
        // redirect URI, then read the authorization code straight off the socket. No
        // custom URI scheme / intent-filter is involved, which is what lets this work
        // with a Desktop ("installed") OAuth client instead of an iOS one.
        val server = runCatching {
            ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        }.getOrElse { error ->
            runOnUiThread {
                googleAuthInProgress = false
                showError("Google Calendar", error.message)
            }
            return@Thread
        }
        server.soTimeout = GOOGLE_OAUTH_LOOPBACK_TIMEOUT_MS
        val redirectUri = "http://127.0.0.1:${server.localPort}"

        val request = runCatching {
            bridge.request(
                obj(
                    "type" to "google_auth_request",
                    "client_id" to GOOGLE_CLIENT_ID,
                    "redirect_uri" to redirectUri
                )
            )
        }.getOrElse { error ->
            runCatching { server.close() }
            runOnUiThread {
                googleAuthInProgress = false
                showError("Google Calendar", error.message)
            }
            return@Thread
        }

        pendingGoogleAuthRequest = request
        pendingGoogleParentId = parentId
        runOnUiThread {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(request.getString("auth_url"))))
            } catch (error: ActivityNotFoundException) {
                googleAuthInProgress = false
                runCatching { server.close() } // unblocks the accept() below so the thread exits
                showError("Google Calendar", error.message)
            }
        }

        // Block (bounded by soTimeout) until the browser redirects to our loopback
        // socket. A timeout, an abandoned flow, or the close() above all surface as null.
        val callbackUrl = runCatching {
            server.use { srv ->
                srv.accept().use { socket -> readLoopbackCallbackUrl(socket, redirectUri) }
            }
        }.getOrNull()

        if (callbackUrl == null) {
            runOnUiThread {
                if (googleAuthInProgress) {
                    googleAuthInProgress = false
                    googleCalendarStatus = "Google Calendar sign-in was canceled."
                    render()
                }
            }
            return@Thread
        }

        runOnUiThread {
            bringActivityToFront() // best-effort return to the app; background launch may be blocked
            completeGoogleCalendarImport(request, callbackUrl, parentId)
        }
    }.start()
}

// Reads the single GET request the browser makes to the loopback redirect, writes a
// minimal "you can close this" page back, and returns the full callback URL (including
// the ?code=...&state=... query) for the core to validate and exchange.
private fun readLoopbackCallbackUrl(socket: Socket, redirectUri: String): String {
    val requestLine = socket.getInputStream().bufferedReader().readLine()
        ?: throw IOException("empty OAuth callback request")
    // e.g. "GET /?state=...&code=... HTTP/1.1"
    val target = requestLine.split(' ').getOrNull(1)
        ?: throw IOException("malformed OAuth callback request")
    val body = "<html><body style=\"font-family:sans-serif;text-align:center;padding-top:3em\">" +
        "<h2>KnotQ</h2><p>Google sign-in complete. You can close this tab and return to the app.</p>" +
        "</body></html>"
    val response = "HTTP/1.1 200 OK\r\n" +
        "Content-Type: text/html; charset=utf-8\r\n" +
        "Content-Length: ${body.toByteArray().size}\r\n" +
        "Connection: close\r\n\r\n" + body
    socket.getOutputStream().apply {
        write(response.toByteArray())
        flush()
    }
    return redirectUri + target
}

private fun MainActivity.bringActivityToFront() {
    runCatching {
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        )
    }
}

internal fun MainActivity.completeGoogleCalendarImport(request: JSONObject, callbackUrl: String, parentId: String?) {
    googleAuthInProgress = true
    Thread {
        val result = runCatching {
            bridge.request(
                obj(
                    "type" to "complete_google_calendar_import",
                    "client_id" to request.getString("client_id"),
                    "redirect_uri" to request.getString("redirect_uri"),
                    "state" to request.getString("state"),
                    "code_verifier" to request.getString("code_verifier"),
                    "callback_url" to callbackUrl,
                    "parent_id" to parentId
                )
            )
        }
        runOnUiThread {
            googleAuthInProgress = false
            clearPendingGoogleAuth()
            result.onSuccess { response ->
                googleCalendarStatus = response.optString("message")
                loadSnapshot()
                rescheduleNotifications()
                render()
                if (syncSession != null) syncOnce()
            }.onFailure { error ->
                showError("Google Calendar", error.message)
            }
        }
    }.start()
}

internal fun MainActivity.syncGoogleCalendars(silent: Boolean = false) {
    if (googleSyncInProgress) return
    if ((snapshot.optJSONObject("settings")?.optInt("google_account_count", 0) ?: 0) <= 0) return
    googleSyncInProgress = true
    Thread {
        val result = runCatching {
            bridge.request(
                obj(
                    "type" to "sync_google_calendars"
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
    pendingGoogleAuthRequest = null
    pendingGoogleParentId = null
    getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
        .remove("knotq.googleAuthRequest")
        .remove("knotq.googleAuthParentId")
        .apply()
}
