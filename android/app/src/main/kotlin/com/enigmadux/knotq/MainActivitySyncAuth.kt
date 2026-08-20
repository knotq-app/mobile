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
    // Accounts/sign-in are compiled out of release builds.
    if (!BuildConfig.ACCOUNTS_ENABLED) {
        toast(L10n.t(this, "mobile.sync.state_off"))
        return
    }
    if (syncSession != null) {
        val session = syncSession ?: return
        // Lead with the action that matters for the current state: syncing when
        // it is on, subscribing when it is off. Destructive actions stay last.
        val subscriptionLabel =
            if (syncSubscriptionCancelled) L10n.t(this, "account.menu.reenable_subscription") else L10n.t(this, "account.confirm.cancel_subscription_confirm")
        val subscriptionHandler: () -> Unit =
            if (syncSubscriptionCancelled) { { reEnableSyncSubscription() } } else { { cancelSubscriptionAction() } }
        val needsVerification = !session.supportsSync && syncEmailVerified == false
        val actions: List<String>
        val handlers: List<() -> Unit>
        if (session.supportsSync) {
            // "Resync" is the dedicated card button (iOS parity), so this menu is
            // just account housekeeping.
            actions = listOf(subscriptionLabel, L10n.t(this, "account.menu.sign_out"), L10n.t(this, "mobile.account.delete_account"))
            handlers = listOf(subscriptionHandler, { signOutSync() }, { confirmDeleteSyncAccount() })
        } else if (needsVerification) {
            // Subscribing is blocked until the email is verified, so offer the resend
            // instead of a Subscribe entry that would fail.
            actions = listOf(
                L10n.t(this, "account.verify.resend"),
                L10n.t(this, "mobile.sync.restore_purchases"),
                L10n.t(this, "account.menu.sign_out"),
                L10n.t(this, "mobile.account.delete_account")
            )
            handlers = listOf(
                { resendVerificationEmail() },
                { restoreGooglePlayPurchases() },
                { signOutSync() },
                { confirmDeleteSyncAccount() }
            )
        } else {
            actions = listOf(
                L10n.t(this, "mobile.sync.subscribe_google_play"),
                L10n.t(this, "mobile.sync.restore_purchases"),
                L10n.t(this, "account.menu.sign_out"),
                L10n.t(this, "mobile.account.delete_account")
            )
            handlers = listOf(
                { startGooglePlaySubscribe() },
                { restoreGooglePlayPurchases() },
                { signOutSync() },
                { confirmDeleteSyncAccount() }
            )
        }
        val stateLine = when {
            syncOffline -> L10n.t(this, "mobile.sync.state_offline")
            session.supportsSync && syncSubscriptionCancelled ->
                L10n.t(this, "mobile.sync.state_cancelled")
            session.supportsSync -> L10n.t(this, "mobile.sync.state_on")
            needsVerification -> L10n.t(this, "mobile.sync.state_needs_verification")
            else -> L10n.t(this, "mobile.sync.state_off")
        }
        // NOTE: AlertDialog shows EITHER a message OR an items list, not both
        // (message wins). This is the "Manage" menu, so the actions must render —
        // the email + state (Enabled/Offline/Cancelled badge) already show on the
        // sync card, so carry only a concise state line in the title here.
        AlertDialog.Builder(this)
            .setTitle(stateLine)
            .setItems(actions.toTypedArray()) { _, which -> handlers[which]() }
            .setNegativeButton(L10n.t(this, "common.close"), null)
            .show()
        // Re-check the lifecycle so a cancellation made elsewhere is reflected.
        refreshAccountStatus()
        return
    }

    syncLoginChallenge = null

    AlertDialog.Builder(this)
        .setTitle(L10n.t(this, "mobile.sync.dialog_title"))
        .setMessage(L10n.t(this, "mobile.sync.browser_signin_message"))
        .setNegativeButton(L10n.t(this, "common.cancel"), null)
        .setNeutralButton(L10n.t(this, "mobile.sync.create_account")) { _, _ -> beginBrowserSyncAuth(createAccount = true) }
        .setPositiveButton(L10n.t(this, "sync.sign_in")) { _, _ -> beginBrowserSyncAuth(createAccount = false) }
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
        Toast.makeText(this, L10n.t(this, "mobile.sync.continue_in_browser"), Toast.LENGTH_SHORT).show()
    } catch (error: ActivityNotFoundException) {
        clearPendingSyncBrowserAuth()
        showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), error.message)
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
        showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), L10n.t(this, "mobile.sync.callback_state_mismatch"))
        return true
    }
    val errorCode = uri.getQueryParameter("error").orEmpty()
    if (errorCode.isNotEmpty()) {
        clearPendingSyncBrowserAuth()
        showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), authorizeErrorMessage(errorCode))
        return true
    }
    val code = uri.getQueryParameter("code").orEmpty()
    if (code.isEmpty()) {
        clearPendingSyncBrowserAuth()
        showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), L10n.t(this, "mobile.sync.callback_incomplete"))
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
                Toast.makeText(this, L10n.t(this, "mobile.sync.signed_in_as", mapOf("email" to session.email)), Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), error.message)
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
        showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), L10n.t(this, "mobile.sync.enter_credentials_prompt"))
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
                    Toast.makeText(this, L10n.t(this, "mobile.sync.signed_in_as", mapOf("email" to session.email)), Toast.LENGTH_SHORT).show()
                } else if (start.challenge != null) {
                    syncLoginChallenge = start.challenge
                    showLoginCodeDialog(start.challenge)
                }
            }.onFailure { error ->
                showError(L10n.t(this, "mobile.sync.sign_in_failed_title"), error.message)
            }
        }
    }.start()
}

