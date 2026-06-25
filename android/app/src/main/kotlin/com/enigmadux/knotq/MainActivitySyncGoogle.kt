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
