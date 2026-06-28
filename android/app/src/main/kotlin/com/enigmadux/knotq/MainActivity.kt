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
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt


class MainActivity : Activity() {
    internal lateinit var bridge: RustBridge
    internal lateinit var rootFrame: FrameLayout
    internal lateinit var shell: LinearLayout
    internal lateinit var titleBar: LinearLayout
    internal lateinit var content: FrameLayout
    internal lateinit var dock: LinearLayout
    internal lateinit var theme: UiTheme

    // First-run onboarding overlay state. The overlay lives in `rootFrame` as a
    // sibling of `shell`, so it survives `render()` (which only rebuilds shell).
    internal var onboardingActive = false
    internal var onboardingPhase = ONBOARDING_ACCOUNT
    internal var onboardingStep = 0
    internal var onboardingOverlay: View? = null

    internal var snapshot = JSONObject()
    internal var selectedTab = TAB_HOME
    internal var weekOffset = 0
    internal var selectedDate: LocalDate = LocalDate.now()
    // Calendar day the UI is anchored to, so onStart can notice a midnight
    // rollover and advance the daily/home "today" instead of staying stuck on
    // yesterday when the app is reopened the next day without a restart.
    internal var anchoredDay: LocalDate = LocalDate.now()
    internal var selectedSchemeId: String? = null
    // Tab the scheme editor was entered from, so its back button returns there.
    internal var schemeReturnTab = TAB_HOME
    internal var keyboardActive = false
    // Preserve the calendar timeline scroll position across incidental re-renders
    // (e.g. toggling an item done); reset to the now/morning anchor on day change.
    internal var calendarScrollY = 0
    internal var calendarScrollDate: String? = null
    // Folders the user collapsed in the scheme navigator (new folders default
    // to expanded, like iOS).
    internal val collapsedFolderIds = HashSet<String>()
    // Settings sub-page showing the hierarchical archive (iOS "Archived Items").
    internal var settingsShowingArchive = false
    // Daily feed paging + scroll anchoring, mirroring the iOS bottom-pinned
    // feed: history grows by a month each time the user scrolls to the top.
    internal var dailyHistoryDays = 3
    internal var dailyHistoryLoadTriggerDate: String? = null
    internal var dailyScrollY = 0
    internal var dailyScrollDate: String? = null
    internal var pendingDailyAnchorDate: String? = null
    internal var pendingDailyAutoFocusDate: String? = null
    internal var lastRenderedTab: Int? = null
    internal val editorSchemeIds = WeakHashMap<EditText, String>()
    // The FrameLayout wrapping each editor, used to float the inline table-cell
    // editor over a tapped cell.
    internal val editorHosts = WeakHashMap<EditText, FrameLayout>()
    internal var lastActiveEditor: EditText? = null
    internal var suppressEditorBlurCommit = false
    // Pending debounced live flush of the active editor into the core (push-on-type).
    internal var editorFlushRunnable: Runnable? = null
    // Serial executor for core WRITES (edits/flushes), so they run OFF the main
    // thread — a sync run holds the core lock across network I/O, and doing a core
    // write on the UI thread blocks (hangs) until that lock frees. Single-threaded
    // = FIFO, so edit order is preserved (like iOS's serial bridge queue).
    internal val coreExecutor: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor()
    // The inline cell editor currently shown (if any), so a second tap commits
    // the first before moving on.
    internal var activeCellEdit: ActiveCellEdit? = null
    internal var tableStructureDialogOpen = false

    // Re-tints the format bar's marker buttons for the caret's line; rebuilt
    // with each rendered format bar and invoked from editor selection changes.
    internal var formatBarMarkerRefresh: (() -> Unit)? = null
    // Keep the format bar's horizontal scroll position across re-renders.
    internal var formatBarScrollX = 0
    // The bottom format bar's FrameLayout host plus its two interchangeable
    // contents: the normal format controls and (while a table cell is open) the
    // cell controls that replace them, matching iOS.
    internal var formatBarHost: FrameLayout? = null
    internal var formatBarNormalContent: View? = null
    internal var formatBarCellContent: View? = null
    // Scheme + line awaiting an image pick from the system photo chooser.
    internal var pendingImageAttach: Pair<String, Int>? = null
    internal var syncSession: SyncSession? = null
    internal var syncLoginChallenge: SyncLoginChallenge? = null
    internal var syncAuthInProgress = false
    internal var syncAccountActionInProgress = false
    internal var syncInProgress = false
    // From /v1/auth/account/status: the subscription is cancelled (won't renew) but
    // still entitling, so Settings offers to re-enable instead of cancel. The
    // provider routes re-enable to the store (Google/Apple) or our backend (web).
    internal var syncSubscriptionCancelled = false
    internal var syncSubscriptionProvider: String? = null
    // From /v1/auth/account/status: whether the account email is confirmed. `null`
    // until checked. Subscribing is gated on a confirmed email, so the Sync card
    // blocks the purchase action and prompts to verify when this is false.
    internal var syncEmailVerified: Boolean? = null
    internal var resendVerificationInProgress = false
    // Frontend cooldown (seconds remaining) for the resend action, a soft limit on
    // top of the backend's own rate limit.
    internal var resendVerificationCooldown = 0
    internal var syncFailureNotified = false
    internal var syncOffline = false
    internal var safeAreaTop = 0
    internal var safeAreaBottom = 0
    internal var billingClient: BillingClient? = null
    internal var purchaseInProgress = false
    internal var googleAuthInProgress = false
    internal var googleSyncInProgress = false
    internal var googleSyncPollingActive = false
    internal var googleCalendarStatus: String? = null
    internal var pendingGoogleAuthRequest: JSONObject? = null
    internal var pendingGoogleParentId: String? = null
    internal val syncPollHandler = Handler(Looper.getMainLooper())
    internal val syncPollRunnable = object : Runnable {
        override fun run() {
            syncOnce()
            syncPollHandler.postDelayed(this, 30_000)
        }
    }
    // True while the post-edit push is waiting out SYNC_EDIT_DEBOUNCE_MS, so a
    // burst of edits arms the timer once (leading-window) and onStop knows to
    // flush a still-pending edit before the app leaves the foreground.
    internal var syncEditPending = false
    // Drives the background WebSocket "changed" nudge poll while in the foreground.
    @Volatile
    internal var wsNudgeActive = false
    // Debounced sync triggered right after each local edit, matching desktop's
    // local-change debounce: rapid edits coalesce into one push instead of
    // syncing on every mutation.
    internal val syncEditRunnable = object : Runnable {
        override fun run() {
            // If a sync is already running, don't drop this edit — retry shortly so
            // it isn't stranded until some other trigger (there's no foreground poll
            // backstop now). Keep syncEditPending set so the retry stays armed.
            if (syncInProgress) {
                syncPollHandler.postDelayed(this, 500)
                return
            }
            syncEditPending = false
            syncOnce()
        }
    }
    internal val googleSyncHandler = Handler(Looper.getMainLooper())
    internal val googleSyncRunnable = object : Runnable {
        override fun run() {
            syncGoogleCalendars(silent = true)
            googleSyncHandler.postDelayed(this, GOOGLE_SYNC_INTERVAL_MS)
        }
    }

    companion object {
        // The background sync worker runs in this process: it reuses the live
        // bridge when the activity exists (two open cores would clobber each
        // other's in-memory workspace) and skips work while in the foreground.
        @Volatile internal var sharedBridge: RustBridge? = null
        @Volatile internal var isInForeground = false
    }