internal fun MainActivity.createSyncAccount(apiBaseRaw: String, emailRaw: String, password: String) {
    if (syncAuthInProgress) return
    val apiBase = normalizeApiBase(apiBaseRaw)
    val email = emailRaw.trim()
    if (apiBase.isEmpty() || email.isEmpty() || password.isEmpty()) {
        showError(L10n.t(this, "mobile.sync.account_creation_failed_title"), L10n.t(this, "mobile.sync.enter_credentials_prompt"))
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
                Toast.makeText(this, L10n.t(this, "mobile.sync.signed_in_as", mapOf("email" to session.email)), Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError(L10n.t(this, "mobile.sync.account_creation_failed_title"), error.message)
            }
        }
    }.start()
}

internal fun MainActivity.showLoginCodeDialog(challenge: SyncLoginChallenge) {
    val form = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), 0)
    }
    form.addView(text(L10n.t(this, "mobile.sync.enter_code_sent_to", mapOf("email" to challenge.email)), theme.textDim, 13f, false), spaced())
    val code = EditText(this).apply {
        hint = L10n.t(this@showLoginCodeDialog, "mobile.sync.code_hint_label")
        setText(challenge.devCode.orEmpty())
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        setSingleLine(true)
    }
    form.addView(code)
    val dialog = AlertDialog.Builder(this)
        .setTitle(L10n.t(this, "mobile.sync.verify_sign_in_title"))
        .setView(form)
        .setNegativeButton(L10n.t(this, "common.cancel"), null)
        .setNeutralButton(L10n.t(this, "mobile.sync.different_account"), null)
        .setPositiveButton(L10n.t(this, "mobile.sync.verify_button"), null)
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
        showError(L10n.t(this, "mobile.sync.verification_failed_title"), L10n.t(this, "mobile.sync.enter_code_prompt"))
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
                Toast.makeText(this, L10n.t(this, "mobile.sync.signed_in_as", mapOf("email" to session.email)), Toast.LENGTH_SHORT).show()
                syncOnce()
            }.onFailure { error ->
                showError(L10n.t(this, "mobile.sync.verification_failed_title"), error.message)
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
    // The account prompt is the last onboarding step (after the tour), so signing
    // in there completes onboarding.
    if (onboardingActive && onboardingPhase == ONBOARDING_ACCOUNT) {
        finishOnboarding()
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
