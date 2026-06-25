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
                    render()
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
    if (syncSession == null) return
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
    // Disclose the auto-renew terms and surface the Terms of Use / Privacy Policy
    // before launching the Play billing sheet (the sheet itself shows price and
    // period). Mirrors the iOS paywall disclosure (Guideline 3.1.2 / Play policy).
    showSubscriptionDisclosure { launchSyncBillingFlow() }
}

private fun MainActivity.showSubscriptionDisclosure(onContinue: () -> Unit) {
    val form = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(8), dp(20), 0)
    }
    form.addView(
        text(
            "KnotQ Sync is an auto-renewing subscription billed through your Google " +
                "Play account. It renews automatically each period unless you cancel at " +
                "least 24 hours before the period ends; manage or cancel anytime in Google " +
                "Play. The price and billing period are shown on the next screen.",
            theme.textDim,
            13f,
            false
        ),
        spaced()
    )
    val links = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
    links.addView(
        text("Terms of Use", theme.accent, 13f, true).apply {
            setPadding(0, dp(4), dp(18), dp(2))
            setOnClickListener { openSubscriptionStorePage(TERMS_OF_USE_URL) }
        }
    )
    links.addView(
        text("Privacy Policy", theme.accent, 13f, true).apply {
            setPadding(0, dp(4), 0, dp(2))
            setOnClickListener { openSubscriptionStorePage(PRIVACY_POLICY_URL) }
        }
    )
    form.addView(links)
    AlertDialog.Builder(this, alertDialogTheme())
        .setTitle("KnotQ Sync subscription")
        .setView(form)
        .setNegativeButton("Cancel", null)
        .setPositiveButton("Continue") { _, _ -> onContinue() }
        .show()
}

private fun MainActivity.launchSyncBillingFlow() {
    val session = syncSession ?: return
    if (purchaseInProgress) return
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
                    render()
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
                render()
                showError("Could not verify purchase", error.message)
            }
        }
    }.start()
}