    internal val purchasesUpdatedListener = PurchasesUpdatedListener { result, purchases ->
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val purchase = purchases?.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                if (purchase != null) {
                    verifyGooglePlayPurchase(purchase)
                } else {
                    runOnUiThread { purchaseInProgress = false; render() }
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED ->
                runOnUiThread { purchaseInProgress = false; render() }
            else -> runOnUiThread {
                purchaseInProgress = false
                render()
                showError("Purchase failed", result.debugMessage.ifEmpty { "Could not complete the purchase." })
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            bridge = RustBridge(this)
            syncSession = loadSyncSession()
            loadSnapshot()
            val seededScreenshotFixture = seedScreenshotFixtureIfRequested()
            ensureTodayDailyQueue()
            applyTheme()
            buildShell()
            render()
            if (!seededScreenshotFixture) maybeStartOnboarding()
            // Notification permission is requested *after* onboarding finishes
            // (iOS parity — see finishOnboarding), so the system dialog doesn't
            // pop over the sign-in sheet. Returning users who've already onboarded
            // (onboarding didn't start) get asked here on launch as before.
            if (!seededScreenshotFixture && !onboardingActive) {
                MobileNotificationScheduler.requestPermission(this)
            }
            rescheduleNotifications()
            sharedBridge = bridge
            registerForPushNotifications()
            handleIncomingAuthIntent(intent?.data)
        } catch (error: Throwable) {
            theme = UiTheme.dark
            showFatal(error.message)
        }
    }

    override fun onStart() {
        super.onStart()
        isInForeground = true
        if (!::bridge.isInitialized) return
        // Pick up credentials the background worker may have rotated (or a
        // session it invalidated) while the app was backgrounded.
        syncSession = loadSyncSession()
        // Re-check the entitlement + subscription lifecycle before resuming the poll
        // so a subscription bought (or changed) while the app was closed — the common
        // "subscribe, reopen the app, see it" flow — shows up without waiting for the
        // access token to expire. Runs first so it claims the in-progress guard ahead
        // of the poll's first sync (which then no-ops until it returns).
        refreshSubscriptionStatus()
        startSyncPolling()
        configureGoogleSyncPolling()
        // The app may have been backgrounded across midnight; roll the daily/home
        // "today" forward so it isn't stuck on yesterday.
        handleDayRolloverIfNeeded()
    }

    // Re-anchor to the current day after a rollover. If the user was parked on
    // what used to be "today", advance the selected date with it; otherwise keep
    // their selection but still rebuild so today's daily queue exists and the
    // "today" markers refresh. No-ops while the day is unchanged.
    internal fun handleDayRolloverIfNeeded() {
        if (!::bridge.isInitialized) return
        val today = LocalDate.now()
        if (today == anchoredDay) return
        val wasOnPreviousToday = selectedDate == anchoredDay
        anchoredDay = today
        if (wasOnPreviousToday) {
            selectedDate = today
            weekOffset = 0
        }
        ensureTodayDailyQueue()
        loadSnapshot()
        rescheduleNotifications()
        render()
    }

    override fun onResume() {
        super.onResume()
        if (!::bridge.isInitialized) return
        maybeRequestStoreReview()
    }

    override fun onStop() {
        isInForeground = false
        syncPollHandler.removeCallbacks(syncPollRunnable)
        // Tear the socket down in the background (FCM + the 3h refresh cover wakeups).
        stopWsNudge()
        stopWsSync()
        val flushEditSync = syncEditPending
        syncPollHandler.removeCallbacks(syncEditRunnable)
        syncEditPending = false
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        googleSyncPollingActive = false
        if (::bridge.isInitialized) {
            // Mirror iOS applicationDidEnterBackground: keep workspace data fresh
            // via periodic background refresh while signed in to sync.
            scheduleBackgroundSyncWork()
            // A debounced edit hadn't pushed yet — flush it via a one-off worker so
            // backgrounding right after typing doesn't strand the change until the
            // 3 h refresh. Mirrors iOS flushPendingEditSync().
            if (flushEditSync) enqueueOneTimeSync(this)
        }
        super.onStop()
    }

    override fun onDestroy() {
        syncPollHandler.removeCallbacks(syncPollRunnable)
        syncPollHandler.removeCallbacks(syncEditRunnable)
        syncEditPending = false
        stopWsNudge()
        stopWsSync()
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        billingClient?.endConnection()
        billingClient = null
        sharedBridge = null
        if (::bridge.isInitialized) {
            bridge.close()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingAuthIntent(intent?.data)
    }

    internal fun maybeRequestStoreReview() {
        val prefs = getSharedPreferences("knotq", MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val firstLaunchAt = reviewUsageStartAt(prefs, now)

        if (!prefs.getBoolean(ONBOARDING_PREF, false)) return
        if (prefs.getBoolean(REVIEW_PROMPTED_PREF, false)) return
        if (now - firstLaunchAt < REVIEW_MIN_USAGE_MS) return

        prefs.edit().putBoolean(REVIEW_PROMPTED_PREF, true).apply()
        val manager = runCatching { ReviewManagerFactory.create(this) }.getOrNull() ?: return
        runCatching {
            manager.requestReviewFlow().addOnCompleteListener { request ->
                if (!request.isSuccessful) return@addOnCompleteListener
                if (!isInForeground || isFinishing || isDestroyed) return@addOnCompleteListener
                manager.launchReviewFlow(this, request.result)
            }
        }
    }

    internal fun reviewUsageStartAt(prefs: android.content.SharedPreferences, now: Long): Long {
        val stored = prefs.getLong(REVIEW_FIRST_LAUNCH_AT_PREF, 0L)
        if (stored > 0L) return stored

        val inferred = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0)
                ).firstInstallTime
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0).firstInstallTime
            }
        }.getOrDefault(now).takeIf { it > 0L } ?: now

        prefs.edit().putLong(REVIEW_FIRST_LAUNCH_AT_PREF, inferred).apply()
        return inferred
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        if (selectedTab == TAB_SETTINGS && settingsShowingArchive) {
            settingsShowingArchive = false
            render()
            return
        }
        if (selectedTab == TAB_SEARCH) {
            exitSearch()
            return
        }
        super.onBackPressed()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (MobileNotificationScheduler.isNotificationPermissionRequest(requestCode)) {
            rescheduleNotifications()
        }
    }

    internal fun buildShell() {
        shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        titleBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(10), 0)
            setBackgroundColor(theme.bgToolbar)
        }
        content = FrameLayout(this).apply {
            setBackgroundColor(theme.bgApp)
        }
        dock = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(6), dp(5), dp(6), dp(5))
        }

        shell.addView(titleBar, LinearLayout.LayoutParams(-1, dp(38)))
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        // Host the shell inside a root frame so the onboarding overlay can sit on
        // top of (and survive) `render()`, which only rebuilds the shell's children.
        rootFrame = FrameLayout(this).apply {
            setBackgroundColor(theme.bgApp)
        }
        rootFrame.addView(shell, FrameLayout.LayoutParams(-1, -1))
        setContentView(rootFrame)
        installSafeAreaInsets()
        installKeyboardVisibilityWatcher()
    }

    internal fun render() {
        if (!::content.isInitialized) return
        if (lastRenderedTab != TAB_DAILY && selectedTab == TAB_DAILY) {
            pendingDailyAutoFocusDate = selectedDate.toString()
        }
        lastRenderedTab = selectedTab
        // The whole view tree (including any floating inline cell editor) is
        // rebuilt below; drop the stale reference without re-committing.
        activeCellEdit = null
        applyTheme()
        rootFrame.setBackgroundColor(theme.bgApp)
        shell.setBackgroundColor(theme.bgApp)
        applySafeAreaPadding()
        titleBar.setBackgroundColor(theme.bgToolbar)
        content.setBackgroundColor(theme.bgApp)

        renderTitleBar()
        currentFocus?.clearFocus()
        content.clearFocus()
        content.removeAllViews()
        editorSchemeIds.clear()
        editorHosts.clear()
        lastActiveEditor = null
        val wide = isWideLayout()
        updateChromeVisibility()
        val view = if (wide) renderWideShell() else renderPhoneMain()
        content.addView(view, FrameLayout.LayoutParams(-1, -1))
        renderDock()
        if (shouldShowPhoneQuickActions()) {
            content.addView(homeFloatingActions(), FrameLayout.LayoutParams(-2, dp(58), Gravity.BOTTOM or Gravity.RIGHT).apply {
                setMargins(0, 0, dp(22), dp(83))
            })
        }
        if (shouldShowPhoneDock()) {
            content.addView(dock, FrameLayout.LayoutParams(-2, dp(58), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                setMargins(0, 0, 0, dp(6))
            })
        }
        updateChromeVisibility()
    }

    internal fun renderAfterEditorMutation() {
        suppressEditorBlurCommit = true
        render()
        rootFrame.post { suppressEditorBlurCommit = false }
    }

    internal fun renderTitleBar() {
        titleBar.removeAllViews()
        titleBar.addView(
            if (selectedTab == TAB_HOME) brandMark(20) else colorSquare(titleColor(), 18),
            LinearLayout.LayoutParams(dp(if (selectedTab == TAB_HOME) 20 else 18), dp(if (selectedTab == TAB_HOME) 20 else 18))
        )
        titleBar.addView(text(titleText(), theme.textPrimary, 14f, true).apply {
            gravity = Gravity.CENTER
            maxLines = 1
        }, LinearLayout.LayoutParams(0, -1, 1f))

        titleBar.addView(iconActionChip(GLYPH_SEARCH, "Search") {
            selectedTab = TAB_SEARCH
            selectedSchemeId = null
            render()
        }, marginRight(dp(6), -2, dp(28)))
        titleBar.addView(iconActionChip(GLYPH_CLOUD, syncSession?.email ?: "Sign in") {
            showSyncAccountDialog()
        }, marginRight(dp(6), dp(104), dp(28)))
        titleBar.addView(chip(GLYPH_ADD) { showNewMenu() }, LinearLayout.LayoutParams(dp(32), dp(28)))
    }

    internal fun renderDock() {
        dock.removeAllViews()
        dock.background = rounded(theme.bgToolbar, dp(30), theme.borderOverlay, max(1, (0.5f * resources.displayMetrics.density).roundToInt()))
        dock.elevation = dp(if (theme.isDark) 8 else 2).toFloat()
        listOf(
            Triple(TAB_HOME, R.drawable.ic_knotq_home_24, "Home"),
            Triple(TAB_CALENDAR, R.drawable.ic_knotq_calendar_24, "Calendar"),
            Triple(TAB_SETTINGS, R.drawable.ic_knotq_gear_24, "Settings")
        ).forEach { (index, iconRes, label) ->
            val selected = when (index) {
                TAB_HOME -> selectedTab == TAB_HOME || selectedTab in listOf(TAB_SCHEMES, TAB_DAILY, TAB_SEARCH)
                else -> selectedTab == index
            }
            dock.addView(dockButton(iconRes, label, selected) {
                selectedTab = index
                selectedSchemeId = null
                settingsShowingArchive = false
                if (index == TAB_CALENDAR && selectedDate != LocalDate.now()) {
                    selectedDate = LocalDate.now()
                    weekOffset = 0
                    loadSnapshot()
                }
                render()
            }, LinearLayout.LayoutParams(dp(ICON_DOCK_BUTTON_WIDTH_DP), dp(ICON_DOCK_BUTTON_HEIGHT_DP)))
        }
    }

    @Suppress("DEPRECATION")
    internal fun installSafeAreaInsets() {
        rootFrame.setOnApplyWindowInsetsListener { _, insets ->
            val cutoutTop = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                insets.displayCutout?.safeInsetTop ?: 0
            } else {
                0
            }
            val cutoutBottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                insets.displayCutout?.safeInsetBottom ?: 0
            } else {
                0
            }
            val nextTop = max(insets.systemWindowInsetTop, cutoutTop)
            val nextBottom = max(insets.systemWindowInsetBottom, cutoutBottom)
            if (safeAreaTop != nextTop || safeAreaBottom != nextBottom) {
                safeAreaTop = nextTop
                safeAreaBottom = nextBottom
                applySafeAreaPadding()
            }
            insets
        }
        rootFrame.requestApplyInsets()
        applySafeAreaPadding()
    }

    internal fun applySafeAreaPadding() {
        if (!::shell.isInitialized) return
        shell.setPadding(0, safeAreaTop, 0, safeAreaBottom)
    }

    internal fun hidePhoneDockForEditing() {
        keyboardActive = true
        updateChromeVisibility()
    }

    internal fun showPhoneDockAfterEditing() {
        keyboardActive = false
        updateChromeVisibility()
    }

    internal fun dismissKeyboard() {
        val focus = currentFocus
        if (focus is EditText) {
            focus.clearFocus()
        }
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow((focus ?: shell).windowToken, 0)
        keyboardActive = false
        updateChromeVisibility()
    }

    internal fun exitSearch() {
        dismissKeyboard()
        selectedTab = TAB_HOME
        selectedSchemeId = null
        render()
    }

    internal fun installKeyboardVisibilityWatcher() {
        shell.viewTreeObserver.addOnGlobalLayoutListener {
            if (!::shell.isInitialized) return@addOnGlobalLayoutListener
            val frame = Rect()
            shell.getWindowVisibleDisplayFrame(frame)
            val height = shell.rootView.height
            if (height <= 0) return@addOnGlobalLayoutListener
            val hidden = height - frame.bottom
            val next = hidden > height * 0.15f
            if (keyboardActive != next) {
                keyboardActive = next
                updateChromeVisibility()
            }
        }
    }

    internal fun updateChromeVisibility() {
        if (!::titleBar.isInitialized || !::dock.isInitialized) return
        titleBar.visibility = if (isWideLayout()) View.VISIBLE else View.GONE
        dock.visibility = if (shouldShowPhoneDock()) View.VISIBLE else View.GONE
    }

    internal fun isWideLayout(): Boolean =
        resources.configuration.screenWidthDp >= 760

    internal fun shouldShowPhoneDock(): Boolean =
        !isWideLayout() && !keyboardActive && selectedTab in listOf(TAB_HOME, TAB_CALENDAR, TAB_SETTINGS)

    internal fun shouldShowPhoneQuickActions(): Boolean =
        !isWideLayout() && !keyboardActive && selectedTab == TAB_HOME

    // ── First-run onboarding ────────────────────────────────────────────────


    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_ATTACH_IMAGE) return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pendingImageAttach = null
            return
        }
        completeImageAttach(uri)
    }


    internal inner class CalendarWeekHighlightView(
        context: Context,
        private val dates: List<LocalDate>,
        private val visibleDates: Set<String>
    ) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (dates.isEmpty() || width <= 0) return
            val cellWidth = width / dates.size.toFloat()
            // Concentric with the day-number row: 7dp cell top margin + 16dp
            // weekday row puts the 37dp number row at 23..60.
            val pillTop = dp(23).toFloat()
            val pillHeight = dp(37).toFloat()
            val barHeight = dp(4).toFloat()
            paint.style = Paint.Style.FILL
            paint.color = calendarWeekConnectorColor()
            var runStart: Int? = null
            dates.forEachIndexed { index, date ->
                val visible = visibleDates.contains(date.toString())
                if (visible && runStart == null) {
                    runStart = index
                } else if (!visible && runStart != null) {
                    drawWeekConnector(canvas, runStart ?: index, index - 1, cellWidth, pillTop, pillHeight, barHeight)
                    runStart = null
                }
            }
            runStart?.let { drawWeekConnector(canvas, it, dates.lastIndex, cellWidth, pillTop, pillHeight, barHeight) }

            dates.forEachIndexed { index, date ->
                if (!visibleDates.contains(date.toString())) return@forEachIndexed
                val circleSize = pillHeight
                val left = index * cellWidth + (cellWidth - circleSize) / 2f
                val rect = RectF(left, pillTop, left + circleSize, pillTop + circleSize)
                paint.color = if (date == LocalDate.now()) calendarDayHighlightColor() else calendarWeekSecondaryHighlightColor()
                canvas.drawOval(rect, paint)
            }
        }

        private fun drawWeekConnector(
            canvas: Canvas,
            start: Int,
            end: Int,
            cellWidth: Float,
            pillTop: Float,
            pillHeight: Float,
            barHeight: Float
        ) {
            if (end <= start) return
            paint.color = calendarWeekConnectorColor()
            val x = start * cellWidth + cellWidth / 2f
            val connectorWidth = (end - start) * cellWidth
            listOf(
                pillTop + pillHeight * 0.29f,
                pillTop + pillHeight * 0.71f - barHeight
            ).forEach { y ->
                canvas.drawRoundRect(RectF(x, y, x + connectorWidth, y + barHeight), barHeight / 2f, barHeight / 2f, paint)
            }
        }
    }

    /// An hour-grid day timeline mirroring the iOS calendar: a left time gutter
    /// plus N day columns (2 on phone), with events drawn at their actual times
    /// and overlapping events split into side-by-side sub-columns. Tap an event to
    /// edit it; long-press to jump to its scheme.
    internal inner class CalendarTimelineView(context: Context) : View(context) {
        // One JSONObject per visible day column (date + occurrences); `columns` is
        // the slot count used for column widths even if fewer days are available.
        private var dayObjects: List<JSONObject> = emptyList()
        private var columns: Int = 2
        private var leadingColumns: Int = 0
        private var dragLaid: Laid? = null
        private var dragRect: RectF = RectF()
        private var dragSourceDay = -1
        private var dragStartY = 0f
        private var dragStartMinute = 0f
        private var dragDuration = 30f
        private var dragHeight = 0f
        private var dragOffsetX = 0f
        private var dragOffsetY = 0f
        private var dragMoved = false
        private var dragSnapBaseline = -1f
        // The dragged block stays rendered at its drop slot while the recurring
        // scope prompt is open.
        private var dragHeldForDialog = false
        private var draftDay = -1
        private var draftMinute = -1f
        private var draftRect: RectF? = null
        private var touchStartX = 0f
        private var touchStartY = 0f
        private var swipingDays = false
        private var swipeOffsetX = 0f
        private var swipeAnimator: ValueAnimator? = null
        private var velocityTracker: VelocityTracker? = null
        private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
        // Viewport (scroll offset + visible height) reported by the enclosing
        // ScrollView so the sticky off-screen-event pills can track the screen.
        private var viewportTop = 0
        private var viewportHeight = 0
        private val stickyHits = ArrayList<Pair<RectF, JSONObject>>()
        // Event drags pick up on a faster long-press (0.22s, matching iOS) than
        // the empty-space create draft (the detector's default long-press).
        private var pendingDragRunnable: Runnable? = null

        private val hourPx = dp(44)
        private val gutterPx = dp(48)
        private val topOffset = dp(8)
        private val bottomPad = dp(88)
        private val hoursInDay = 24

        private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = max(1f, 0.6f * resources.displayMetrics.density)
        }
        private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        private val pillLinePaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val nowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val gutterPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.RIGHT
            textSize = sp(10f)
        }
        private val timePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            textSize = sp(9f)
            typeface = Typeface.MONOSPACE
        }
        private val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            textSize = sp(11f)
            typeface = Typeface.DEFAULT_BOLD
        }
        private val stickyTitlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.LEFT
            textSize = sp(12f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }

        private inner class Laid(
            val occ: JSONObject,
            val rect: RectF,
            val isReminder: Boolean,
            val isAssignment: Boolean,
            val hideTime: Boolean,
            val dayIndex: Int
        )

        private var laid: List<Laid> = emptyList()
        private var dragMode = CALENDAR_INTERACTION_NONE
        private var createKind = "assignment"
        private var dragTargetDay = -1
        private var dragTargetMinute = 0f

        private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                stickyHits.lastOrNull { it.first.contains(e.x, e.y) }?.let { (_, occ) ->
                    showEventEditorDialog(occ)
                    return true
                }
                val hit = hitTest(e.x, e.y)
                if (hit != null) {
                    showEventEditorDialog(hit)
                }
                // Empty space is inert on tap (iOS creates only via long-press).
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                if (dragMode != CALENDAR_INTERACTION_NONE || swipingDays) return
                val hit = hitTest(e.x, e.y)
                if (hit != null) {
                    if (hit.optBoolean("is_read_only", false)) {
                        showEventEditorDialog(hit)
                    } else {
                        laid.lastOrNull { it.occ == hit }?.let { matched ->
                            beginDrag(matched, e.x, e.y)
                        }
                    }
                } else {
                    beginCreate(dayIndexForX(e.x), e.y)
                }
            }
        })

        init {
            isClickable = true
        }

        fun configure(days: List<JSONObject>, columns: Int, leadingColumns: Int = 0) {
            this.dayObjects = days
            this.columns = max(1, columns)
            this.leadingColumns = leadingColumns.coerceIn(0, max(0, days.size - 1))
            this.swipeOffsetX = 0f
            this.swipingDays = false
            this.laid = emptyList()
            requestLayout()
            if (width > 0) relayout()
            invalidate()
        }

        fun onViewportChanged(scrollY: Int, visibleHeight: Int) {
            if (viewportTop == scrollY && viewportHeight == visibleHeight) return
            viewportTop = scrollY
            viewportHeight = visibleHeight
            invalidate()
        }

        private fun sp(value: Float): Float =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics)

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val w = MeasureSpec.getSize(widthMeasureSpec)
            setMeasuredDimension(w, topOffset + hoursInDay * hourPx + bottomPad)
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            relayout()
        }

        private fun minuteOfDay(occ: JSONObject, key: String): Float? {
            val instant = MobileDateFormatting.parseInstant(occ.optionalString(key)) ?: return null
            val local = instant.atZone(ZoneId.systemDefault()).toLocalTime()
            return (local.hour * 60 + local.minute).toFloat()
        }

        private fun isShortEvent(occ: JSONObject): Boolean {
            if (occ.optString("kind") != "event") return false
            val s = MobileDateFormatting.parseInstant(occ.optionalString("start")) ?: return false
            val e = MobileDateFormatting.parseInstant(occ.optionalString("end")) ?: return false
            return e.epochSecond - s.epochSecond <= 30 * 60
        }

        private fun dayDate(dayIndex: Int): LocalDate? {
            val objectIndex = dayIndex + leadingColumns
            if (objectIndex !in dayObjects.indices) return null
            return runCatching { LocalDate.parse(dayObjects[objectIndex].optString("date")) }.getOrNull()
        }

        private fun dayIndexForX(x: Float): Int {
            val columnWidth = max(1, (width - gutterPx) / columns)
            return ((x - gutterPx) / columnWidth).toInt().coerceIn(0, columns - 1)
        }

        private fun snappedMinute(y: Float, stepMinutes: Int, round: Boolean): Float {
            val raw = ((y - topOffset) / hourPx) * 60f
            val maxMinute = (hoursInDay * 60).toFloat()
            val clamped = raw.coerceIn(0f, maxMinute)
            if (stepMinutes <= 0) return clamped
            return if (round) {
                val step = stepMinutes.toFloat()
                val steps = (clamped / step).roundToInt()
                (steps * step).coerceIn(0f, maxMinute)
            } else {
                val step = stepMinutes.toFloat()
                val steps = (clamped / step).toInt()
                (steps * step).coerceIn(0f, maxMinute)
            }
        }

        private fun eventDurationMinutes(occ: JSONObject): Float {
            val kind = occ.optString("kind")
            if (kind != "event") return 30f
            val rawStart = minuteOfDay(occ, "start") ?: 0f
            val rawEnd = minuteOfDay(occ, "end") ?: (rawStart + 60f)
            return max(15f, rawEnd - rawStart)
        }

        private fun dragAnchorMinute(occ: JSONObject): Float {
            return when (occ.optString("kind")) {
                "assignment" -> minuteOfDay(occ, "end") ?: 0f
                else -> minuteOfDay(occ, "start") ?: 0f
            }
        }

        private fun activeDateTime(dayIndex: Int, minute: Float): LocalDateTime? {
            val date = dayDate(dayIndex) ?: return null
            val clamped = minute.coerceIn(0f, ((hoursInDay * 60) - 1).toFloat())
            val total = clamped.toInt().coerceIn(0, (hoursInDay * 60) - 1)
            return date.atTime(total / 60, total % 60)
        }

        private fun clearCreatePreview() {
            draftDay = -1
            draftMinute = -1f
            createKind = "event"
            dragMoved = false
            draftRect = null
        }

        private fun clearDragPreview() {
            dragMode = CALENDAR_INTERACTION_NONE
            dragHeldForDialog = false
            dragLaid = null
            dragSourceDay = -1
            dragStartMinute = 0f
            dragDuration = 30f
            dragHeight = 0f
            dragOffsetX = 0f
            dragOffsetY = 0f
            dragMoved = false
            dragSnapBaseline = -1f
            dragRect.setEmpty()
        }

        private fun beginDrag(laid: Laid, x: Float, y: Float) {
            val rowWidth = max(1, (width - gutterPx) / columns)
            if (rowWidth <= 0) return
            val occ = laid.occ
            dragMode = CALENDAR_INTERACTION_DRAG
            dragLaid = laid
            dragRect.set(laid.rect)
            dragStartY = y
            dragStartMinute = dragAnchorMinute(occ)
            dragDuration = eventDurationMinutes(occ)
            dragHeight = laid.rect.height()
            dragOffsetX = x - laid.rect.left
            dragOffsetY = y - laid.rect.top
            dragSourceDay = dayIndexForX(laid.rect.centerX())
            val columnLeft = gutterPx + dragSourceDay * rowWidth
            dragMoved = false
            dragSnapBaseline = -1f
            val sourceOffset = laid.rect.left - columnLeft
            dragOffsetX = (dragOffsetX - sourceOffset)
            dragTargetDay = dragSourceDay
            dragTargetMinute = dragStartMinute
            parent?.requestDisallowInterceptTouchEvent(true)
            invalidate()
        }

        private fun beginCreate(dayIndex: Int, y: Float, initialKind: String = "event") {
            val rowWidth = max(1, (width - gutterPx) / columns)
            val minute = snappedMinute(y, 5, false)
            val startMinute = minute.coerceIn(0f, ((hoursInDay * 60) - 60).toFloat())
            draftDay = dayIndex
            draftMinute = startMinute
            dragStartMinute = startMinute
            dragTargetDay = dayIndex
            dragTargetMinute = startMinute
            dragMode = CALENDAR_INTERACTION_CREATE
            createKind = initialKind
            dragStartY = y
            dragHeight = hourPx.toFloat()
            dragMoved = false
            val left = gutterPx + dayIndex * rowWidth
            val draftLeft = left + 1f
            val draftRight = left + rowWidth - 1f
            val draftTop = topOffset + startMinute / 60f * hourPx
            val draftBottom = topOffset + ((startMinute + 60f) / 60f * hourPx)
            draftRect = RectF(draftLeft, draftTop, draftRight, draftBottom)
            parent?.requestDisallowInterceptTouchEvent(true)
            invalidate()
        }

        private fun commitCreateFromTouch() {
            val targetDay = dragTargetDay.coerceIn(0, columns - 1)
            val targetMinute = dragTargetMinute.coerceIn(0f, ((hoursInDay * 60) - 1).toFloat())
            val date = dayDate(targetDay) ?: selectedDate
            // Keep the draft block on screen while the editor dialog is open so
            // it marks the new task's slot (matching iOS); clear it on dismiss.
            dragMode = CALENDAR_INTERACTION_NONE
            invalidate()
            showEventEditorDialog(
                occurrence = null,
                initialDate = date,
                initialMinute = targetMinute,
                preferredKind = createKind,
                openForNew = true,
                onDismiss = {
                    clearCreatePreview()
                    invalidate()
                }
            )
        }

        private fun commitDragFromTouch() {
            val laid = dragLaid ?: return
            val kind = laid.occ.optString("kind")
            val targetDay = dragTargetDay.coerceIn(0, columns - 1)
            val targetTime = activeDateTime(targetDay, dragTargetMinute.coerceIn(0f, (hoursInDay * 60 - 1).toFloat())) ?: run {
                clearDragPreview()
                return
            }
            val start = when (kind) {
                "event", "reminder" -> MobileDateFormatting.iso(targetTime.toLocalDate(), targetTime.hour, targetTime.minute)
                else -> null
            }
            val end = when (kind) {
                "event" -> {
                    val endTime = activeDateTime(targetDay, dragTargetMinute + dragDuration)
                    endTime?.let { MobileDateFormatting.iso(it.toLocalDate(), it.hour, it.minute) }
                }
                "assignment" -> MobileDateFormatting.iso(targetTime.toLocalDate(), targetTime.hour, targetTime.minute)
                else -> null
            }
            val notificationOffset = if (laid.occ.isNull("notification_offset_secs")) null else laid.occ.optInt("notification_offset_secs")

            if (dragMoved) {
                val commit = { scope: String ->
                    commitEventEdit(
                        occurrence = laid.occ,
                        title = laid.occ.optString("title"),
                        start = start,
                        end = end,
                        rrule = null,
                        notificationOffsetSecs = notificationOffset,
                        notificationDirty = true,
                        done = laid.occ.optBoolean("done", false),
                        scope = scope
                    )
                }
                if (laid.occ.optBoolean("is_recurring", false)) {
                    // Keep the dragged block at its target slot while the scope
                    // prompt is up; snap back only if the prompt is cancelled.
                    dragMode = CALENDAR_INTERACTION_NONE
                    dragHeldForDialog = true
                    invalidate()
                    showOccurrenceScopeDialog(
                        "Recurring task",
                        laid.occ,
                        forDelete = false,
                        onCancel = {
                            clearDragPreview()
                            invalidate()
                        }
                    ) { scope ->
                        commit(scope)
                    }
                } else {
                    clearDragPreview()
                    invalidate()
                    commit("all_events")
                }
            } else {
                clearDragPreview()
                invalidate()
                showEventEditorDialog(laid.occ)
            }
        }

        private fun endCreate() {
            if (dragMode != CALENDAR_INTERACTION_CREATE) return
            if (draftRect == null) {
                clearCreatePreview()
                return
            }
            commitCreateFromTouch()
        }

        private fun endDrag() {
            if (dragMode != CALENDAR_INTERACTION_DRAG) return
            commitDragFromTouch()
        }

        private fun cancelDragOrCreate() {
            when (dragMode) {
                CALENDAR_INTERACTION_DRAG -> clearDragPreview()
                CALENDAR_INTERACTION_CREATE -> clearCreatePreview()
                else -> Unit
            }
            dragMode = CALENDAR_INTERACTION_NONE
            invalidate()
        }

        private fun updateCreate(x: Float, y: Float) {
            val rowWidth = max(1, (width - gutterPx) / columns)
            val candidateDay = dayIndexForX(x).coerceIn(0, columns - 1)
            // The draft tracks the finger directly on a 5-minute grid, iOS-style.
            val candidateMinute = snappedMinute(y, 5, false).coerceIn(0f, ((hoursInDay * 60) - 60).toFloat())
            if (candidateDay != dragTargetDay || abs(candidateMinute - dragTargetMinute) >= 1f) {
                dragMoved = true
            }
            dragTargetDay = candidateDay
            dragTargetMinute = candidateMinute
            val left = gutterPx + candidateDay * rowWidth
            val draftLeft = left + 1f
            val draftRight = left + rowWidth - 1f
            val draftTop = topOffset + dragTargetMinute / 60f * hourPx
            val draftBottom = topOffset + (dragTargetMinute + 60f) / 60f * hourPx
            draftRect = RectF(draftLeft, draftTop, draftRight, draftBottom)
            invalidate()
        }

        private fun updateDrag(y: Float, x: Float) {
            val laid = dragLaid ?: return
            val rowWidth = max(1, (width - gutterPx) / columns)
            val rawMinute = snappedMinute(y - dragOffsetY + dragRect.height() / 2f, 15, true)
            val kind = laid.occ.optString("kind")
            val maxStart = if (kind == "event") {
                hoursInDay * 60 - dragDuration
            } else {
                hoursInDay * 60 - 15
            }
            val snapped = rawMinute.coerceIn(0f, maxStart.toFloat())
            // Compare against the first snap, not the raw anchor: 15-minute
            // re-rounding must not register a "move" for a stationary hold.
            if (dragSnapBaseline < 0f) dragSnapBaseline = snapped
            if (abs(snapped - dragSnapBaseline) > 0.5f) {
                dragMoved = true
            }
            val dayIndex = dayIndexForX(x - dragOffsetX + dragRect.width() / 2f)
            val targetDay = dayIndex.coerceIn(0, columns - 1)
            val columnLeft = gutterPx + targetDay * rowWidth
            dragTargetDay = targetDay
            dragTargetMinute = snapped
            val targetOffset = dragRect.width() - laid.rect.width().coerceAtLeast(1f)
            val sourceColumnWidth = max(1f, rowWidth.toFloat())
            val sourceOffset = dragOffsetX
            val clampedOffset = sourceOffset.coerceIn(0f, sourceColumnWidth - dragRect.width() - 1f)
            val top = topOffset + snapped / 60f * hourPx
            dragRect.set(columnLeft + clampedOffset, top, columnLeft + clampedOffset + laid.rect.width(), top + dragRect.height())
            invalidate()
        }

        // Greedy interval colouring identical to the iOS layout: split each
        // overlap component independently, then let items span any free lanes.
        private fun relayout() {
            val colWidth = max(1, (width - gutterPx) / columns)
            val out = ArrayList<Laid>()
            for (dayIndex in dayObjects.indices) {
                val occsArray = dayObjects[dayIndex].optJSONArray("occurrences") ?: continue

                data class Slot(val occ: JSONObject, val startMin: Float, val endMin: Float)
                data class PendingSlot(val slot: Slot, val lane: Int)
                data class PlacedSlot(val slot: Slot, val lane: Int, val laneSpan: Int, val laneCount: Int)

                fun slotsOverlap(a: Slot, b: Slot): Boolean =
                    a.startMin < b.endMin && b.startMin < a.endMin

                fun flushComponent(component: ArrayList<PendingSlot>, placed: ArrayList<PlacedSlot>) {
                    if (component.isEmpty()) return
                    val laneCount = component.maxOf { it.lane } + 1
                    component.forEach { pending ->
                        var laneSpan = 1
                        if (pending.lane + 1 < laneCount) {
                            for (lane in (pending.lane + 1) until laneCount) {
                                if (component.any { other ->
                                        other.lane == lane && slotsOverlap(pending.slot, other.slot)
                                    }) {
                                    break
                                }
                                laneSpan += 1
                            }
                        }
                        placed.add(PlacedSlot(pending.slot, pending.lane, laneSpan, laneCount))
                    }
                    component.clear()
                }

                val slots = ArrayList<Slot>()
                occsArray.forEachObject { occ ->
                    val kind = occ.optString("kind")
                    if (kind == "procedure") return@forEachObject
                    val rawStart = minuteOfDay(occ, "start") ?: minuteOfDay(occ, "end") ?: return@forEachObject
                    val startMin = rawStart.coerceIn(0f, 1440f)
                    val minDur = if (kind == "event") 30f else 45f
                    val rawEnd = minuteOfDay(occ, "end")?.coerceIn(0f, 1440f) ?: (startMin + minDur)
                    slots.add(Slot(occ, startMin, max(startMin + minDur, rawEnd)))
                }
                slots.sortWith(compareBy<Slot> { it.startMin }.thenByDescending { it.endMin })

                val placed = ArrayList<PlacedSlot>()
                val component = ArrayList<PendingSlot>()
                var componentEnd: Float? = null
                val active = ArrayList<Pair<Float, Int>>()

                slots.forEach { slot ->
                    val currentEnd = componentEnd
                    if (currentEnd != null && slot.startMin >= currentEnd) {
                        flushComponent(component, placed)
                        active.clear()
                        componentEnd = null
                    }

                    active.removeAll { it.first <= slot.startMin }

                    var lane = 0
                    while (active.any { it.second == lane }) {
                        lane += 1
                    }
                    active.add(slot.endMin to lane)
                    componentEnd = max(componentEnd ?: slot.endMin, slot.endMin)
                    component.add(PendingSlot(slot, lane))
                }

                flushComponent(component, placed)

                val columnX = gutterPx + (dayIndex - leadingColumns) * colWidth
                placed.forEach { placement ->
                    val slot = placement.slot
                    val kind = slot.occ.optString("kind")
                    val subWidth = colWidth.toFloat() / max(1, placement.laneCount)
                    val y = topOffset + slot.startMin / 60f * hourPx
                    val minHeight = if (kind == "event") dp(20).toFloat() else dp(34).toFloat()
                    val height = max(minHeight, (slot.endMin - slot.startMin) / 60f * hourPx - 2f)
                    val x = columnX + placement.lane * subWidth + 1f
                    val rect = RectF(
                        x,
                        y,
                        x + max(dp(8).toFloat(), subWidth * placement.laneSpan - 2f),
                        y + height
                    )
                    out.add(Laid(slot.occ, rect, kind == "reminder", kind == "assignment", isShortEvent(slot.occ), dayIndex - leadingColumns))
                }
            }
            laid = out
        }

        override fun onDraw(canvas: Canvas) {
            if (width <= 0) return
            if (laid.isEmpty() && dayObjects.isNotEmpty()) relayout()
            drawPastShade(canvas)
            drawGrid(canvas)
            val dayCanvas = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), 0f, width.toFloat(), height.toFloat())
            canvas.translate(swipeOffsetX, 0f)
            // While dragging (or holding for the scope prompt), only the moving
            // copy is drawn — not the original.
            val dragActive = dragMode == CALENDAR_INTERACTION_DRAG || dragHeldForDialog
            laid.forEach {
                if (!dragActive || it !== dragLaid) drawEvent(canvas, it)
            }
            // The create draft stays visible after the touch ends, while its
            // editor dialog is open (cleared via the dialog's dismiss callback).
            draftRect?.let { drawDraftBlock(canvas, it) }
            if (dragActive) {
                dragLaid?.let { laid ->
                    val kind = laid.occ.optString("kind")
                    val moving = JSONObject(laid.occ.toString()).apply {
                        activeDateTime(dragTargetDay, dragTargetMinute)?.let { time ->
                            when (kind) {
                                "event", "reminder" -> put("start", MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute))
                            }
                            when (kind) {
                                "event" -> {
                                    activeDateTime(dragTargetDay, dragTargetMinute + dragDuration)?.let { end ->
                                        put("end", MobileDateFormatting.iso(end.toLocalDate(), end.hour, end.minute))
                                    }
                                }
                                "assignment" -> put("end", MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute))
                            }
                        }
                    }
                    drawEvent(canvas, Laid(moving, dragRect, kind == "reminder", kind == "assignment", laid.hideTime, dragTargetDay))
                }
            }
            drawNowLine(canvas)
            canvas.restoreToCount(dayCanvas)
            drawStickyIndicators(canvas)
        }

        /// Tints the already-elapsed part of each day in the calendar blue, like
        /// iOS/desktop `cal_past`: full column for past days, top-to-now today.
        private fun drawPastShade(canvas: Canvas) {
            if (dayObjects.isEmpty()) return
            val colWidth = max(1, (width - gutterPx) / columns)
            val today = LocalDate.now()
            val saved = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), 0f, width.toFloat(), height.toFloat())
            canvas.translate(swipeOffsetX, 0f)
            fillPaint.color = adjustAlpha(calendarDayHighlightColor(), if (theme.isDark) 0.11f else 0.13f)
            for (objectIndex in dayObjects.indices) {
                val date = runCatching { LocalDate.parse(dayObjects[objectIndex].optString("date")) }.getOrNull() ?: continue
                val shadeBottom = when {
                    date.isBefore(today) -> (topOffset + hoursInDay * hourPx).toFloat()
                    date == today -> {
                        val now = LocalTime.now()
                        topOffset + (now.hour * 60 + now.minute) / 60f * hourPx
                    }
                    else -> continue
                }
                val x = (gutterPx + (objectIndex - leadingColumns) * colWidth).toFloat()
                canvas.drawRect(x, 0f, x + colWidth, shadeBottom, fillPaint)
            }
            canvas.restoreToCount(saved)
        }

        private fun drawDraftBlock(canvas: Canvas, rect: RectF) {
            val radius = dp(3).toFloat()
            fillPaint.color = adjustAlpha(theme.accent, if (theme.isDark) 0.32f else 0.22f)
            canvas.drawRoundRect(rect, radius, radius, fillPaint)
            borderPaint.color = theme.accent
            borderPaint.alpha = 255
            borderPaint.strokeWidth = max(1f, 1.5f * resources.displayMetrics.density)
            canvas.drawRoundRect(rect, radius, radius, borderPaint)
            val textColor = if (theme.isDark) Color.WHITE else rgb(0x24272d)
            val saved = canvas.save()
            canvas.clipRect(rect)
            val cx = rect.centerX()
            val availW = max(0f, rect.width() - dp(8))
            timePaint.color = textColor
            timePaint.alpha = 255
            val timeLabel = activeDateTime(dragTargetDay, dragTargetMinute)?.let { time ->
                MobileDateFormatting.time(MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute), timeFormat24())
            }.orEmpty()
            val time = TextUtils.ellipsize(timeLabel, timePaint, availW, TextUtils.TruncateAt.END)
            canvas.drawText(time, 0, time.length, cx, rect.top + dp(3) - timePaint.ascent(), timePaint)
            titlePaint.color = textColor
            titlePaint.alpha = 255
            canvas.drawText("New", cx, rect.top + dp(15) - titlePaint.ascent(), titlePaint)
            canvas.restoreToCount(saved)
        }

        /// Stacked "more events" pills pinned to the top/bottom of the viewport
        /// for events scrolled out of view, fading in with distance like iOS.
        private fun drawStickyIndicators(canvas: Canvas) {
            stickyHits.clear()
            if (viewportHeight <= 0 || dayObjects.isEmpty() || dragMode != CALENDAR_INTERACTION_NONE) return
            val colWidth = dayColumnWidth()
            val pillH = dp(26).toFloat()
            val spacing = dp(4).toFloat()
            val fadeDistance = dp(44).toFloat()
            val bottomCutoff = dp(104).toFloat()
            val stackDepth = 3
            val timelineBottom = (topOffset + hoursInDay * hourPx).toFloat()
            val visibleMinY = max(0, viewportTop).toFloat()
            val visibleMaxY = min(timelineBottom, viewportTop + viewportHeight - bottomCutoff)
            if (visibleMaxY <= visibleMinY) return
            val topBaseY = visibleMinY + dp(7)
            val bottomBaseY = max(topBaseY, viewportTop + viewportHeight - bottomCutoff - pillH - dp(10))

            for (objectIndex in dayObjects.indices) {
                val visIndex = objectIndex - leadingColumns
                val columnLeft = gutterPx + visIndex * colWidth + swipeOffsetX
                val visibleWidth = min(width.toFloat(), columnLeft + colWidth) - max(gutterPx.toFloat(), columnLeft)
                if (visibleWidth <= 0f) continue
                val horizontalAlpha = (visibleWidth / min(colWidth, fadeDistance)).coerceIn(0f, 1f)
                val dayEvents = laid.filter { it.dayIndex == visIndex }
                val topCandidates = dayEvents
                    .filter { it.rect.top < visibleMinY }
                    .sortedWith(compareByDescending<Laid> { it.rect.top }.thenBy { it.rect.left })
                    .take(stackDepth)
                    .reversed()
                val bottomCandidates = dayEvents
                    .filter { it.rect.top > visibleMaxY }
                    .sortedWith(compareBy<Laid> { it.rect.top }.thenBy { it.rect.left })
                    .take(stackDepth)
                    .reversed()
                topCandidates.forEachIndexed { index, candidate ->
                    val alpha = ((visibleMinY - candidate.rect.top) / fadeDistance).coerceIn(0f, 1f) * horizontalAlpha
                    drawStickyPill(canvas, candidate.occ, columnLeft, colWidth, topBaseY + index * (pillH + spacing), pillH, alpha)
                }
                bottomCandidates.forEachIndexed { index, candidate ->
                    val alpha = ((candidate.rect.top - visibleMaxY) / fadeDistance).coerceIn(0f, 1f) * horizontalAlpha
                    drawStickyPill(canvas, candidate.occ, columnLeft, colWidth, max(topBaseY, bottomBaseY - index * (pillH + spacing)), pillH, alpha)
                }
            }
        }

        private fun drawStickyPill(
            canvas: Canvas,
            occ: JSONObject,
            columnLeft: Float,
            colWidth: Float,
            y: Float,
            pillH: Float,
            alpha: Float
        ) {
            if (alpha <= 0.02f) return
            val pillW = min(max(dp(96).toFloat(), colWidth - dp(14)), width - gutterPx - dp(14).toFloat())
            val minX = gutterPx + dp(7).toFloat()
            val maxX = max(minX, width - pillW - dp(7))
            val x = (columnLeft + dp(7)).coerceIn(minX, maxX)
            val rect = RectF(x, y, x + pillW, y + pillH)
            val alpha255 = (alpha * 255).roundToInt().coerceIn(0, 255)
            val radius = pillH / 2f
            fillPaint.color = if (theme.isDark) adjustAlpha(rgb(0x333333), 0.92f) else adjustAlpha(theme.bgApp, 0.86f)
            fillPaint.alpha = (Color.alpha(fillPaint.color) * alpha / 1f).roundToInt().coerceIn(0, 255)
            canvas.drawRoundRect(rect, radius, radius, fillPaint)
            borderPaint.color = if (theme.isDark) adjustAlpha(Color.WHITE, 0.18f) else theme.dividerSoft
            borderPaint.alpha = (Color.alpha(borderPaint.color) * alpha).roundToInt().coerceIn(0, 255)
            borderPaint.strokeWidth = max(1f, 0.75f * resources.displayMetrics.density)
            canvas.drawRoundRect(rect, radius, radius, borderPaint)
            fillPaint.color = if (occ.optString("scheme_name") == "Daily") dailyAccent() else schemeColor(occ.optInt("color_index"))
            fillPaint.alpha = alpha255
            canvas.drawCircle(rect.left + dp(9) + dp(7) / 2f, rect.centerY(), dp(7) / 2f, fillPaint)
            stickyTitlePaint.color = theme.textPrimary
            stickyTitlePaint.alpha = alpha255
            val title = occ.optString("title").trim().ifEmpty { occ.optString("kind").replaceFirstChar(Char::titlecase) }
            val availW = max(0f, pillW - dp(30))
            val label = TextUtils.ellipsize(title, stickyTitlePaint, availW, TextUtils.TruncateAt.END)
            val baseline = rect.centerY() - (stickyTitlePaint.ascent() + stickyTitlePaint.descent()) / 2f
            canvas.drawText(label, 0, label.length, rect.left + dp(22), baseline, stickyTitlePaint)
            stickyHits.add(rect to occ)
        }

        private fun drawGrid(canvas: Canvas) {
            val colWidth = max(1, (width - gutterPx) / columns)
            gridPaint.color = theme.dividerSoft
            gutterPaint.color = theme.textMuted
            val gridBottom = (topOffset + hoursInDay * hourPx).toFloat()
            for (hour in 0..hoursInDay) {
                val y = (topOffset + hour * hourPx).toFloat()
                canvas.drawLine(gutterPx.toFloat(), y, width.toFloat(), y, gridPaint)
                // The very bottom of the timeline is the next midnight (12 AM).
                val baseline = y - (gutterPaint.ascent() + gutterPaint.descent()) / 2f
                canvas.drawText(hourLabel(hour % hoursInDay), (gutterPx - dp(6)).toFloat(), baseline, gutterPaint)
            }
            val saved = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), topOffset.toFloat(), width.toFloat(), gridBottom)
            canvas.translate(swipeOffsetX, 0f)
            for (i in 0..dayObjects.size) {
                val x = (gutterPx + (i - leadingColumns) * colWidth).toFloat()
                canvas.drawLine(x, topOffset.toFloat(), x, gridBottom, gridPaint)
            }
            canvas.restoreToCount(saved)
        }

        private fun hourLabel(hour: Int): String {
            if (timeFormat24()) return "%02d:00".format(hour)
            return when {
                hour == 0 -> "12 AM"
                hour == 12 -> "12 PM"
                hour < 12 -> "$hour AM"
                else -> "${hour - 12} PM"
            }
        }

        private fun drawEvent(canvas: Canvas, e: Laid) {
            val occ = e.occ
            val isPill = e.isReminder || e.isAssignment
            val done = occ.optBoolean("done")
            val fillAlpha = if (done) 115 else 255
            val radius = if (isPill) 0f else dp(3).toFloat()

            fillPaint.color = eventBg()
            fillPaint.alpha = fillAlpha
            canvas.drawRoundRect(e.rect, radius, radius, fillPaint)

            if (isPill) {
                pillLinePaint.color = eventBorder()
                pillLinePaint.alpha = fillAlpha
                val sw = calendarPillStrokeWidth().toFloat()
                if (e.isReminder) {
                    canvas.drawRect(e.rect.left, e.rect.top, e.rect.right, e.rect.top + sw, pillLinePaint)
                } else {
                    canvas.drawRect(e.rect.left, e.rect.bottom - sw, e.rect.right, e.rect.bottom, pillLinePaint)
                }
            } else {
                borderPaint.color = eventBorder()
                borderPaint.alpha = fillAlpha
                borderPaint.strokeWidth = calendarEventBorderWidth().toFloat()
                val inset = borderPaint.strokeWidth / 2f
                canvas.drawRoundRect(
                    e.rect.left + inset, e.rect.top + inset, e.rect.right - inset, e.rect.bottom - inset,
                    radius, radius, borderPaint
                )
            }

            val saved = canvas.save()
            canvas.clipRect(e.rect)
            val padX = dp(4).toFloat()
            val availW = max(0f, e.rect.width() - padX * 2)
            val cx = e.rect.centerX()
            val title = occ.optString("title").ifEmpty { occ.optString("kind").replaceFirstChar(Char::titlecase) }
            val timeLabel = MobileDateFormatting.compactOccurrenceLabel(occ, timeFormat24())
            val showTime = !e.hideTime && timeLabel.isNotEmpty() && !MobileDateFormatting.isCompactEvent(occ)
            titlePaint.color = calendarItemTextColor(occ)
            titlePaint.alpha = if (done) 200 else 255
            if (showTime) {
                timePaint.color = calendarTimeColor(occ)
                timePaint.alpha = if (done) 150 else 255
                val timeTop = e.rect.top + dp(if (e.isReminder) 5 else 3)
                val time = TextUtils.ellipsize(timeLabel, timePaint, availW, TextUtils.TruncateAt.END)
                canvas.drawText(time, 0, time.length, cx, timeTop - timePaint.ascent(), timePaint)
                val titleTop = timeTop + dp(12)
                val name = TextUtils.ellipsize(title, titlePaint, availW, TextUtils.TruncateAt.END)
                canvas.drawText(name, 0, name.length, cx, titleTop - titlePaint.ascent(), titlePaint)
            } else {
                val name = TextUtils.ellipsize(title, titlePaint, availW, TextUtils.TruncateAt.END)
                val baseline = e.rect.centerY() - (titlePaint.ascent() + titlePaint.descent()) / 2f
                canvas.drawText(name, 0, name.length, cx, baseline, titlePaint)
            }
            canvas.restoreToCount(saved)
        }

        private fun drawNowLine(canvas: Canvas) {
            val todayKey = LocalDate.now().toString()
            val dayIndex = dayObjects.indexOfFirst { it.optString("date") == todayKey }
            if (dayIndex < 0) return
            val colWidth = max(1, (width - gutterPx) / columns)
            val now = LocalTime.now()
            val y = topOffset + (now.hour * 60 + now.minute) / 60f * hourPx
            val x0 = (gutterPx + (dayIndex - leadingColumns) * colWidth).toFloat()
            nowPaint.color = theme.danger
            nowPaint.style = Paint.Style.STROKE
            nowPaint.strokeWidth = max(1f, 1.5f * resources.displayMetrics.density)
            canvas.drawLine(x0, y, x0 + colWidth, y, nowPaint)
        }

        private fun hitTest(x: Float, y: Float): JSONObject? =
            laid.lastOrNull { it.rect.contains(x, y) }?.occ

        private fun dayColumnWidth(): Float =
            max(1, (width - gutterPx) / columns).toFloat()

        private fun rubberBandSwipe(dx: Float, limit: Float): Float {
            val magnitude = abs(dx)
            if (magnitude <= limit) return dx
            val sign = if (dx < 0f) -1f else 1f
            return sign * (limit + (magnitude - limit) * 0.18f)
        }

        private fun maybeStartDaySwipe(event: MotionEvent): Boolean {
            if (dragMode != CALENDAR_INTERACTION_NONE) return false
            val dx = event.x - touchStartX
            val dy = event.y - touchStartY
            if (!swipingDays && abs(dx) > touchSlop * 2 && abs(dx) > abs(dy) * 1.18f) {
                swipingDays = true
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            if (!swipingDays) return false
            swipeAnimator?.cancel()
            swipeOffsetX = rubberBandSwipe(dx, dayColumnWidth() * 0.96f)
            invalidate()
            return true
        }

        private fun finishDaySwipe() {
            val colWidth = dayColumnWidth()
            // iOS commit rule: project the gesture 0.18s ahead by velocity (only
            // when that grows the travel) and page when the projection clears the
            // threshold, or when the raw drag passed 42% of a column.
            velocityTracker?.computeCurrentVelocity(1000)
            val vx = velocityTracker?.xVelocity ?: 0f
            velocityTracker?.recycle()
            velocityTracker = null
            val dx = swipeOffsetX
            val projectedRaw = dx + vx * 0.18f
            val projected = if (abs(projectedRaw) > abs(dx)) projectedRaw else dx
            val threshold = max(dp(48).toFloat(), min(width * 0.15f, colWidth * 0.68f))
            val shouldShift = abs(projected) > threshold || abs(dx) > colWidth * 0.42f
            val dayDelta = when {
                shouldShift && projected < 0 -> 1L
                shouldShift && projected > 0 -> -1L
                else -> 0L
            }
            if (dayDelta == 0L) {
                animateDaySwipe(0f) {
                    swipingDays = false
                    parent?.requestDisallowInterceptTouchEvent(false)
                }
                return
            }
            val target = if (dayDelta > 0) -colWidth else colWidth
            animateDaySwipe(target) {
                val nextDate = selectedDate.plusDays(dayDelta)
                selectedDate = nextDate
                weekOffset = 0
                calendarScrollDate = nextDate.toString()
                swipeOffsetX = 0f
                swipingDays = false
                parent?.requestDisallowInterceptTouchEvent(false)
                loadSnapshot()
                render()
            }
        }

        private fun animateDaySwipe(target: Float, onEnd: () -> Unit) {
            swipeAnimator?.cancel()
            val animator = ValueAnimator.ofFloat(swipeOffsetX, target).apply {
                duration = 220L
                interpolator = DecelerateInterpolator(1.6f)
                addUpdateListener { valueAnimator ->
                    swipeOffsetX = valueAnimator.animatedValue as Float
                    invalidate()
                }
                addListener(object : AnimatorListenerAdapter() {
                    private var cancelled = false

                    override fun onAnimationCancel(animation: Animator) {
                        cancelled = true
                    }

                    override fun onAnimationEnd(animation: Animator) {
                        if (swipeAnimator === animation) {
                            swipeAnimator = null
                        }
                        if (!cancelled) onEnd()
                    }
                })
            }
            swipeAnimator = animator
            animator.start()
        }

        private fun cancelPendingDragPickup() {
            pendingDragRunnable?.let { removeCallbacks(it) }
            pendingDragRunnable = null
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    swipeAnimator?.cancel()
                    velocityTracker?.recycle()
                    velocityTracker = VelocityTracker.obtain()
                    velocityTracker?.addMovement(event)
                    touchStartX = event.x
                    touchStartY = event.y
                    swipingDays = false
                    swipeOffsetX = 0f
                    // Events pick up for dragging after a short 0.22s hold
                    // (iOS-style), faster than the long-press create draft.
                    cancelPendingDragPickup()
                    val downX = event.x
                    val downY = event.y
                    if (dragMode == CALENDAR_INTERACTION_NONE &&
                        stickyHits.none { it.first.contains(downX, downY) }
                    ) {
                        hitTest(downX, downY)?.takeIf { !it.optBoolean("is_read_only", false) }?.let { hit ->
                            val runnable = Runnable {
                                pendingDragRunnable = null
                                if (dragMode == CALENDAR_INTERACTION_NONE && !swipingDays) {
                                    laid.lastOrNull { it.occ == hit }?.let { matched ->
                                        beginDrag(matched, downX, downY)
                                    }
                                }
                            }
                            pendingDragRunnable = runnable
                            postDelayed(runnable, 220L)
                        }
                    }
                    gestureDetector.onTouchEvent(event)
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    velocityTracker?.addMovement(event)
                    if (maybeStartDaySwipe(event)) {
                        cancelPendingDragPickup()
                        return true
                    }
                }
                MotionEvent.ACTION_UP -> {
                    cancelPendingDragPickup()
                    if (swipingDays) {
                        finishDaySwipe()
                        return true
                    }
                    velocityTracker?.recycle()
                    velocityTracker = null
                }
                MotionEvent.ACTION_CANCEL -> {
                    cancelPendingDragPickup()
                    velocityTracker?.recycle()
                    velocityTracker = null
                    if (swipingDays) {
                        animateDaySwipe(0f) {
                            swipingDays = false
                            parent?.requestDisallowInterceptTouchEvent(false)
                        }
                        return true
                    }
                }
            }

            gestureDetector.onTouchEvent(event)
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE -> when (dragMode) {
                    CALENDAR_INTERACTION_CREATE -> updateCreate(event.x, event.y)
                    CALENDAR_INTERACTION_DRAG -> updateDrag(event.y, event.x)
                    else -> Unit
                }
                MotionEvent.ACTION_UP -> when (dragMode) {
                    CALENDAR_INTERACTION_CREATE -> endCreate()
                    CALENDAR_INTERACTION_DRAG -> endDrag()
                    else -> Unit
                }
                MotionEvent.ACTION_CANCEL -> cancelDragOrCreate()
            }
            return true
        }
    }

    /// expand/collapse, long-press (0.3s) lifts a row, drag shows a drop line
    /// between rows (or highlights a folder to drop inside), release commits
    /// the move. Releasing a lifted row without dragging opens its actions.
    internal inner class NavigatorPanel(context: Context) : FrameLayout(context) {
        private val list = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        private val rowHeight = dp(30)
        private val dropLine = View(context).apply {
            visibility = GONE
            background = rounded(theme.accent, dp(2))
        }
        private val folderHighlight = View(context).apply {
            visibility = GONE
            background = rounded(
                adjustAlpha(theme.accent, 0.14f),
                dp(5),
                theme.accent,
                max(1, (1.5f * resources.displayMetrics.density).roundToInt())
            )
        }
        private val rowMetas = ArrayList<Pair<View, NavRowMeta>>()
        private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var pressedRow: View? = null
        private var pressedMeta: NavRowMeta? = null
        private var dragging = false
        private var draggedSinceLift = false
        private var pendingPlacement: Pair<String, Int>? = null
        private var liftRunnable: Runnable? = null

        init {
            addView(list, LayoutParams(-1, -2))
            addView(folderHighlight, LayoutParams(0, 0))
            addView(dropLine, LayoutParams(0, dp(3)))
            buildRows()
        }

        private fun buildRows() {
            list.removeAllViews()
            rowMetas.clear()
            val root = snapshot.optJSONObject("root")
            val rootId = root?.optString("id").orEmpty()
            fun append(nodes: JSONArray?, parentId: String, depth: Int) {
                nodes?.forEachIndexedObject { index, node ->
                    val kind = node.optString("kind")
                    val id = node.optString("id")
                    val meta = NavRowMeta(
                        node = node,
                        id = id,
                        kind = kind,
                        parentId = parentId,
                        siblingIndex = index,
                        depth = depth,
                        childCount = node.optJSONArray("children")?.length() ?: 0
                    )
                    val row = navigatorRow(meta)
                    rowMetas.add(row to meta)
                    list.addView(row, LinearLayout.LayoutParams(-1, rowHeight))
                    if (kind == "folder" && !collapsedFolderIds.contains(id)) {
                        append(node.optJSONArray("children"), id, depth + 1)
                    }
                }
            }
            append(root?.optJSONArray("children"), rootId, 0)
            if (rowMetas.isEmpty()) {
                list.addView(text("No schemes yet", theme.textMuted, 14f, false).apply {
                    setPadding(dp(10), dp(8), dp(10), dp(8))
                }, LinearLayout.LayoutParams(-1, dp(36)))
            }
        }

        private fun navigatorRow(meta: NavRowMeta): View {
            val isFolder = meta.kind == "folder"
            val expanded = isFolder && !collapsedFolderIds.contains(meta.id)
            return LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8 + meta.depth * 10), 0, dp(7), 0)
                // Shared fixed leading slot so folder icons and scheme color
                // squares sit on the same center axis.
                addView(FrameLayout(this@MainActivity).apply {
                    if (isFolder) {
                        addView(
                            iconImage(R.drawable.ic_knotq_folder_24, theme.textMuted),
                            FrameLayout.LayoutParams(dp(14), dp(14), Gravity.CENTER)
                        )
                    } else {
                        addView(View(this@MainActivity).apply {
                            background = rounded(schemeColor(meta.node.optInt("color_index")), dp(3))
                        }, FrameLayout.LayoutParams(dp(10), dp(10), Gravity.CENTER))
                    }
                }, LinearLayout.LayoutParams(dp(18), dp(18)))
                addView(
                    text(meta.node.optString("name"), if (isFolder) theme.textPrimary else theme.textDim, 13f, isFolder).apply {
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                    },
                    LinearLayout.LayoutParams(0, -1, 1f).apply { setMargins(dp(7), 0, dp(4), 0) }
                )
                if (isFolder) {
                    addView(
                        inlineIcon(R.drawable.ic_knotq_chevron_right_24, theme.textMuted, widthDp = 18, iconSize = 13).apply {
                            rotation = if (expanded) 90f else 0f
                        },
                        LinearLayout.LayoutParams(dp(18), dp(18))
                    )
                }
                setOnClickListener {
                    if (isFolder) {
                        if (!collapsedFolderIds.add(meta.id)) {
                            collapsedFolderIds.remove(meta.id)
                        }
                        render()
                    } else {
                        openScheme(meta.id)
                    }
                }
            }
        }

        private fun rowAt(y: Float): Pair<View, NavRowMeta>? {
            val yInList = y - list.top
            return rowMetas.firstOrNull { (view, _) -> yInList >= view.top && yInList < view.bottom }
        }

        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.x
                    downY = ev.y
                    dragging = false
                    val hit = rowAt(ev.y)
                    pressedRow = hit?.first
                    pressedMeta = hit?.second
                    if (hit != null) {
                        val lift = Runnable {
                            liftRunnable = null
                            beginLift()
                        }
                        liftRunnable = lift
                        postDelayed(lift, 300L)
                    }
                }
                MotionEvent.ACTION_MOVE -> {
                    if (dragging) {
                        // The move that triggers interception is consumed by
                        // the handoff; handle it here so sparse event streams
                        // still track the finger.
                        handleDragMove(ev)
                    } else if (abs(ev.x - downX) > touchSlop || abs(ev.y - downY) > touchSlop) {
                        cancelLift()
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> cancelLift()
            }
            return dragging
        }

        private fun cancelLift() {
            liftRunnable?.let { removeCallbacks(it) }
            liftRunnable = null
        }

        private fun beginLift() {
            val row = pressedRow ?: return
            dragging = true
            draggedSinceLift = false
            pendingPlacement = null
            parent?.requestDisallowInterceptTouchEvent(true)
            row.elevation = dp(8).toFloat()
            row.animate().scaleX(0.97f).scaleY(0.97f).alpha(0.85f).setDuration(120).start()
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            updateDropTarget(downY)
        }

        private fun handleDragMove(event: MotionEvent) {
            val row = pressedRow ?: return
            row.translationY = event.y - downY
            if (abs(event.y - downY) > touchSlop) draggedSinceLift = true
            updateDropTarget(event.y)
            autoScrollIfNeeded(event)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (!dragging) {
                // Touches that started on empty space (or after a cancelled
                // lift) are not ours.
                return false
            }
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE -> handleDragMove(event)
                MotionEvent.ACTION_UP -> {
                    // The release point decides the drop even when no
                    // intermediate move event was delivered.
                    if (abs(event.y - downY) > touchSlop) {
                        draggedSinceLift = true
                        updateDropTarget(event.y)
                    }
                    finishDrag(commit = true)
                }
                MotionEvent.ACTION_CANCEL -> finishDrag(commit = false)
            }
            return true
        }

        private fun finishDrag(commit: Boolean) {
            val row = pressedRow
            val meta = pressedMeta
            val placement = pendingPlacement
            dragging = false
            pendingPlacement = null
            hideIndicators()
            row?.animate()?.cancel()
            row?.scaleX = 1f
            row?.scaleY = 1f
            row?.alpha = 1f
            row?.translationY = 0f
            row?.elevation = 0f
            parent?.requestDisallowInterceptTouchEvent(false)
            if (meta == null) return
            if (commit && placement != null) {
                // Reveal a drop into a collapsed folder, like iOS.
                collapsedFolderIds.remove(placement.first)
                mutate(obj(
                    "type" to "move_node",
                    "kind" to meta.kind,
                    "id" to meta.id,
                    "folder_id" to placement.first,
                    "position" to placement.second
                ))
            } else if (commit && !draggedSinceLift) {
                // Lifted but never dragged: treat as the row's context menu.
                if (meta.kind == "folder") showFolderActions(meta.node) else showSchemeActions(meta.node)
            }
        }

        private fun updateDropTarget(y: Float) {
            val meta = pressedMeta ?: return
            val raw = rawDrop(y)
            pendingPlacement = raw?.let { adjustPlacement(meta, it.folderId, it.position) }
            if (pendingPlacement == null) {
                hideIndicators()
            } else {
                showIndicator(raw!!)
            }
        }

        private inner class RawNavDrop(
            val folderId: String,
            val position: Int,
            val lineY: Float,
            val lineDepth: Int,
            val intoRow: View?
        )

        private fun rawDrop(y: Float): RawNavDrop? {
            if (rowMetas.isEmpty()) return null
            val rootId = rootFolderId() ?: return null
            val rootCount = snapshot.optJSONObject("root")?.optJSONArray("children")?.length() ?: 0
            val firstView = rowMetas.first().first
            val lastView = rowMetas.last().first
            val yInList = y - list.top
            if (yInList < firstView.top) {
                return RawNavDrop(rootId, 0, (firstView.top + list.top).toFloat(), 0, null)
            }
            if (yInList >= lastView.bottom) {
                return RawNavDrop(rootId, rootCount, (lastView.bottom + list.top).toFloat(), 0, null)
            }
            val (view, meta) = rowAt(y) ?: return null
            val fraction = if (view.height > 0) (yInList - view.top) / view.height.toFloat() else 0.5f
            val isFolder = meta.kind == "folder"
            if (isFolder && meta.id != pressedMeta?.id && fraction > 0.32f && fraction < 0.68f) {
                return RawNavDrop(meta.id, meta.childCount, -1f, 0, view)
            }
            val after = fraction >= 0.5f
            if (after && isFolder && !collapsedFolderIds.contains(meta.id)) {
                // The visible gap below an expanded folder header is its first
                // child slot.
                return RawNavDrop(meta.id, 0, (view.bottom + list.top).toFloat(), meta.depth + 1, null)
            }
            val position = meta.siblingIndex + if (after) 1 else 0
            val lineY = ((if (after) view.bottom else view.top) + list.top).toFloat()
            return RawNavDrop(meta.parentId, position, lineY, meta.depth, null)
        }

        /// Resolves a raw sibling slot against the post-removal child list and
        /// rejects no-ops and folder-into-own-subtree moves (iOS parity).
        private fun adjustPlacement(dragged: NavRowMeta, folderId: String, position: Int): Pair<String, Int>? {
            if (dragged.kind == "folder") {
                if (folderId == dragged.id || jsonNodeContains(dragged.node, folderId)) return null
            }
            val root = snapshot.optJSONObject("root") ?: return null
            val targetParent = if (folderId == root.optString("id")) root else nodeById(folderId, root)
            val targetChildren = targetParent?.optJSONArray("children")?.length() ?: return null
            val sameParent = dragged.parentId == folderId
            var adjusted = position
            if (sameParent && dragged.siblingIndex < position) adjusted = max(0, adjusted - 1)
            val targetCount = targetChildren - if (sameParent) 1 else 0
            adjusted = adjusted.coerceIn(0, max(0, targetCount))
            if (sameParent && adjusted == dragged.siblingIndex) return null
            return folderId to adjusted
        }

        private fun jsonNodeContains(node: JSONObject, id: String): Boolean {
            val children = node.optJSONArray("children") ?: return false
            for (index in 0 until children.length()) {
                val child = children.optJSONObject(index) ?: continue
                if (child.optString("id") == id || jsonNodeContains(child, id)) return true
            }
            return false
        }

        private fun showIndicator(raw: RawNavDrop) {
            if (raw.intoRow != null) {
                dropLine.visibility = GONE
                folderHighlight.visibility = VISIBLE
                folderHighlight.layoutParams = LayoutParams(width - dp(6), rowHeight - dp(4)).apply {
                    leftMargin = dp(3)
                    topMargin = raw.intoRow.top + list.top + dp(2)
                }
                folderHighlight.bringToFront()
            } else {
                folderHighlight.visibility = GONE
                val indent = dp(8 + raw.lineDepth * 10)
                dropLine.visibility = VISIBLE
                dropLine.layoutParams = LayoutParams(max(dp(40), width - indent - dp(7)), dp(3)).apply {
                    leftMargin = indent
                    topMargin = (raw.lineY - dp(1)).roundToInt().coerceAtLeast(0)
                }
                dropLine.bringToFront()
            }
            pressedRow?.bringToFront()
        }

        private fun hideIndicators() {
            dropLine.visibility = GONE
            folderHighlight.visibility = GONE
        }

        /// Nudges the enclosing page scroll when a drag nears its edges.
        private fun autoScrollIfNeeded(event: MotionEvent) {
            var ancestor = parent
            while (ancestor != null && ancestor !is ScrollView) {
                ancestor = ancestor.parent
            }
            val scroll = ancestor as? ScrollView ?: return
            val location = IntArray(2)
            getLocationInWindow(location)
            val scrollLocation = IntArray(2)
            scroll.getLocationInWindow(scrollLocation)
            val yInScroll = location[1] + event.y - scrollLocation[1]
            val edge = dp(56)
            if (yInScroll < edge) {
                scroll.scrollBy(0, -dp(12))
            } else if (yInScroll > scroll.height - edge) {
                scroll.scrollBy(0, dp(12))
            }
        }
    }


    internal fun rescheduleNotifications() {
        if (!::bridge.isInitialized) return
        try {
            MobileNotificationScheduler.reschedule(
                this,
                bridge.requestArray(obj("type" to "pending_notifications"))
            )
            // Also clear banners for events that ended or occurrences completed,
            // which reschedule() leaves in the tray once they've already fired.
            MobileNotificationScheduler.clearStale(
                this,
                bridge.requestArray(obj("type" to "delivered_notifications_to_clear"))
            )
        } catch (error: RuntimeException) {
            showError("Notifications unavailable", error.message)
        }
    }

    /// Fetch the current FCM registration token and hand it to the live core so
    /// the next sync registers this device for silent background pushes. Token
    /// rotation is handled separately by KnotQMessagingService.onNewToken; this
    /// covers the common cold-start-with-existing-token case. Best-effort: if
    /// Play services are unavailable the listener simply never fires.
    internal fun registerForPushNotifications() {
        runCatching {
            com.google.firebase.messaging.FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token ->
                    if (token.isNullOrBlank()) return@addOnSuccessListener
                    PushRegistration.store(this, token)
                    if (::bridge.isInitialized) PushRegistration.apply(bridge, token)
                }
        }
    }

    internal fun showOnboardingOverlay() {
        if (!onboardingActive || !::rootFrame.isInitialized) return
        removeOnboardingOverlay()
        val overlay = if (onboardingPhase == ONBOARDING_ACCOUNT) buildAccountOverlay() else buildGuideOverlay()
        rootFrame.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        onboardingOverlay = overlay
    }

    internal fun removeOnboardingOverlay() {
        onboardingOverlay?.let { if (::rootFrame.isInitialized) rootFrame.removeView(it) }
        onboardingOverlay = null
    }
}
