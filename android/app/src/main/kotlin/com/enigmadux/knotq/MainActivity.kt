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
    // The inline cell editor currently shown (if any), so a second tap commits
    // the first before moving on.
    internal var activeCellEdit: ActiveCellEdit? = null
    internal var tableStructureDialogOpen = false

    /// The floating inline table-cell editor currently shown, with everything
    /// needed to commit its per-line diff back to the core.
    internal class ActiveCellEdit(
        val editor: SchemeEditText,
        val field: EditText,
        val schemeId: String,
        val itemId: String,
        val hit: TableCellHit,
        val oldLines: List<String>,
    )
    internal enum class TableStructureAction {
        INSERT_ROW_ABOVE,
        INSERT_ROW_BELOW,
        DELETE_ROW,
        INSERT_COLUMN_LEFT,
        INSERT_COLUMN_RIGHT,
        DELETE_COLUMN
    }
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
    // Coalesces the sync triggered right after each local edit (iOS pushes on
    // every mutate; the short delay batches rapid editing bursts).
    internal val syncEditRunnable = Runnable { syncOnce() }
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
                    runOnUiThread { purchaseInProgress = false }
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED ->
                runOnUiThread { purchaseInProgress = false }
            else -> runOnUiThread {
                purchaseInProgress = false
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
            ensureTodayDailyQueue()
            applyTheme()
            buildShell()
            render()
            maybeStartOnboarding()
            MobileNotificationScheduler.requestPermission(this)
            rescheduleNotifications()
            sharedBridge = bridge
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
    }

    override fun onResume() {
        super.onResume()
        if (!::bridge.isInitialized) return
        maybeRequestStoreReview()
    }

    override fun onStop() {
        isInForeground = false
        syncPollHandler.removeCallbacks(syncPollRunnable)
        syncPollHandler.removeCallbacks(syncEditRunnable)
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        googleSyncPollingActive = false
        // Mirror iOS applicationDidEnterBackground: keep workspace data fresh
        // via periodic background refresh while signed in to sync.
        if (::bridge.isInitialized) scheduleBackgroundSyncWork()
        super.onStop()
    }

    override fun onDestroy() {
        syncPollHandler.removeCallbacks(syncPollRunnable)
        syncPollHandler.removeCallbacks(syncEditRunnable)
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

    internal fun maybeStartOnboarding() {
        if (onboardingActive) return
        if (getSharedPreferences("knotq", MODE_PRIVATE).getBoolean(ONBOARDING_PREF, false)) return
        if (snapshot.optJSONObject("root") == null) return
        onboardingActive = true
        onboardingStep = 0
        if (syncSession != null) {
            // Already signed in: skip the account step, go straight to the tour.
            onboardingPhase = ONBOARDING_GUIDE
            applyOnboardingStep(0)
        } else {
            onboardingPhase = ONBOARDING_ACCOUNT
            showOnboardingOverlay()
        }
    }

    internal fun startOnboardingGuide() {
        onboardingPhase = ONBOARDING_GUIDE
        applyOnboardingStep(0)
    }

    /// Navigates to the step's pane (mirrors desktop) and then redraws the overlay
    /// once the new content has been laid out so the cutout hugs it.
    internal fun applyOnboardingStep(step: Int) {
        onboardingStep = step.coerceIn(0, ONBOARDING_STEPS.size - 1)
        when (ONBOARDING_STEPS[onboardingStep].tab) {
            TAB_SCHEMES -> {
                val id = firstRegularSchemeId()
                if (id != null) {
                    selectedTab = TAB_SCHEMES
                    selectedSchemeId = id
                } else {
                    // No schemes yet: fall back to Home (mirrors desktop).
                    selectedTab = TAB_HOME
                    selectedSchemeId = null
                }
            }
            TAB_DAILY -> {
                ensureTodayDailyQueue()
                selectedTab = TAB_DAILY
                selectedSchemeId = null
            }
            else -> {
                selectedTab = ONBOARDING_STEPS[onboardingStep].tab
                selectedSchemeId = null
            }
        }
        render()
        rootFrame.post { showOnboardingOverlay() }
    }

    internal fun onboardingAdvance() {
        if (onboardingStep >= ONBOARDING_STEPS.size - 1) {
            finishOnboarding()
        } else {
            applyOnboardingStep(onboardingStep + 1)
        }
    }

    internal fun onboardingBack() {
        if (onboardingStep <= 0) {
            if (syncSession == null) {
                onboardingPhase = ONBOARDING_ACCOUNT
                showOnboardingOverlay()
            }
            return
        }
        applyOnboardingStep(onboardingStep - 1)
    }

    internal fun finishOnboarding() {
        onboardingActive = false
        getSharedPreferences("knotq", MODE_PRIVATE).edit().putBoolean(ONBOARDING_PREF, true).apply()
        removeOnboardingOverlay()
        selectedTab = TAB_HOME
        selectedSchemeId = null
        render()
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

    internal fun buildAccountOverlay(): View {
        val overlay = FrameLayout(this).apply {
            isClickable = true
            setOnClickListener { } // swallow taps to the app behind the scrim
            setBackgroundColor(Color.argb(158, 0, 0, 0))
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(22), dp(20), dp(18))
            background = rounded(theme.bgModal, dp(16), theme.borderOverlay)
        }
        card.addView(brandMark(60), LinearLayout.LayoutParams(dp(60), dp(60)).apply { bottomMargin = dp(14) })
        card.addView(text("KnotQ", theme.textPrimary, 24f, true).apply { gravity = Gravity.CENTER })
        card.addView(
            text("Local-first planning with optional sync.", theme.textSoft, 13f, false).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4); bottomMargin = dp(18) }
        )
        card.addView(
            onboardingButton("Sign in or create account", true) { showSyncAccountDialog() },
            LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(10) }
        )
        card.addView(
            onboardingButton("Continue without account", false) { startOnboardingGuide() },
            LinearLayout.LayoutParams(-1, -2)
        )
        card.addView(
            text("You can add or remove sync later from Settings.", theme.textMuted, 11f, false).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(14) }
        )
        val width = min(dp(380), resources.displayMetrics.widthPixels - dp(40))
        overlay.addView(card, FrameLayout.LayoutParams(width, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        return overlay
    }

    internal fun buildGuideOverlay(): View {
        val def = ONBOARDING_STEPS[onboardingStep]
        val cutout = if (def.ringsContent) {
            val r = contentRectInRoot()
            if (r.width() > 0 && r.height() > 0) {
                // Inset to keep the ring on-screen and clear of the floating dock.
                Rect(r.left + dp(6), r.top + dp(6), r.right - dp(6), max(r.top + dp(48), r.bottom - dp(76)))
            } else {
                null
            }
        } else {
            null
        }

        val overlay = FrameLayout(this).apply {
            isClickable = true
            setOnClickListener { } // tour is driven by Back / Skip / Next
        }
        overlay.addView(buildSpotlightScrim(cutout), FrameLayout.LayoutParams(-1, -1))

        val cardWidth = min(dp(360), resources.displayMetrics.widthPixels - dp(32))
        val lp = FrameLayout.LayoutParams(cardWidth, FrameLayout.LayoutParams.WRAP_CONTENT)
        if (cutout == null) {
            lp.gravity = Gravity.CENTER
        } else {
            lp.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            lp.bottomMargin = dp(84)
        }
        overlay.addView(buildGuideCard(), lp)
        return overlay
    }

    internal fun buildSpotlightScrim(cutout: Rect?): View {
        val dimColor = Color.argb(158, 0, 0, 0)
        val ringColor = theme.accent
        val radius = dp(14).toFloat()
        return object : View(this) {
            private val dimPaint = Paint().apply { color = dimColor }
            private val clearPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
            }
            private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = dp(2).toFloat()
                color = ringColor
            }

            init {
                setLayerType(LAYER_TYPE_SOFTWARE, null)
            }

            override fun onDraw(canvas: Canvas) {
                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), dimPaint)
                cutout?.let { r ->
                    val rect = RectF(r.left.toFloat(), r.top.toFloat(), r.right.toFloat(), r.bottom.toFloat())
                    canvas.drawRoundRect(rect, radius, radius, clearPaint)
                    canvas.drawRoundRect(rect, radius, radius, ringPaint)
                }
            }
        }
    }

    internal fun buildGuideCard(): View {
        val def = ONBOARDING_STEPS[onboardingStep]
        val isLast = onboardingStep >= ONBOARDING_STEPS.size - 1
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(14))
            background = rounded(theme.bgModal, dp(14), theme.borderOverlay)
            elevation = dp(12).toFloat()
        }

        val dots = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        ONBOARDING_STEPS.indices.forEach { i ->
            val active = i == onboardingStep
            dots.addView(View(this).apply {
                background = rounded(if (active) theme.accent else adjustAlpha(theme.borderOverlay, 0.6f), dp(3))
            }, LinearLayout.LayoutParams(dp(if (active) 18 else 6), dp(6)).apply { rightMargin = dp(5) })
        }
        card.addView(dots, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = dp(12) })

        card.addView(text(def.title, theme.textPrimary, 18f, true))
        card.addView(
            text(def.body, theme.textSoft, 13f, false).apply {
                gravity = Gravity.START
                setLineSpacing(dp(3).toFloat(), 1f)
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(7); bottomMargin = dp(14) }
        )

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        if (onboardingStep > 0) {
            buttons.addView(
                onboardingButton("Back", false) { onboardingBack() },
                LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) }
            )
        }
        buttons.addView(text("Skip", theme.textMuted, 13f, true).apply {
            setPadding(dp(4), dp(10), dp(12), dp(10))
            setOnClickListener { finishOnboarding() }
        }, LinearLayout.LayoutParams(-2, -2))
        buttons.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) // spacer
        buttons.addView(
            onboardingButton(if (isLast) "Done" else "Next", true) { onboardingAdvance() },
            LinearLayout.LayoutParams(-2, -2)
        )
        card.addView(buttons, LinearLayout.LayoutParams(-1, -2))
        return card
    }

    internal fun onboardingButton(label: String, prominent: Boolean, listener: () -> Unit): TextView =
        text(label, if (prominent) Color.WHITE else theme.textPrimary, 14f, true).apply {
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(11), dp(16), dp(11))
            background = if (prominent) {
                rounded(theme.accent, dp(8))
            } else {
                rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            }
            setOnClickListener { listener() }
        }

    internal fun contentRectInRoot(): Rect {
        val rootLoc = IntArray(2)
        rootFrame.getLocationInWindow(rootLoc)
        val cLoc = IntArray(2)
        content.getLocationInWindow(cLoc)
        val left = cLoc[0] - rootLoc[0]
        val top = cLoc[1] - rootLoc[1]
        return Rect(left, top, left + content.width, top + content.height)
    }

    internal fun firstRegularSchemeId(): String? =
        snapshot.optJSONObject("root")?.let { firstRegularSchemeId(it) }

    internal fun firstRegularSchemeId(node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            when (child.optString("kind")) {
                "folder" -> firstRegularSchemeId(child)?.let { return it }
                "scheme" -> {
                    if (!child.optBoolean("is_daily_queue", false) && !child.optBoolean("is_read_only", false)) {
                        child.optString("id").takeIf { it.isNotEmpty() }?.let { return it }
                    }
                }
            }
        }
        return null
    }

    internal fun renderWideShell(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(theme.bgApp)
            addView(renderNavigator(), LinearLayout.LayoutParams(dp(160), -1).apply {
                setMargins(dp(7), dp(7), 0, dp(7))
            })
            addView(renderUpcomingRail(), LinearLayout.LayoutParams(dp(258), -1))
            addView(View(this@MainActivity).apply { setBackgroundColor(theme.dividerTiny) }, LinearLayout.LayoutParams(dp(1), -1))
            addView(renderMain(), LinearLayout.LayoutParams(0, -1, 1f))
        }
    }

    internal fun renderPhoneMain(): View =
        when (selectedTab) {
            TAB_SEARCH, TAB_SETTINGS -> scroll(renderMain())
            else -> renderMain()
        }

    internal fun renderMain(): View {
        return when (selectedTab) {
            TAB_HOME -> renderHome()
            TAB_CALENDAR -> renderCalendar()
            TAB_SCHEMES -> selectedSchemeId?.let(::findScheme)?.let(::renderSchemeEditor) ?: renderListsPage()
            TAB_DAILY -> renderDaily()
            TAB_SEARCH -> renderSearch()
            TAB_SETTINGS -> renderSettings()
            else -> renderHome()
        }
    }

    internal fun renderNavigator(): View {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(10), dp(8), dp(8))
            background = rounded(theme.bgSidebar, dp(10), theme.borderOverlay)
        }
        panel.addView(navSpecial("Home", theme.accent, selectedTab == TAB_HOME) {
            selectedTab = TAB_HOME
            selectedSchemeId = null
            render()
        })
        panel.addView(navSpecial("Calendar", theme.textPrimary, selectedTab == TAB_CALENDAR) {
            selectedTab = TAB_CALENDAR
            selectedSchemeId = null
            render()
        })
        panel.addView(navSpecial("Daily", if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad), selectedTab == TAB_DAILY) {
            selectedTab = TAB_DAILY
            selectedSchemeId = null
            ensureDaily()
        })
        panel.addView(divider(), LinearLayout.LayoutParams(-1, dp(1)).apply {
            setMargins(dp(3), dp(7), dp(3), dp(8))
        })

        val tree = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject { addNode(tree, it, 0) }
        panel.addView(scroll(tree), LinearLayout.LayoutParams(-1, 0, 1f))
        panel.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(iconActionChip(GLYPH_ADD, "New") { showNewMenu() }, LinearLayout.LayoutParams(0, dp(30), 1f))
            addView(chip(GLYPH_SETTINGS) {
                selectedTab = TAB_SETTINGS
                selectedSchemeId = null
                render()
            }, LinearLayout.LayoutParams(dp(33), dp(30)).apply { setMargins(dp(6), 0, 0, 0) })
        })
        return panel
    }

    internal fun renderHome(): LinearLayout {
        if (!isWideLayout()) return renderPhoneHome()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(homeHeader(), spaced())
        body.addView(homeQuickActions(), LinearLayout.LayoutParams(-1, dp(34)).apply {
            setMargins(0, 0, 0, dp(14))
        })
        body.addView(sectionHeader("Today"))
        body.addView(homeDailySummaryRow(), LinearLayout.LayoutParams(-1, dp(48)).apply {
            setMargins(0, 0, 0, dp(8))
        })
        addOccurrenceSection(body, "Today", "None today", todayOccurrences())

        body.addView(sectionHeader("Schemes"))
        val tree = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject {
            addNode(tree, it, 0, spacious = true)
        }
        if (tree.childCount == 0) {
            tree.addView(text("No schemes", theme.textMuted, 13f, false).apply {
                setPadding(dp(8), dp(6), dp(8), dp(10))
            })
        }
        body.addView(tree, spaced())
        body.addView(archiveNavigatorSection(compact = false), spaced())

        if (resources.configuration.screenWidthDp < 760) {
            val combined = JSONArray()
            calendar().optJSONArray("overdue")?.forEachObject { if (combined.length() < 14) combined.put(it) }
            calendar().optJSONArray("upcoming")?.forEachObject { if (combined.length() < 14) combined.put(it) }
            addOccurrenceSection(body, "Upcoming", "Nothing scheduled", combined)
        }
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun renderPhoneHome(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(homeSearchEntry(), LinearLayout.LayoutParams(-1, dp(42)).apply {
            setMargins(0, dp(2), 0, dp(15))
        })
        body.addView(phoneSchemesSection(), spaced())
        // Overdue first so it isn't missed, then upcoming, capped like iOS.
        val combined = JSONArray()
        calendar().optJSONArray("overdue")?.forEachObject { if (combined.length() < 14) combined.put(it) }
        calendar().optJSONArray("upcoming")?.forEachObject { if (combined.length() < 14) combined.put(it) }
        addOccurrenceSection(body, "Upcoming", "Nothing scheduled", combined)
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun homeSearchEntry(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = rounded(theme.bgModal, dp(8), theme.borderOverlay)
            addView(text("Search KnotQ", theme.textMuted, 14f, false), LinearLayout.LayoutParams(0, -1, 1f))
            addView(iconImage(R.drawable.ic_knotq_search_24, theme.textMuted, "Search"), LinearLayout.LayoutParams(dp(28), dp(ICON_SEARCH_VECTOR_SIZE_DP)))
            setOnClickListener {
                selectedTab = TAB_SEARCH
                selectedSchemeId = null
                render()
            }
        }

    internal fun phoneSchemesSection(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text("Schemes", theme.textPrimary, 20f, true), LinearLayout.LayoutParams(0, dp(34), 1f))
            addView(iconSquareImage(R.drawable.ic_knotq_plus_24, "New", iconSize = 17) { showNewMenu() }, LinearLayout.LayoutParams(dp(30), dp(30)))
        }, LinearLayout.LayoutParams(-1, dp(37)).apply {
            setMargins(dp(2), 0, dp(2), dp(3))
        })

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(if (theme.isDark) theme.bgToolbar else theme.bgModal, dp(8), theme.borderOverlay)
            setPadding(dp(4), dp(4), dp(4), dp(3))
        }
        panel.addView(NavigatorPanel(this), LinearLayout.LayoutParams(-1, -2))
        panel.addView(View(this).apply { setBackgroundColor(theme.dividerSoft) }, LinearLayout.LayoutParams(-1, max(1, (0.5f * resources.displayMetrics.density).roundToInt())).apply {
            setMargins(dp(4), dp(3), dp(4), dp(3))
        })
        panel.addView(homeDailySchemeRow(), LinearLayout.LayoutParams(-1, dp(42)))
        root.addView(panel)
        return root
    }

    /// Scheme tree with iOS-style direct manipulation: tap folders to
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

    internal fun homeDailySchemeRow(): View {
        val entry = dailyEntryForHome()
        val scheme = entry?.optJSONObject("scheme")
        val openCount = countOpenItems(scheme)
        val date = entry?.optString("date") ?: selectedDate.toString()
        val detail = when {
            openCount == 0 -> MobileDateFormatting.shortDay(date)
            else -> "${MobileDateFormatting.shortDay(date)} · $openCount"
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            addView(colorSquare(dailyAccent(), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply {
                setMargins(0, 0, dp(9), 0)
            })
            addView(text("Daily", theme.textPrimary, 14f, true), LinearLayout.LayoutParams(-2, -1))
            addView(text(detail, theme.textSoft, 12f, true).apply {
                setPadding(dp(9), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(inlineIcon(R.drawable.ic_knotq_chevron_right_24, theme.textMuted, widthDp = 24, iconSize = 16))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                runCatching { LocalDate.parse(date) }.getOrNull()?.let { selectedDate = it }
                ensureDaily()
            }
        }
    }

    internal fun homeHeader(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(brandMark(36), LinearLayout.LayoutParams(dp(36), dp(36)).apply {
                setMargins(0, 0, dp(10), 0)
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(text("KnotQ", theme.textPrimary, 22f, true), LinearLayout.LayoutParams(-1, dp(24)))
                addView(text(MobileDateFormatting.fullDay(selectedDate.toString()), theme.textDim, 12f, false), LinearLayout.LayoutParams(-1, dp(16)))
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }

    internal fun homeQuickActions(): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(iconActionChip(GLYPH_TICK, "Daily Item") { addDailyItemFromHome() }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_CALENDAR, "Calendar") { showCalendarItemDialog() }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_EDIT, "New Scheme") {
                    showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
                        mutate(obj("type" to "create_scheme", "name" to name, "position" to 0))
                    }
                }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_FOLDER, "New Folder") {
                    showNameDialog("New Folder", "", { validateFolderName(it) }) { name ->
                        mutate(obj("type" to "create_folder", "name" to name))
                    }
                }, LinearLayout.LayoutParams(-2, dp(30)))
                addView(iconActionChip(GLYPH_CLOUD, "Google") { startGoogleCalendarImport() }, LinearLayout.LayoutParams(-2, dp(30)))
            })
        }

    internal fun homeDailySummaryRow(): View {
        val entry = dailyEntryForHome()
        val scheme = entry?.optJSONObject("scheme")
        val itemCount = scheme?.optJSONArray("items")?.length() ?: 0
        val doneCount = countDoneItems(scheme)
        val date = entry?.optString("date") ?: selectedDate.toString()
        val detail = if (itemCount == 0) "No items" else "$doneCount / $itemCount complete"
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), 0, dp(8), 0)
            background = rounded(theme.rowSelected, dp(7), theme.dividerSoft)
            addView(colorSquare(dailyAccent(), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply {
                setMargins(0, 0, dp(9), 0)
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(text("Daily", theme.textPrimary, 14f, true), LinearLayout.LayoutParams(-1, dp(20)))
                addView(text("${MobileDateFormatting.shortDay(date)} · $detail", theme.textDim, 12f, false), LinearLayout.LayoutParams(-1, dp(17)))
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(text(GLYPH_ADD, theme.textPrimary, ICON_ROW_SIZE_SP, true).apply {
                gravity = Gravity.CENTER
                setOnClickListener { addDailyItemFromHome() }
            }, LinearLayout.LayoutParams(dp(32), dp(34)))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                runCatching { LocalDate.parse(date) }.getOrNull()?.let { selectedDate = it }
                ensureDaily()
            }
        }
    }

    internal fun countDoneItems(scheme: JSONObject?): Int {
        var done = 0
        scheme?.optJSONArray("items")?.forEachObject { item ->
            if (item.optBoolean("done")) done++
        }
        return done
    }

    // Matches iOS HomeDailySchemeRow.openCount: not done, non-blank text.
    internal fun countOpenItems(scheme: JSONObject?): Int {
        var open = 0
        scheme?.optJSONArray("items")?.forEachObject { item ->
            if (!item.optBoolean("done") && item.optString("text").trim().isNotEmpty()) open++
        }
        return open
    }

    internal fun renderListsPage(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(sectionHeader("Schemes"))
        body.addView(dailyShortcutRow(), LinearLayout.LayoutParams(-1, dp(30)).apply {
            setMargins(0, 0, 0, dp(6))
        })
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject {
            addNode(list, it, 0, spacious = true)
        }
        body.addView(list)
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun dailyShortcutRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(7), 0)
            background = rounded(Color.TRANSPARENT, dp(4))
            addView(colorSquare(dailyAccent(), 9), LinearLayout.LayoutParams(dp(9), dp(9)).apply {
                setMargins(0, 0, dp(7), 0)
            })
            addView(text("Daily", theme.textPrimary, 13f, true).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(text(GLYPH_RIGHT, theme.textMuted, ICON_TOOL_SIZE_SP, true).apply { gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(16), -1))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                ensureDaily()
            }
        }

    internal fun archiveNavigatorSection(compact: Boolean): View {
        val schemes = archivedSchemes()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val title = if (schemes.length() == 0) "Archive" else "Archive ${schemes.length()}"
        root.addView(text(title, theme.textDim, if (compact) 12f else 14f, true).apply {
            setPadding(dp(if (compact) 6 else 8), dp(if (compact) 5 else 8), dp(6), dp(if (compact) 4 else 6))
            setOnLongClickListener {
                if (schemes.length() > 0) showArchiveActions()
                true
            }
        })
        if (schemes.length() == 0) {
            if (!compact) {
                root.addView(text("No archived schemes", theme.textMuted, 13f, false).apply {
                    setPadding(dp(8), 0, dp(8), dp(4))
                })
            }
            return root
        }
        schemes.forEachObject { scheme ->
            root.addView(archivedSchemeRow(scheme, compact), LinearLayout.LayoutParams(-1, if (compact) dp(22) else dp(40)))
        }
        return root
    }

    internal fun archivedSchemeRow(scheme: JSONObject, compact: Boolean): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(if (compact) 6 else 10), 0, dp(7), 0)
            addView(colorSquare(adjust(schemeColor(scheme.optInt("color_index")), 0.72f), if (compact) 9 else 10), LinearLayout.LayoutParams(dp(if (compact) 9 else 10), dp(if (compact) 9 else 10)))
            addView(text(scheme.optString("display_name"), theme.textMuted, if (compact) 12f else 14f, false).apply {
                maxLines = 1
            }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (compact) 7 else 10), 0, 0, 0)
            })
            if (!compact) {
                addView(iconChip(GLYPH_TICK, {
                    mutate(obj("type" to "restore_scheme", "scheme_id" to scheme.optString("id")))
                }), LinearLayout.LayoutParams(dp(28), dp(28)))
            }
            setOnClickListener { showArchivedSchemeActions(scheme) }
            setOnLongClickListener {
                showArchivedSchemeActions(scheme)
                true
            }
        }

    internal fun renderUpcomingRail(): View {
        val root = page(compact = true)
        addOccurrenceSection(root, "Overdue", "None", calendar().optJSONArray("overdue"))
        addOccurrenceSection(root, "Today", "None today", todayOccurrences())
        addOccurrenceSection(root, "Upcoming", "None", calendar().optJSONArray("upcoming"))
        return scroll(root)
    }

    internal fun renderCalendar(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(calendarToolbar())

        // Show a run of day columns from the fetched week, anchored on the selected
        // day. Indexing into the fetched days (rather than absolute dates) keeps the
        // columns aligned with the data even while browsing other weeks.
        val columns = calendarVisibleDayCount()
        val dayObjects = calendarDayObjects()
        val startIndex = calendarVisibleStartIndex(dayObjects)
        val renderStartIndex = max(0, startIndex - 1)
        val renderEndIndex = min(dayObjects.size, startIndex + columns + 1)
        val renderDays = if (dayObjects.isEmpty()) emptyList()
        else dayObjects.subList(renderStartIndex, renderEndIndex).toList()
        val leadingColumns = startIndex - renderStartIndex

        val timeline = CalendarTimelineView(this).apply {
            configure(renderDays, columns, leadingColumns)
        }

        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(timeline, LinearLayout.LayoutParams(-1, -2))

        val scrollView = ScrollView(this).apply {
            setBackgroundColor(theme.bgApp)
            isVerticalScrollBarEnabled = false
            addView(column)
        }
        scrollView.viewTreeObserver.addOnScrollChangedListener {
            calendarScrollY = scrollView.scrollY
            timeline.onViewportChanged(scrollView.scrollY, scrollView.height)
        }
        // Anchor the scroll near "now" when today is one of the visible columns
        // (else early morning); keep the user's position when the same day
        // re-renders for another reason.
        val dateKey = selectedDate.toString()
        val target = if (calendarScrollDate != dateKey) {
            val visibleHasToday = (0 until columns).any { selectedDate.plusDays(it.toLong()) == LocalDate.now() }
            val hour = if (visibleHasToday) max(0, LocalTime.now().hour - 1) else 7
            dp(8) + dp(44) * hour
        } else {
            calendarScrollY
        }
        calendarScrollDate = dateKey
        // Apply the anchor during the first layout pass (before the first
        // draw) — a post{} lands a frame late and flashes the unscrolled
        // timeline first.
        var appliedCalendarAnchor = false
        scrollView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            if (!appliedCalendarAnchor && scrollView.height > 0) {
                appliedCalendarAnchor = true
                scrollView.scrollTo(0, target)
                timeline.onViewportChanged(scrollView.scrollY, scrollView.height)
            }
        }
        root.addView(scrollView, LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun calendarVisibleDayCount(): Int = when {
        resources.configuration.screenWidthDp >= 760 -> 5
        resources.configuration.screenWidthDp >= 600 -> 3
        else -> 2
    }

    internal fun calendarDayObjects(): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        calendar().optJSONArray("days")?.let { arr ->
            for (i in 0 until arr.length()) arr.optJSONObject(i)?.let(out::add)
        }
        return out
    }

    /// First column index into the fetched week: the selected day, clamped so the
    /// visible run always stays within the available days. Both the timeline and
    /// the week strip use this so their highlights stay in sync.
    internal fun calendarVisibleStartIndex(days: List<JSONObject>): Int {
        val count = calendarVisibleDayCount()
        val selectedIndex = days.indexOfFirst { it.optString("date") == selectedDate.toString() }.coerceAtLeast(0)
        return selectedIndex.coerceIn(0, max(0, days.size - count))
    }

    internal fun calendarToolbar(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = underline(theme.bgApp)
            addView(calendarTitleView(), LinearLayout.LayoutParams(-1, dp(42)))
            addView(calendarWeekStrip(), LinearLayout.LayoutParams(-1, dp(66)))
        }.also {
            it.layoutParams = LinearLayout.LayoutParams(-1, dp(108))
        }
    }

    internal fun calendarQuickAddRow(): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), dp(4), dp(8), 0)
                addView(iconActionChip(GLYPH_CALENDAR, "Event") {
                    quickCreateCalendarItem("event")
                }, marginRight(dp(6), -2, dp(24)))
                addView(iconActionChip(GLYPH_BELL, "Reminder") {
                    quickCreateCalendarItem("reminder")
                }, marginRight(dp(6), -2, dp(24)))
                addView(iconActionChip(GLYPH_TICK, "Assignment") {
                    quickCreateCalendarItem("assignment")
                }, LinearLayout.LayoutParams(-2, dp(24)))
            })
        }

    internal fun quickCreateCalendarItem(kind: String) {
        val initialKind = when (kind) {
            "event", "reminder", "assignment" -> kind
            else -> "task"
        }
        val now = LocalDateTime.now()
        showEventEditorDialog(
            occurrence = null,
            initialDate = selectedDate,
            initialMinute = (now.hour * 60 + now.minute).toFloat(),
            preferredKind = initialKind,
            openForNew = true
        )
    }

    internal fun calendarTitleView(): View =
        FrameLayout(this).apply {
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(dp(14), 0, dp(12), 0)
                background = rounded(adjustAlpha(theme.textPrimary, if (theme.isDark) 0.07f else 0.055f), dp(18), theme.borderOverlay)
                addView(text(monthTitle(selectedDate), theme.textPrimary, 18f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                }, LinearLayout.LayoutParams(-2, dp(34)))
                addView(inlineIcon(R.drawable.ic_knotq_chevron_down_24, theme.textMuted, widthDp = 18, iconSize = 15), LinearLayout.LayoutParams(dp(18), dp(34)).apply {
                    setMargins(dp(3), 0, 0, 0)
                })
                setOnClickListener { showMonthPickerDialog() }
            }, FrameLayout.LayoutParams(-2, dp(34), Gravity.CENTER))
        }

    internal fun calendarWeekStrip(): View =
        FrameLayout(this).apply {
            val stripDates = (0 until 7).map { weekStart(selectedDate).plusDays(it.toLong()) }
            val count = calendarVisibleDayCount()
            val visibleDates = (0 until count).map { selectedDate.plusDays(it.toLong()).toString() }.toSet()
            addView(CalendarWeekHighlightView(this@MainActivity, stripDates, visibleDates), FrameLayout.LayoutParams(-1, -1))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            stripDates.forEachIndexed { offset, date ->
                val today = date == LocalDate.now()
                    val visible = visibleDates.contains(date.toString())
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                        addView(text(date.dayOfWeek.getDisplayName(TextStyle.NARROW, Locale.getDefault()).uppercase(Locale.getDefault()), if (today) calendarDayHighlightColor() else adjustAlpha(theme.textMuted, if (theme.isDark) 0.42f else 0.50f), 10f, true).apply {
                        gravity = Gravity.CENTER
                            includeFontPadding = false
                        }, LinearLayout.LayoutParams(-1, dp(16)))
                        addView(text(date.dayOfMonth.toString(), calendarWeekDayTextColor(today, visible), 18f, today).apply {
                        gravity = Gravity.CENTER
                            includeFontPadding = false
                        }, LinearLayout.LayoutParams(-1, dp(37)))
                    setOnClickListener {
                        selectedDate = date
                        weekOffset = 0
                            calendarScrollDate = date.toString()
                        loadSnapshot()
                        render()
                    }
                }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                        setMargins(0, dp(7), 0, dp(6))
                })
            }
            }, FrameLayout.LayoutParams(-1, -1))
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

    internal fun renderSchemeEditor(scheme: JSONObject): LinearLayout {
        val schemeId = scheme.optString("id")
        val readOnly = scheme.optBoolean("is_read_only", false)
        val originalLines = documentLines(scheme)
        lateinit var editor: SchemeEditText
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        // iOS editor chrome: back on the left; scheme color swatch + archive on
        // the right.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, "Back", iconSize = 20) {
                activeEditor()?.let { commitSchemeDocument(schemeId, it, rerender = false) }
                exitSchemeEditor()
            })
            addView(View(this@MainActivity), LinearLayout.LayoutParams(0, 1, 1f))
            if (!readOnly) {
                addView(iconChipImage(R.drawable.ic_knotq_table_24, "Insert table", iconSize = 17) {
                    insertTableFromEditor(schemeId, editor)
                }, LinearLayout.LayoutParams(dp(32), dp(28)).apply { setMargins(0, 0, dp(6), 0) })
            }
            addView(FrameLayout(this@MainActivity).apply {
                contentDescription = "Color"
                background = rounded(theme.buttonBg, dp(7))
                addView(View(this@MainActivity).apply {
                    background = rounded(schemeColor(scheme.optInt("color_index")), dp(4), theme.borderOverlay)
                }, FrameLayout.LayoutParams(dp(16), dp(16), Gravity.CENTER))
                setOnClickListener { showColorDialog(schemeId) }
            }, LinearLayout.LayoutParams(dp(32), dp(28)))
            if (!scheme.optBoolean("is_daily_queue", false)) {
                addView(iconChipImage(R.drawable.ic_knotq_archive_24, "Archive", iconSize = 17) {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Archive \"${scheme.optString("display_name", scheme.optString("name"))}\"?")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Archive") { _, _ ->
                            activeEditor()?.let { commitSchemeDocument(schemeId, it, rerender = false) }
                            mutate(obj("type" to "delete_scheme", "scheme_id" to schemeId))
                            exitSchemeEditor()
                        }
                        .show()
                }, LinearLayout.LayoutParams(dp(32), dp(28)).apply { setMargins(dp(6), 0, 0, 0) })
            }
        }, LinearLayout.LayoutParams(-1, dp(44)))

        editor = SchemeEditText(this).apply {
            setText(renderDocument(originalLines))
            placeCursorAtDocumentEnd(this)
            tag = originalLines
            editorSchemeIds[this] = schemeId
            editorTheme = theme
            accentColor = editorChromeColor()
            lineAdornments = editorLineAdornments(scheme, timeFormat24())
            markerTapHandler = { lineIndex -> toggleEditorLineMarker(this, lineIndex) }
            selectionChangedHandler = { formatBarMarkerRefresh?.invoke() }
            if (!readOnly) {
                tableCellTapHandler = { hit -> beginInlineCellEdit(schemeId, this, hit) }
            }
            isEnabled = !readOnly
            gravity = Gravity.TOP or Gravity.START
            setTextColor(theme.textPrimary)
            setHintTextColor(theme.textMuted)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setSingleLine(false)
            imeOptions = EditorInfo.IME_ACTION_DONE
            setTextSize(16f)
            setHorizontallyScrolling(false)
            setPadding(dp(EDITOR_TEXT_LEFT_PAD_DP), dp(2), dp(24), dp(170))
            setLineSpacing(0f, 1f)
            minHeight = max(dp(360), resources.displayMetrics.heightPixels - dp(210))
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            background = null
            setOnFocusChangeListener { _, hasFocus ->
                if (readOnly) return@setOnFocusChangeListener
                if (hasFocus) {
                    lastActiveEditor = this
                    hidePhoneDockForEditing()
                } else {
                    // Quiet commit: a full re-render here would destroy
                    // whatever the user just tapped (e.g. the title field).
                    showPhoneDockAfterEditing()
                    if (!suppressEditorBlurCommit) {
                        commitSchemeDocument(schemeId, this, rerender = false)
                    }
                }
            }
        }
        // The editor lives inside a host FrameLayout so the inline table-cell
        // editor can float a real EditField over the tapped cell, on top of the
        // canvas-drawn editor, without disturbing the single-document model.
        val editorHost = FrameLayout(this).apply {
            addView(editor, FrameLayout.LayoutParams(-1, -2))
        }
        editorHosts[editor] = editorHost
        val editorBody = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, 0)
            addView(schemeTitleBlock(scheme), LinearLayout.LayoutParams(-1, -2).apply {
                setMargins(dp(EDITOR_TEXT_LEFT_PAD_DP), 0, dp(24), dp(1))
            })
            addView(editorHost, LinearLayout.LayoutParams(-1, -2))
        }
        val editorScroll = scroll(editorBody)
        root.addView(editorScroll, LinearLayout.LayoutParams(-1, 0, 1f))
        editorScroll.post {
            placeCursorAtDocumentEnd(editor)
            // Plain scroll — fullScroll(FOCUS_DOWN) would transfer focus to the
            // editor, and its later blur-commit made the title untappable.
            editorScroll.scrollTo(0, max(0, editorBody.bottom - editorScroll.height))
        }
        if (readOnly) {
            root.addView(text("Imported calendar schemes are read-only.", theme.textMuted, 12f, false).apply {
                gravity = Gravity.CENTER
                setBackgroundColor(theme.bgToolbar)
            }, LinearLayout.LayoutParams(-1, dp(38)))
        } else {
            root.addView(editorFormatBar(schemeId, editor), LinearLayout.LayoutParams(-1, dp(38)))
        }
        return root
    }

    internal fun schemeTitleBlock(scheme: JSONObject): View {
        val schemeId = scheme.optString("id")
        val committed = scheme.optString("display_name", scheme.optString("name"))
        val input = edit(committed).apply {
            setSingleLine(true)
            isEnabled = !scheme.optBoolean("is_read_only", false)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_DONE
            textSize = 26f
            setTypeface(typeface, Typeface.BOLD)
            includeFontPadding = false
            minHeight = dp(34)
            background = null
            setPadding(0, 0, 0, 0)
        }
        val error = text("", theme.danger, 11f, true).apply {
            visibility = View.GONE
            setPadding(0, dp(1), 0, 0)
        }
        val validator = {
            validateSchemeName(
                input.text.toString(),
                folderId = if (scheme.optBoolean("is_daily_queue", false)) null else parentFolderIdForScheme(schemeId),
                excludingId = if (scheme.optBoolean("is_daily_queue", false)) null else schemeId,
                checkDuplicates = !scheme.optBoolean("is_daily_queue", false)
            )
        }
        fun refreshError(): String? {
            val message = validator()
            error.text = message.orEmpty()
            error.visibility = if (message == null) View.GONE else View.VISIBLE
            input.setTextColor(if (message == null) theme.textPrimary else theme.danger)
            return message
        }
        fun commitTitle() {
            val draft = input.text.toString()
            val message = refreshError()
            if (message == null && draft != committed) {
                mutate(obj("type" to "rename_scheme", "scheme_id" to schemeId, "name" to draft))
            }
        }
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                refreshError()
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        input.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                commitTitle()
                input.clearFocus()
                true
            } else {
                false
            }
        }
        input.setOnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                hidePhoneDockForEditing()
            } else {
                showPhoneDockAfterEditing()
                commitTitle()
            }
        }
        refreshError()

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(input, LinearLayout.LayoutParams(-1, dp(34)))
            addView(error, LinearLayout.LayoutParams(-1, dp(13)))
        }
    }

    internal fun renderDaily(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        // iOS daily chrome: a floating back chip, no bar or divider.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, "Back", iconSize = 20) {
                currentFocus?.clearFocus()
                selectedTab = TAB_HOME
                selectedSchemeId = null
                render()
            })
            addView(View(this@MainActivity), LinearLayout.LayoutParams(0, 1, 1f))
        }, LinearLayout.LayoutParams(-1, dp(44)))

        // iOS DailyFeedPane: a bottom-pinned feed of day sections — each one a
        // scheme editor with the date as its inline title — loading more
        // history as you scroll up.
        val list = MaxWidthLinearLayout(this, dp(760)).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(2), dp(10), dp(14))
            setBackgroundColor(theme.bgApp)
        }
        val days = dailyEntries()
        val selectedKey = selectedDate.toString()
        val todayKey = LocalDate.now().toString()
        val yesterdayKey = LocalDate.now().minusDays(1).toString()
        // Desktop/iOS feed rules: every day renders with its title, but empty
        // days only earn a section when they're today, yesterday, or selected.
        val dayViews = LinkedHashMap<String, View>()
        if (days.isEmpty()) {
            list.addView(emptyState("Daily not ready", "Could not create the daily queue."))
        } else {
            days.forEach { day ->
                val date = day.optString("date")
                val keepWhenEmpty = date == selectedKey || date == todayKey || date == yesterdayKey
                if (!keepWhenEmpty && isDailyEntryEmpty(day)) return@forEach
                val view = dailyDayEditor(day)
                dayViews[date] = view
                list.addView(view, LinearLayout.LayoutParams(-1, -2).apply {
                    setMargins(0, 0, 0, dp(6))
                })
            }
        }
        val scrollView = scroll(list)
        var lastObservedScrollY = -1
        scrollView.viewTreeObserver.addOnScrollChangedListener {
            val y = scrollView.scrollY
            // Crossing into the top band while scrolling up loads an older page
            // (a real upward scroll, so short content can't auto-chain loads).
            if (lastObservedScrollY > dp(48) && y <= dp(48) && y < lastObservedScrollY) {
                dayViews.keys.firstOrNull()?.let { loadOlderDailyEntries(it) }
            }
            lastObservedScrollY = y
            dailyScrollY = y
        }
        val resetScroll = dailyScrollDate != selectedKey
        dailyScrollDate = selectedKey
        scrollView.post {
            val anchorDate = pendingDailyAnchorDate
            pendingDailyAnchorDate = null
            when {
                // After a history load, keep the previously-oldest day in place
                // instead of yanking back to the selected day.
                anchorDate != null && dayViews[anchorDate] != null ->
                    scrollView.scrollTo(0, max(0, (dayViews[anchorDate]?.top ?: 0) - dp(4)))
                resetScroll -> {
                    val target = dayViews[selectedKey]
                    if (target != null && target.bottom > scrollView.height) {
                        scrollView.scrollTo(0, max(0, target.bottom - scrollView.height + dp(8)))
                    } else if (target == null) {
                        scrollView.fullScroll(View.FOCUS_DOWN)
                    }
                }
                else -> scrollView.scrollTo(0, dailyScrollY)
            }
        }
        root.addView(scrollView, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(editorFormatBar(), LinearLayout.LayoutParams(-1, dp(38)))
        return root
    }

    /// iOS `isEffectivelyEmpty`: a day whose items carry no text, scheduling,
    /// metadata, or media doesn't earn a row in the feed.
    internal fun isDailyEntryEmpty(day: JSONObject): Boolean {
        val items = day.optJSONObject("scheme")?.optJSONArray("items") ?: return true
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val marker = item.optString("marker", "blank")
            val hasStart = item.optionalString("start") != null
            val hasEnd = item.optionalString("end") != null
            val hasRule = item.optionalString("repeat_rule") != null
            val hasBlockContent = item.hasBlockContent()
            if (item.optString("text").trim().isNotEmpty() ||
                (marker != "blank" && marker != "checkbox") ||
                item.optInt("indent") != 0 ||
                hasStart || hasEnd || hasRule || hasBlockContent ||
                !item.isNull("notification_offset_secs") ||
                item.optBoolean("done")
            ) {
                return false
            }
        }
        return true
    }

    /// iOS `DailyDayEditorSection`: each day is a scheme editor with the date
    /// as its inline title, the selected day softly highlighted; tapping an
    /// unselected day selects it.
    internal fun dailyDayEditor(day: JSONObject): View {
        val date = day.optString("date")
        val scheme = day.optJSONObject("scheme") ?: return emptyState(MobileDateFormatting.fullDay(date), "Daily not ready")
        val schemeId = scheme.optString("id")
        val selected = date == selectedDate.toString()
        val empty = isDailyEntryEmpty(day)
        val originalLines = documentLines(scheme)
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(3), 0, dp(5))
            // Every day carries its title, like the desktop feed — the same
            // short label iOS shows ("Thu, Jun 11").
            addView(text(scheme.optString("display_name").ifEmpty { MobileDateFormatting.fullDay(date) }, theme.textPrimary, 26f, true).apply {
                includeFontPadding = false
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(14), 0, dp(14), 0)
            }, LinearLayout.LayoutParams(-1, dp(44)))
            val editor = SchemeEditText(this@MainActivity).apply {
                setText(renderDocument(originalLines))
                placeCursorAtDocumentEnd(this)
                tag = originalLines
                editorSchemeIds[this] = schemeId
                editorTheme = theme
                accentColor = editorChromeColor()
                lineAdornments = editorLineAdornments(scheme, timeFormat24())
                markerTapHandler = { lineIndex -> toggleEditorLineMarker(this, lineIndex) }
                selectionChangedHandler = { formatBarMarkerRefresh?.invoke() }
                tableCellTapHandler = { hit -> beginInlineCellEdit(schemeId, this, hit) }
                gravity = Gravity.TOP or Gravity.START
                setTextColor(theme.textPrimary)
                setHintTextColor(theme.textMuted)
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                setSingleLine(false)
                imeOptions = EditorInfo.IME_ACTION_DONE
                setTextSize(16f)
                setHorizontallyScrolling(false)
                setPadding(dp(14), dp(3), dp(14), dp(5))
                setLineSpacing(0f, 1f)
                minHeight = if (empty) dp(44) else dailyEditorHeight(scheme)
                isVerticalScrollBarEnabled = false
                overScrollMode = View.OVER_SCROLL_NEVER
                background = null
                setOnFocusChangeListener { _, hasFocus ->
                    if (hasFocus) {
                        lastActiveEditor = this
                        hidePhoneDockForEditing()
                    } else {
                        showPhoneDockAfterEditing()
                        if (!suppressEditorBlurCommit) {
                            commitSchemeDocument(schemeId, this, rerender = false)
                        }
                    }
                }
            }
            if (!selected) {
                // Unselected days select on tap (like iOS); editing starts once
                // the day is the active one.
                editor.isFocusable = false
                editor.isFocusableInTouchMode = false
                val select = View.OnClickListener {
                    runCatching { LocalDate.parse(date) }.getOrNull()?.let {
                        selectedDate = it
                        pendingDailyAutoFocusDate = date
                        loadSnapshot()
                        render()
                    }
                }
                setOnClickListener(select)
                editor.setOnClickListener(select)
            } else {
                editor.post {
                    placeCursorAtDocumentEnd(editor)
                    if (pendingDailyAutoFocusDate == date) {
                        pendingDailyAutoFocusDate = null
                        focusEditorForTyping(editor)
                    }
                }
            }
            val editorHost = FrameLayout(this@MainActivity).apply {
                addView(editor, FrameLayout.LayoutParams(-1, -2))
            }
            editorHosts[editor] = editorHost
            addView(editorHost, LinearLayout.LayoutParams(-1, -2))
        }
    }

    internal fun dailyEditorHeight(scheme: JSONObject): Int {
        val items = scheme.optJSONArray("items")
        var visualLines = 1
        var annotations = 0
        if (items != null && items.length() > 0) {
            visualLines = 0
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index)
                val textLength = item?.optString("text")?.length ?: 0
                visualLines += max(1, (max(textLength, 1) + 33) / 34)
                val hasStart = item?.let { !it.isNull("start") && it.optString("start").isNotEmpty() } ?: false
                val hasEnd = item?.let { !it.isNull("end") && it.optString("end").isNotEmpty() } ?: false
                if (hasStart || hasEnd) annotations++
            }
        }
        // Mirror iOS `DailyDayEditorSection.editorHeight`.
        return dp(max(48, visualLines * 24 + annotations * 14 + 16))
    }

    internal fun dailyAccent(): Int = if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)

    internal fun renderSearch(): View {
        val root = page()
        val query = edit("").apply {
            hint = "Search KnotQ"
            setSingleLine(true)
            background = rounded(theme.bgModal, dp(7), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
        }
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // Back and the search field share one row.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            if (!isWideLayout()) {
                addView(FrameLayout(this@MainActivity).apply {
                    background = rounded(theme.buttonBg, dp(7))
                    addView(
                        iconImage(R.drawable.ic_knotq_chevron_left_24, theme.textPrimary, "Back"),
                        FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER)
                    )
                    setOnClickListener { exitSearch() }
                }, LinearLayout.LayoutParams(dp(40), dp(40)).apply { setMargins(0, 0, dp(8), 0) })
            }
            addView(query, LinearLayout.LayoutParams(0, dp(46), 1f))
        }, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(10)) })
        root.addView(results)
        val searchNow = {
            renderSearchResults(results, query.text.toString())
        }
        query.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                searchNow()
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        query.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEARCH || actionId == EditorInfo.IME_ACTION_DONE) {
                searchNow()
                dismissKeyboard()
                true
            } else {
                false
            }
        }
        query.setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) searchNow() }
        searchNow()
        return root
    }

    internal fun renderSearchResults(results: LinearLayout, query: String) {
        results.removeAllViews()
        if (query.isBlank()) {
            results.addView(emptyState("Search KnotQ", "Find anything across all your schemes."))
            return
        }
        try {
            val hits = bridge.requestArray(obj("type" to "search", "query" to query))
            if (hits.length() == 0) {
                results.addView(emptyState("No results", "Nothing matched “$query”."))
                return
            }
            hits.forEachIndexedObject { idx, hit ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    background = rounded(if (idx % 2 == 1) theme.rowAlt else Color.TRANSPARENT, dp(3))
                    addView(View(this@MainActivity).apply { setBackgroundColor(schemeColor(hit.optInt("color_index"))) }, LinearLayout.LayoutParams(dp(2), -1).apply {
                        setMargins(dp(4), dp(8), dp(6), dp(8))
                    })
                    addView(LinearLayout(this@MainActivity).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(0, dp(7), dp(8), dp(7))
                        addView(LinearLayout(this@MainActivity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            addView(text(hit.optString("scheme_name").ifEmpty { hit.optString("target_kind") }, schemeColor(hit.optInt("color_index")), 11f, true), LinearLayout.LayoutParams(0, -2, 1f))
                            addView(text(hit.optString("detail"), theme.textSoft, 10f, true))
                        })
                        addView(text(hit.optString("title"), theme.textPrimary, 14f, false))
                    }, LinearLayout.LayoutParams(0, -2, 1f))
                    hit.optString("scheme_id").takeIf { it.isNotEmpty() }?.let { schemeId ->
                        setOnClickListener { openScheme(schemeId) }
                    }
                }
                results.addView(row, rowParams())
            }
        } catch (error: RuntimeException) {
            showError("Could not save edits", error.message)
        }
    }

    internal fun renderSettings(): LinearLayout {
        if (settingsShowingArchive) return renderArchivePage()
        val root = page()
        root.addView(sectionHeader("Settings"))
        root.addView(syncSettingsCard(), spaced())
        val settings = snapshot.optJSONObject("settings")
        val themeMode = settings?.optString("theme_mode", "system") ?: "system"
        val timeFormat = settings?.optString("time_format", "twelve_hour") ?: "twelve_hour"
        val eventOffset = settings?.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
            ?: DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS
        val assignmentOffset = settings?.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
            ?: DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
        val googleAccountCount = settings?.optInt("google_account_count", 0) ?: 0

        root.addView(settingsSection("Appearance"))
        root.addView(settingsGroup(
            choiceRow("System", selected = themeMode == "system") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "system")) },
            choiceRow("Dark", selected = themeMode == "dark") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "dark")) },
            choiceRow("Light", selected = themeMode == "light") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "light")) }
        ))

        root.addView(settingsSection("Time"))
        root.addView(settingsGroup(
            choiceRow("12-hour", selected = timeFormat == "twelve_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twelve_hour")) },
            choiceRow("24-hour", selected = timeFormat == "twenty_four_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twenty_four_hour")) }
        ))

        root.addView(settingsSection("Notifications"))
        root.addView(settingsGroup(
            settingsLinkRow("Events", notificationLeadTimeLabel(eventOffset, eventDefault = true)) {
                showNotificationDefaultDialog("Event reminders", eventOffset, eventDefaultNotificationOptions) { next ->
                    mutate(obj("type" to "set_notification_defaults", "event_offset_secs" to next, "assignment_offset_secs" to assignmentOffset))
                }
            },
            settingsLinkRow("Assignments", notificationLeadTimeLabel(assignmentOffset, eventDefault = false)) {
                showNotificationDefaultDialog("Assignment reminders", assignmentOffset, assignmentDefaultNotificationOptions) { next ->
                    mutate(obj("type" to "set_notification_defaults", "event_offset_secs" to eventOffset, "assignment_offset_secs" to next))
                }
            }
        ))

        root.addView(settingsSection("Google Calendar"))
        if (googleAccountCount > 0) {
            root.addView(settingsGroup(
                settingsLinkRow(if (googleSyncInProgress) "Syncing…" else "Sync Google Calendars", "$googleAccountCount connected") { syncGoogleCalendars() },
                settingsLinkRow(if (googleAuthInProgress) "Connecting…" else "Connect another account") { startGoogleCalendarImport() }
            ))
            googleCalendarStatus?.takeIf { it.isNotBlank() }?.let { status ->
                root.addView(text(status, theme.textMuted, 12f, false).apply {
                    setPadding(dp(8), dp(5), dp(8), dp(2))
                })
            }
        } else {
            root.addView(settingsGroup(
                settingsLinkRow(if (googleAuthInProgress) "Connecting…" else "Connect Google Calendar") { startGoogleCalendarImport() }
            ))
        }

        root.addView(settingsSection("Archive"))
        val schemes = archivedSchemes()
        root.addView(settingsGroup(
            settingsLinkRow("Archived items", schemes.length().toString()) {
                settingsShowingArchive = true
                render()
            }
        ))
        return root
    }

    internal fun syncSettingsCard(): View {
        val session = syncSession
        // Cancelled (won't renew) but still entitling: amber "Cancelled" badge, like
        // the not-yet-subscribed state, with a re-enable action below.
        val cancelled = session?.supportsSync == true && syncSubscriptionCancelled
        val badge = when {
            session != null && syncOffline -> "Offline"
            cancelled -> "Cancelled"
            session?.supportsSync == true -> "Enabled"
            session != null -> "Upgrade"
            else -> "Available"
        }
        val badgeFg = when {
            session != null && syncOffline -> if (theme.isDark) rgb(0xf8d38d) else rgb(0x9a4b00)
            !cancelled && session?.supportsSync == true -> if (theme.isDark) rgb(0x9af0b6) else rgb(0x176b38)
            cancelled || session != null -> if (theme.isDark) rgb(0xf8d38d) else rgb(0x9a4b00)
            else -> if (theme.isDark) rgb(0x9bc2ff) else rgb(0x235ebe)
        }
        val badgeBg = when {
            session != null && syncOffline -> adjustAlpha(if (theme.isDark) rgb(0xf59e0b) else rgb(0xd97706), if (theme.isDark) 0.16f else 0.10f)
            !cancelled && session?.supportsSync == true -> adjustAlpha(if (theme.isDark) rgb(0x30d158) else rgb(0x1f8f4d), if (theme.isDark) 0.15f else 0.09f)
            cancelled || session != null -> adjustAlpha(if (theme.isDark) rgb(0xf59e0b) else rgb(0xd97706), if (theme.isDark) 0.16f else 0.10f)
            else -> adjustAlpha(if (theme.isDark) rgb(0x3b82f6) else rgb(0x2f67cf), if (theme.isDark) 0.16f else 0.09f)
        }
        val detail = when {
            session != null && syncOffline -> "Sync will retry when your connection is back."
            cancelled -> "Sync stays active until your billing period ends."
            session != null -> session.email
            else -> "Sign in to keep this workspace available across devices."
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
            background = rounded(
                if (theme.isDark) adjustAlpha(rgb(0x3b82f6), 0.086f) else rgb(0xeaf2ff),
                dp(8),
                if (theme.isDark) adjustAlpha(rgb(0x7aa0ff), 0.27f) else adjustAlpha(rgb(0x2f67cf), 0.22f)
            )
            elevation = dp(if (theme.isDark) 5 else 2).toFloat()
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.TOP
                // iOS card header: brand logo beside the title.
                addView(brandMark(34), LinearLayout.LayoutParams(dp(34), dp(34)).apply {
                    setMargins(0, dp(2), dp(9), 0)
                })
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(text("KnotQ Sync", theme.textPrimary, 15f, true), LinearLayout.LayoutParams(-1, dp(18)))
                    addView(text(detail, theme.textSoft, 11f, false).apply {
                        maxLines = 2
                    }, LinearLayout.LayoutParams(-1, dp(30)))
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(text(badge, badgeFg, 11f, true).apply {
                    gravity = Gravity.CENTER
                    setPadding(dp(7), 0, dp(7), 0)
                    background = rounded(badgeBg, dp(11))
                }, LinearLayout.LayoutParams(-2, dp(22)))
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                if (session == null) {
                    addView(syncCardButton("Sign in", primary = true) { showSyncAccountDialog() }, LinearLayout.LayoutParams(0, dp(32), 1f))
                } else {
                    // iOS layout: a primary action on the left (Resync when enabled,
                    // Re-enable/Subscribe otherwise) and account housekeeping behind a
                    // single "Manage" menu so destructive options don't dominate.
                    val leftLabel: String
                    val leftPrimary: Boolean
                    val leftAction: () -> Unit
                    when {
                        cancelled -> {
                            leftLabel = "Re-enable"; leftPrimary = true; leftAction = { reEnableSyncSubscription() }
                        }
                        !session.supportsSync -> {
                            leftLabel = "I've subscribed"; leftPrimary = true; leftAction = { restoreGooglePlayPurchases() }
                        }
                        else -> {
                            leftLabel = if (syncInProgress) "Resyncing..." else "Resync"; leftPrimary = false; leftAction = { syncOnce() }
                        }
                    }
                    addView(syncCardButton(leftLabel, primary = leftPrimary, listener = leftAction),
                        LinearLayout.LayoutParams(0, dp(32), 1f).apply { setMargins(0, 0, dp(8), 0) })
                    addView(syncCardButton("Manage") { showSyncAccountDialog() }, LinearLayout.LayoutParams(-2, dp(32)))
                }
            }, LinearLayout.LayoutParams(-1, dp(32)).apply {
                setMargins(0, dp(8), 0, 0)
            })
        }
    }

    internal fun showNotificationDefaultDialog(
        title: String,
        current: Int,
        options: List<NotificationLeadTimeOption>,
        onSelect: (Int) -> Unit
    ) {
        val labels = options.map { option ->
            if (option.offsetSecs == current) "${option.label} $GLYPH_TICK" else option.label
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(labels) { _, which -> onSelect(options[which].offsetSecs) }
            .show()
    }

    internal fun addNode(parent: LinearLayout, node: JSONObject, depth: Int, spacious: Boolean = false) {
        val kind = node.optString("kind")
        if (kind == "folder") {
            parent.addView(folderRow(node, depth, spacious), if (spacious) LinearLayout.LayoutParams(-1, dp(30)) else rowParams())
            node.optJSONArray("children")?.forEachObject { addNode(parent, it, depth + 1, spacious) }
            return
        }
        val selected = selectedSchemeId == node.optString("id")
        val rowHeight = if (spacious) dp(30) else dp(22)
        val slot = if (spacious) 18 else 16
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 8 else 6) + depth * if (spacious) 10 else 8), 0, dp(7), 0)
            background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(4))
            // Same fixed leading slot as folder rows so squares and folder
            // icons share a center axis.
            addView(FrameLayout(this@MainActivity).apply {
                addView(View(this@MainActivity).apply {
                    background = rounded(schemeColor(node.optInt("color_index")), dp(3))
                }, FrameLayout.LayoutParams(dp(if (spacious) 10 else 9), dp(if (spacious) 10 else 9), Gravity.CENTER))
            }, LinearLayout.LayoutParams(dp(slot), dp(slot)))
            addView(text(node.optString("name"), if (selected) theme.textPrimary else theme.textDim, if (spacious) 13f else 12f, false).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (spacious) 7 else 5), 0, dp(4), 0)
            })
            setOnClickListener { openScheme(node.optString("id")) }
            setOnLongClickListener {
                showSchemeActions(node)
                true
            }
        }
        parent.addView(row, LinearLayout.LayoutParams(-1, rowHeight))
    }

    internal fun folderRow(node: JSONObject, depth: Int, spacious: Boolean = false): View {
        val slot = if (spacious) 18 else 16
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 8 else 6) + depth * if (spacious) 10 else 8), 0, dp(7), 0)
            addView(FrameLayout(this@MainActivity).apply {
                addView(
                    iconImage(R.drawable.ic_knotq_folder_24, theme.textMuted),
                    FrameLayout.LayoutParams(dp(if (spacious) 14 else 13), dp(if (spacious) 14 else 13), Gravity.CENTER)
                )
            }, LinearLayout.LayoutParams(dp(slot), dp(slot)))
            addView(text(node.optString("name"), theme.textPrimary, if (spacious) 13f else 12f, false).apply {
                maxLines = 1
            }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (spacious) 7 else 5), 0, 0, 0)
            })
            setOnLongClickListener {
                showFolderActions(node)
                true
            }
        }
    }

    internal fun itemRow(schemeId: String, item: JSONObject, index: Int, count: Int): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(dp(8 + item.optInt("indent") * 18), dp(7), dp(8), dp(7))
            background = rounded(if (index % 2 == 1) theme.rowAlt else Color.TRANSPARENT, dp(3))
            addView(iconChip(if (item.optBoolean("done")) GLYPH_TICK else markerLabel(item.optString("marker"))) {
                if (item.optString("marker") == "checkbox") {
                    mutate(obj("type" to "toggle_item", "scheme_id" to schemeId, "item_id" to item.optString("id")))
                } else {
                    mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to item.optString("id"), "marker" to "checkbox"))
                }
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                val input = edit(item.optString("text")).apply {
                    background = null
                    minHeight = dp(24)
                    if (item.optBoolean("done")) paintFlags = paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
                    setOnFocusChangeListener { _, hasFocus ->
                        if (!hasFocus && text.toString() != item.optString("text")) {
                            mutate(obj("type" to "update_item_text", "scheme_id" to schemeId, "item_id" to item.optString("id"), "text" to text.toString().trim()))
                        }
                    }
                }
                addView(input, LinearLayout.LayoutParams(-1, -2))
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(smallAction("Marker") { showMarkerDialog(schemeId, item.optString("id")) })
                    addView(smallAction("Out") {
                        mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to max(item.optInt("indent") - 1, 0)))
                    })
                    addView(smallAction("In") {
                        mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to min(item.optInt("indent") + 1, 8)))
                    })
                    addView(smallAction("Date") { showDateKindDialog(schemeId, item.optString("id")) })
                    addView(text(item.optString("kind").replaceFirstChar(Char::titlecase), theme.textMuted, 11f, true))
                })
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(8), 0, 0, 0) })
            setOnLongClickListener {
                showItemActions(schemeId, item, index, count)
                true
            }
        }
    }

    internal fun editorFormatBar(schemeId: String? = null, editor: EditText? = null): View {
        fun targetEditor(): EditText? = editor ?: activeEditor()
        fun targetSchemeId(): String? = schemeId ?: targetEditor()?.let { editorSchemeIds[it] }
        // iOS toolbar order: dismiss | markers (active highlighted) | indent |
        // date | bold/italic/heading | image attach.
        val markerViews = HashMap<String, View>()
        fun refreshActiveMarker() {
            val target = targetEditor()
            val active = target?.let { activeMarkerForEditor(it) }
            markerViews.forEach { (marker, view) ->
                val color = if (marker == active) theme.textPrimary else theme.textDim
                when (view) {
                    is TextView -> view.setTextColor(color)
                    is FrameLayout -> (view.getChildAt(0) as? ImageView)?.setColorFilter(color)
                }
            }
        }
        formatBarMarkerRefresh = ::refreshActiveMarker
        val normalBar = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(theme.bgToolbar)
            // Restore the scroll position from the previous render (before the
            // first draw), and track it from then on.
            var restoredScroll = false
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                if (!restoredScroll && width > 0) {
                    restoredScroll = true
                    scrollTo(formatBarScrollX, 0)
                }
            }
            viewTreeObserver.addOnScrollChangedListener {
                if (restoredScroll) formatBarScrollX = scrollX
            }
            var downX = 0f
            var downY = 0f
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = event.rawX
                        downY = event.rawY
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        val dx = event.rawX - downX
                        val dy = event.rawY - downY
                        if (dy > dp(22) && dy > abs(dx) * 1.25f) {
                            dismissKeyboard()
                        }
                    }
                }
                false
            }
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(7), dp(5), dp(7), dp(5))
                addView(formatIconButton(R.drawable.ic_knotq_keyboard_down_24, "Dismiss keyboard") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) commitSchemeDocument(targetId, target, rerender = true)
                    target?.clearFocus()
                    dismissKeyboard()
                })
                addView(formatDivider())
                addView(formatButton("T") { targetEditor()?.let { setCurrentLineMarker(it, "blank") } }.also { markerViews["blank"] = it })
                addView(formatIconButton(R.drawable.ic_knotq_check_square_24, "Checkbox") { targetEditor()?.let { setCurrentLineMarker(it, "checkbox") } }.also { markerViews["checkbox"] = it })
                addView(formatIconButton(R.drawable.ic_knotq_bullet_24, "Bullet") { targetEditor()?.let { setCurrentLineMarker(it, "bullet") } }.also { markerViews["bullet"] = it })
                addView(formatIconButton(R.drawable.ic_knotq_numbered_24, "Numbered") { targetEditor()?.let { setCurrentLineMarker(it, "numbered") } }.also { markerViews["numbered"] = it })
                addView(formatDivider())
                addView(formatIconButton(R.drawable.ic_knotq_outdent_24, "Outdent") { targetEditor()?.let { shiftCurrentLineIndent(it, -1) } })
                addView(formatIconButton(R.drawable.ic_knotq_indent_24, "Indent") { targetEditor()?.let { shiftCurrentLineIndent(it, 1) } })
                addView(formatDivider())
                addView(formatIconButton(R.drawable.ic_knotq_calendar_24, "Set date") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) openDateForEditorLine(targetId, target)
                })
                addView(formatDivider())
                addView(formatButton("B") { targetEditor()?.let { toggleWrappedMarkdown(it, "**") } })
                addView(formatButton("I") { targetEditor()?.let { toggleWrappedMarkdown(it, "_") } })
                addView(formatButton("H") { targetEditor()?.let { toggleHeading(it) } })
                addView(formatDivider())
                addView(formatIconButton(R.drawable.ic_knotq_image_24, "Attach image") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) startImageAttach(targetId, target)
                })
                addView(formatIconButton(R.drawable.ic_knotq_table_24, "Insert table") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) insertTableFromEditor(targetId, target)
                })
            })
            refreshActiveMarker()
        }
        // The bar hosts either the normal format controls or, while a table cell
        // is being edited, the cell controls swapped in their place (matching
        // iOS, where the cell toolbar replaces the keyboard accessory rather than
        // floating a second bar).
        return FrameLayout(this).apply {
            setBackgroundColor(theme.bgToolbar)
            addView(normalBar, FrameLayout.LayoutParams(-1, -1))
            formatBarHost = this
            formatBarNormalContent = normalBar
            formatBarCellContent = null
            activeCellEdit?.let { showCellEditFormatBar(it.hit) }
        }
    }

    /// Swaps the bottom format bar to the table-cell controls (dismiss / Rows /
    /// Columns), hiding the normal format controls — the iOS cell-toolbar model.
    internal fun showCellEditFormatBar(hit: TableCellHit) {
        val host = formatBarHost ?: return
        formatBarCellContent?.let { host.removeView(it) }
        val bar = cellEditFormatBar(hit)
        host.addView(bar, FrameLayout.LayoutParams(-1, -1))
        formatBarCellContent = bar
        formatBarNormalContent?.visibility = View.GONE
    }

    internal fun hideCellEditFormatBar() {
        val host = formatBarHost ?: return
        formatBarCellContent?.let { host.removeView(it) }
        formatBarCellContent = null
        formatBarNormalContent?.visibility = View.VISIBLE
    }

    internal fun cellEditFormatBar(hit: TableCellHit): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(theme.bgToolbar)
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(7), dp(5), dp(7), dp(5))
                addView(formatIconButton(R.drawable.ic_knotq_keyboard_down_24, "Done editing cell") {
                    commitActiveCellEdit(rerender = true)
                    dismissKeyboard()
                })
                addView(formatDivider())
                addView(cellBarButton("Rows", enabled = !hit.isHeader) { showTableStructureDialog(rowActions = true) })
                addView(cellBarButton("Columns", enabled = true) { showTableStructureDialog(rowActions = false) })
            })
        }

    internal fun cellBarButton(label: String, enabled: Boolean, action: () -> Unit): TextView =
        text(label, if (enabled) theme.textPrimary else theme.textMuted, ICON_FORMAT_SIZE_SP, true).apply {
            gravity = Gravity.CENTER
            isEnabled = enabled
            alpha = if (enabled) 1f else 0.45f
            background = rounded(if (enabled) theme.buttonBg else Color.TRANSPARENT, dp(5))
            isFocusable = false
            isFocusableInTouchMode = false
            setOnClickListener { if (enabled) action() }
            setPadding(dp(12), 0, dp(12), 0)
            layoutParams = LinearLayout.LayoutParams(-2, dp(ICON_FORMAT_HEIGHT_DP)).apply {
                setMargins(0, 0, dp(5), 0)
            }
        }

    internal fun activeMarkerForEditor(editor: EditText): String {
        val value = editor.text?.toString().orEmpty()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        val start = value.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newline = value.indexOf('\n', cursor)
        val end = if (newline < 0) value.length else newline
        if (start > end) return "blank"
        return parseEditorLine(value.substring(start, end)).marker
    }

    internal fun activeEditor(): EditText? {
        val focused = currentFocus as? EditText
        if (focused != null && editorSchemeIds.containsKey(focused)) return focused
        return lastActiveEditor?.takeIf { editorSchemeIds.containsKey(it) && it.isAttachedToWindow }
    }

    internal fun focusEditorForTyping(editor: EditText) {
        if (!editor.isAttachedToWindow) return
        editor.isFocusable = true
        editor.isFocusableInTouchMode = true
        editor.requestFocus()
        lastActiveEditor = editor
        keyboardActive = true
        updateChromeVisibility()
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
    }

    internal fun formatButton(label: String, action: () -> Unit): TextView =
        text(label, theme.textPrimary, ICON_FORMAT_SIZE_SP, true).apply {
            gravity = Gravity.CENTER
            background = rounded(theme.buttonBg, dp(5))
            isFocusable = false
            isFocusableInTouchMode = false
            setOnClickListener { action() }
            layoutParams = LinearLayout.LayoutParams(dp(ICON_FORMAT_WIDTH_DP), dp(ICON_FORMAT_HEIGHT_DP)).apply {
                setMargins(0, 0, dp(5), 0)
            }
        }

    internal fun formatIconButton(iconRes: Int, description: String, action: () -> Unit): View =
        FrameLayout(this).apply {
            contentDescription = description
            background = rounded(theme.buttonBg, dp(5))
            addView(
                iconImage(iconRes, theme.textPrimary, description),
                FrameLayout.LayoutParams(dp(17), dp(17), Gravity.CENTER)
            )
            isFocusable = false
            isFocusableInTouchMode = false
            setOnClickListener { action() }
            layoutParams = LinearLayout.LayoutParams(dp(ICON_FORMAT_WIDTH_DP), dp(ICON_FORMAT_HEIGHT_DP)).apply {
                setMargins(0, 0, dp(5), 0)
            }
        }

    internal fun formatDivider(): View = View(this).apply {
        setBackgroundColor(theme.dividerSoft)
        layoutParams = LinearLayout.LayoutParams(dp(1), dp(18)).apply {
            setMargins(dp(1), 0, dp(6), 0)
        }
    }

    internal fun setCurrentLineMarker(editor: EditText, marker: String) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            val nextDone = marker == "checkbox" && line.marker == "checkbox" && !line.done
            renderEditorLine(line.copy(marker = marker, done = nextDone), 1)
        }
    }

    internal fun toggleEditorLineMarker(editor: EditText, lineIndex: Int) {
        // iOS: only checkbox markers respond to taps (toggling done); other
        // markers never get converted by a tap.
        editLine(editor, lineIndex) { raw ->
            val line = parseEditorLine(raw)
            if (line.marker == "checkbox") {
                renderEditorLine(line.copy(done = !line.done), 1)
            } else {
                raw
            }
        }
    }

    internal fun toggleWrappedMarkdown(editor: EditText, delimiter: String) {
        val editable = editor.editableText ?: return
        val value = editable.toString()
        val selStart = editor.selectionStart.coerceIn(0, value.length)
        val selEnd = editor.selectionEnd.coerceIn(0, value.length)
        val (start, end) = if (selStart == selEnd) {
            val lineStart = value.lastIndexOf('\n', (selStart - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
            val nl = value.indexOf('\n', selStart)
            val lineEnd = if (nl < 0) value.length else nl
            val prefixLen = chromePrefixLength(value.substring(lineStart, lineEnd))
            Pair((lineStart + prefixLen).coerceAtMost(lineEnd), lineEnd)
        } else {
            Pair(min(selStart, selEnd), max(selStart, selEnd))
        }
        if (end < start) return
        val selected = value.substring(start, end)
        val dlen = delimiter.length
        val replacement = if (selected.length >= dlen * 2 && selected.startsWith(delimiter) && selected.endsWith(delimiter)) {
            selected.substring(dlen, selected.length - dlen)
        } else {
            "$delimiter$selected$delimiter"
        }
        editable.replace(start, end, replacement)
        val cursor = if (selStart == selEnd) {
            (start + replacement.length - if (replacement == "$delimiter$delimiter") dlen else 0)
        } else {
            start + replacement.length
        }
        editor.setSelection(cursor.coerceIn(0, editor.text.length))
    }

    internal fun toggleHeading(editor: EditText) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            val body = line.text
            val trimmed = body.trimStart()
            val leading = body.length - trimmed.length
            val newBody = if (trimmed.startsWith("#")) {
                val hashes = trimmed.takeWhile { it == '#' }.length
                val afterHashes = trimmed.drop(hashes)
                if (afterHashes.isEmpty() || afterHashes.first().isWhitespace()) {
                    body.substring(0, leading) + afterHashes.dropWhile { it == ' ' || it == '\t' }
                } else {
                    "# $body"
                }
            } else {
                "# $body"
            }
            renderEditorLine(line.copy(text = newBody), 1)
        }
    }

    internal fun shiftCurrentLineIndent(editor: EditText, delta: Int) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            renderEditorLine(line.copy(indent = (line.indent + delta).coerceIn(0, 8)), 1)
        }
    }

    internal fun insertTaskLine(editor: EditText) {
        val start = editor.logicalSelectionStart()
        val end = max(start, editor.selectionEnd)
        val prefix = if (start == 0 || editor.text.isEmpty()) "" else "\n"
        editor.text.replace(start, end, "${prefix}[ ] ")
        ensureTerminalNewline(editor.text, editor.selectionStart)
    }

    internal fun editCurrentLine(editor: EditText, transform: (String) -> String) {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        val start = value.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newline = value.indexOf('\n', cursor)
        val end = if (newline < 0) value.length else newline
        val replacement = transform(value.substring(start, end))
        editor.text.replace(start, end, replacement)
        editor.setSelection((start + replacement.length).coerceAtMost(editor.text.length))
    }

    internal fun editLine(editor: EditText, lineIndex: Int, transform: (String) -> String) {
        val value = editor.text.toString()
        var start = 0
        var current = 0
        while (current < lineIndex && start < value.length) {
            val next = value.indexOf('\n', start)
            if (next < 0) return
            start = next + 1
            current++
        }
        val end = value.indexOf('\n', start).let { if (it < 0) value.length else it }
        val replacement = transform(value.substring(start, end))
        editor.text.replace(start, end, replacement)
        editor.setSelection((start + replacement.length).coerceAtMost(editor.text.length))
    }

    internal fun openDateForEditorLine(schemeId: String, editor: EditText) {
        commitSchemeDocument(schemeId, editor, rerender = false)
        val line = currentLineIndex(editor)
        val item = findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(line) ?: return
        showDateKindDialog(schemeId, item.optString("id"))
    }

    internal fun insertTableFromEditor(schemeId: String, editor: EditText) {
        val line = currentLineIndex(editor)
        commitSchemeDocument(schemeId, editor, rerender = false)
        val scheme = findScheme(schemeId) ?: return
        val items = scheme.optJSONArray("items") ?: JSONArray()
        val tableItemId = UUID.randomUUID().toString()
        val table = freshTableJson()
        val content = JSONArray().put(obj("kind" to "table", "table" to table))
        val array = JSONArray()
        var inserted = false
        var insertedIndex = items.length()
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            if (index == line) {
                if (canReplaceLineWithBlock(item)) {
                    array.put(blockItemEdit(tableItemId, item.optInt("indent", 0), JSONArray(), content))
                    insertedIndex = index
                } else {
                    array.put(itemEditObject(item))
                    array.put(blockItemEdit(tableItemId, item.optInt("indent", 0), JSONArray(), content))
                    insertedIndex = index + 1
                }
                inserted = true
                continue
            }
            array.put(itemEditObject(item))
        }
        if (!inserted) {
            array.put(blockItemEdit(tableItemId, 0, JSONArray(), content))
        }
        try {
            bridge.request(obj("type" to "replace_scheme_items", "scheme_id" to schemeId, "items" to array))
            loadSnapshot()
            renderAfterEditorMutation()
            focusInsertedTableCell(schemeId, tableItemId, insertedIndex)
            requestSyncSoon()
        } catch (error: RuntimeException) {
            toast(error.message)
        }
    }

    internal fun freshTableJson(rows: Int = 2, columns: Int = 2): JSONObject {
        val columnCount = max(1, columns)
        val rowCount = max(1, rows)
        val columnDefs = JSONArray()
        repeat(columnCount) { index ->
            columnDefs.put(obj("id" to UUID.randomUUID().toString(), "name" to "Column ${index + 1}"))
        }
        val rowDefs = JSONArray()
        repeat(rowCount) {
            val cells = JSONArray()
            repeat(columnCount) { cells.put(freshTableCellJson()) }
            rowDefs.put(obj("id" to UUID.randomUUID().toString(), "cells" to cells))
        }
        return obj("columns" to columnDefs, "rows" to rowDefs)
    }

    internal fun freshTableCellJson(): JSONObject =
        obj(
            "text" to "",
            "lines" to JSONArray().put(obj(
                "id" to UUID.randomUUID().toString(),
                "text" to "",
                "marker" to "blank",
                "done" to false,
                "start" to null,
                "end" to null,
                "media" to JSONArray()
            ))
        )

    internal fun focusInsertedTableCell(schemeId: String, itemId: String, lineIndexHint: Int) {
        val editor = editorForScheme(schemeId) ?: return
        val items = findScheme(schemeId)?.optJSONArray("items")
        var lineIndex = lineIndexHint
        if (items != null) {
            for (index in 0 until items.length()) {
                if (items.optJSONObject(index)?.optString("id") == itemId) {
                    lineIndex = index
                    break
                }
            }
        }
        editor.post {
            editor.invalidate()
            editor.post {
                val rect = editor.cellRectFor(lineIndex, 0, 0, 0) ?: return@post
                beginInlineCellEdit(
                    schemeId,
                    editor,
                    TableCellHit(
                        lineIndex = lineIndex,
                        tableIndex = 0,
                        row = 0,
                        column = 0,
                        rect = rect,
                        text = ""
                    )
                )
            }
        }
    }

    /// Commits the document so the caret's line has a real item, then opens the
    /// system photo chooser; the pick lands in `onActivityResult`.
    internal fun startImageAttach(schemeId: String, editor: EditText) {
        commitSchemeDocument(schemeId, editor, rerender = false)
        val line = currentLineIndex(editor)
        findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(line) ?: return
        pendingImageAttach = schemeId to line
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        try {
            startActivityForResult(Intent.createChooser(intent, "Attach image"), REQUEST_ATTACH_IMAGE)
        } catch (error: ActivityNotFoundException) {
            pendingImageAttach = null
            toast("No image picker available")
        }
    }

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

    internal fun completeImageAttach(uri: Uri) {
        val (schemeId, lineIndex) = pendingImageAttach ?: return
        pendingImageAttach = null
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: run {
                toast("Could not read image")
                return
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                toast("Unsupported image")
                return
            }
            val mime = contentResolver.getType(uri).orEmpty()
            var payload = bytes
            var format: String
            var extension: String
            when {
                mime.contains("png") -> { format = "png"; extension = "png" }
                mime.contains("jpeg") || mime.contains("jpg") -> { format = "jpeg"; extension = "jpg" }
                mime.contains("gif") -> { format = "gif"; extension = "gif" }
                mime.contains("webp") -> { format = "webp"; extension = "webp" }
                else -> {
                    // Unknown source format: re-encode as JPEG like iOS does.
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: run {
                        toast("Unsupported image")
                        return
                    }
                    val out = java.io.ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
                    payload = out.toByteArray()
                    format = "jpeg"
                    extension = "jpg"
                }
            }
            // Must live inside the core's workspace assets dir or the media
            // entry is rejected on commit.
            val assetsDir = File(File(filesDir, "KnotQMobile"), "workspace/assets/images")
            if (!assetsDir.exists() && !assetsDir.mkdirs()) {
                toast("Could not store image")
                return
            }
            val file = File(assetsDir, "${UUID.randomUUID()}.$extension")
            file.writeBytes(payload)

            val scheme = findScheme(schemeId) ?: return
            val items = scheme.optJSONArray("items") ?: return
            val mediaJson = obj(
                "kind" to "image",
                "path" to file.absolutePath,
                "format" to format,
                "width" to bounds.outWidth,
                "height" to bounds.outHeight
            )
            val media = JSONArray().put(mediaJson)
            val content = JSONArray().put(obj("kind" to "image", "media" to mediaJson))
            val array = JSONArray()
            var inserted = false
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                if (index == lineIndex) {
                    if (canReplaceLineWithBlock(item)) {
                        array.put(blockItemEdit(item.optString("id"), item.optInt("indent"), media, content))
                    } else {
                        array.put(itemEditObject(item))
                        array.put(blockItemEdit(null, item.optInt("indent"), media, content))
                    }
                    inserted = true
                    continue
                }
                array.put(itemEditObject(item))
            }
            if (!inserted) {
                array.put(blockItemEdit(null, 0, media, content))
            }
            bridge.request(obj("type" to "replace_scheme_items", "scheme_id" to schemeId, "items" to array))
            loadSnapshot()
            renderAfterEditorMutation()
            requestSyncSoon()
        } catch (error: RuntimeException) {
            toast(error.message)
        } catch (error: java.io.IOException) {
            toast(error.message)
        }
    }

    internal fun canReplaceLineWithBlock(item: JSONObject): Boolean =
        item.optString("text").isEmpty() &&
            item.optString("marker", "blank") == "blank" &&
            item.optInt("indent", 0) >= 0 &&
            !item.optBoolean("done", false) &&
            item.optionalString("start") == null &&
            item.optionalString("end") == null &&
            item.optionalString("repeat_rule") == null &&
            item.isNull("notification_offset_secs") &&
            !item.hasBlockContent()

    internal fun blockItemEdit(itemId: String?, indent: Int, media: JSONArray, content: JSONArray): JSONObject =
        obj(
            "id" to itemId,
            "text" to "",
            "marker" to "blank",
            "indent" to indent.coerceIn(0, 8),
            "done" to false,
            "start" to null,
            "end" to null,
            "notification_offset_secs" to null,
            "repeat_rule" to null,
            "media" to media,
            "content" to content
        )

    internal fun itemEditObject(item: JSONObject, line: SchemeEditorLine? = null): JSONObject {
        // The object char is the block marker: a line keeps its image/table only
        // while it is still a block line. Deleting the char (or typing alongside
        // it) demotes the item to plain text, matching desktop/iOS.
        val isBlockLine = if (line != null) line.hasBlock else item.optString("text").isEmpty() && item.hasBlockContent()
        val textValue = if (isBlockLine) "" else (line?.text ?: item.optString("text"))
        val wasBlock = item.hasBlockContent()
        val blockContent: JSONArray? = when {
            isBlockLine -> item.blockContentForEdit()
            // Demoting a block line to text: the core's `replace_scheme_items`
            // preserves an existing block whenever the draft's content AND media
            // are both empty (so a normal save that omits block content doesn't
            // clobber it). To actually drop the block when its object char is
            // gone, send an explicit text inline so the incoming content wins.
            wasBlock -> JSONArray().put(obj("kind" to "text", "text" to textValue))
            else -> null
        }
        val media = when {
            blockContent != null -> blockContent.mediaFromInlineContent()
            line != null -> JSONArray()
            else -> item.optJSONArray("media") ?: JSONArray()
        }
        return obj(
            "id" to (line?.id ?: item.optString("id")),
            "text" to textValue,
            "marker" to (line?.marker ?: item.optString("marker", "blank")),
            "indent" to (line?.indent ?: item.optInt("indent")),
            "done" to (line?.done ?: item.optBoolean("done")),
            "start" to item.optionalString("start"),
            "end" to item.optionalString("end"),
            "notification_offset_secs" to item.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs"),
            "repeat_rule" to item.optionalString("repeat_rule"),
            "media" to media,
            "content" to blockContent
        )
    }

    internal fun JSONObject.hasBlockContent(): Boolean =
        (optJSONArray("media")?.length() ?: 0) > 0 ||
            (optJSONArray("tables")?.length() ?: 0) > 0 ||
            optJSONArray("content")?.containsBlockInline() == true

    internal fun JSONObject.blockContentForEdit(): JSONArray? {
        val content = optJSONArray("content")
        if (content != null && content.containsBlockInline()) return content
        val out = JSONArray()
        optJSONArray("media")?.forEachObject { out.put(obj("kind" to "image", "media" to it)) }
        optJSONArray("tables")?.forEachObject { out.put(obj("kind" to "table", "table" to it)) }
        return if (out.length() > 0) out else null
    }

    internal fun JSONArray.containsBlockInline(): Boolean {
        for (index in 0 until length()) {
            val kind = optJSONObject(index)?.optString("kind")
            if (kind == "image" || kind == "table") return true
        }
        return false
    }

    internal fun JSONArray.mediaFromInlineContent(): JSONArray {
        val out = JSONArray()
        for (index in 0 until length()) {
            val inline = optJSONObject(index) ?: continue
            if (inline.optString("kind") == "image") {
                inline.optJSONObject("media")?.let { out.put(it) }
            }
        }
        return out
    }

    internal fun currentLineIndex(editor: EditText): Int {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        return value.substring(0, cursor).count { it == '\n' }
    }

    internal fun EditText.logicalSelectionStart(): Int {
        val value = text?.toString().orEmpty()
        val raw = max(0, selectionStart).coerceAtMost(value.length)
        return if (raw == value.length && value.endsWith("\n")) max(0, raw - 1) else raw
    }

    internal fun ensureTerminalNewline(editable: Editable, preferredSelection: Int? = null) {
        if (editable.isNotEmpty() && editable.last() == '\n') return
        val selection = (preferredSelection ?: editable.length).coerceIn(0, editable.length)
        editable.append("\n")
        activeEditor()?.setSelection(selection.coerceAtMost(editable.length))
    }

    internal fun placeCursorAtDocumentEnd(editor: EditText) {
        val value = editor.text?.toString().orEmpty()
        val location = if (value.endsWith("\n")) max(0, value.length - 1) else value.length
        editor.setSelection(location.coerceIn(0, editor.text?.length ?: 0))
    }

    internal fun commitSchemeDocument(schemeId: String, editor: EditText, rerender: Boolean) {
        ensureTerminalNewline(editor.text, editor.selectionStart)
        val oldLines = (editor.tag as? List<*>)?.filterIsInstance<SchemeEditorLine>().orEmpty()
        val nextLines = reconcileEditorLines(oldLines, parseEditorDocument(editor.text.toString(), preserveBlankDocument = oldLines.isNotEmpty()))
        val array = JSONArray()
        nextLines.forEach { line ->
            val existing = line.id?.let { findItem(schemeId, it) }
            if (existing != null) {
                array.put(itemEditObject(existing, line))
            } else {
                array.put(obj(
                    "id" to line.id,
                    "text" to line.text,
                    "marker" to line.marker,
                    "indent" to line.indent,
                    "done" to line.done,
                    "start" to null,
                    "end" to null,
                    "notification_offset_secs" to null,
                    "repeat_rule" to null,
                    "media" to JSONArray(),
                    "content" to JSONArray()
                ))
            }
        }
        try {
            bridge.request(obj("type" to "replace_scheme_items", "scheme_id" to schemeId, "items" to array))
            loadSnapshot()
            rescheduleNotifications()
            val refreshed = findScheme(schemeId)
            editor.tag = refreshed?.let(::documentLines) ?: nextLines
            if (editor is SchemeEditText && refreshed != null) {
                editor.lineAdornments = editorLineAdornments(refreshed, timeFormat24())
            }
            if (rerender) render()
            requestSyncSoon()
        } catch (error: RuntimeException) {
            toast(error.message)
        }
    }

    // ---- Inline table cell editing -------------------------------------------------

    /// Resolves the item that owns a logical editor line (each line is one item).
    internal fun itemIdForLine(schemeId: String, lineIndex: Int): String? =
        findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(lineIndex)?.optString("id")?.takeIf { it.isNotEmpty() }

    /// Returns the live cell texts (one entry per line) for diffing on commit.
    internal fun cellLines(schemeId: String, itemId: String, tableIndex: Int, row: Int, column: Int): List<String> {
        val item = findItem(schemeId, itemId) ?: return emptyList()
        // Prefer the ordered `content` tables; fall back to the flat `tables`.
        val table = tableFromItem(item, tableIndex) ?: return emptyList()
        val cell = table.optJSONArray("rows")?.optJSONObject(row)?.optJSONArray("cells")?.optJSONObject(column)
            ?: return emptyList()
        val lines = ArrayList<String>()
        cell.optJSONArray("lines")?.forEachObject { lines.add(it.optString("text")) }
        if (lines.isEmpty()) cell.optString("text").takeIf { it.isNotEmpty() }?.let { lines.add(it) }
        return lines
    }

    internal fun tableFromItem(item: JSONObject, tableIndex: Int): JSONObject? {
        val content = item.optJSONArray("content")
        if (content != null && content.length() > 0) {
            var seen = 0
            for (index in 0 until content.length()) {
                val inline = content.optJSONObject(index) ?: continue
                if (inline.optString("kind") == "table") {
                    if (seen == tableIndex) return inline.optJSONObject("table")
                    seen++
                }
            }
        }
        return item.optJSONArray("tables")?.optJSONObject(tableIndex)
    }

    /// Floats a real text field over the tapped cell so it is edited in place.
    /// Commits the per-line diff through the core's cell-line APIs.
    internal fun beginInlineCellEdit(schemeId: String, editor: SchemeEditText, hit: TableCellHit) {
        // Commit any field already open before opening a new one. Commit in place
        // (no full re-render) so this same editor survives to host the new field.
        commitActiveCellEdit(rerender = false)
        val host = editorHosts[editor] ?: return
        val itemId = itemIdForLine(schemeId, hit.lineIndex) ?: return
        val existingLines = if (hit.isHeader) listOf(hit.text) else cellLines(schemeId, itemId, hit.tableIndex, hit.row, hit.column)
        val rect = tableOverlayRect(host, editor, hit.rect)
        val field = EditText(this).apply {
            setText(existingLines.joinToString("\n").ifEmpty { hit.text })
            setTextColor(theme.textPrimary)
            setHintTextColor(theme.textMuted)
            background = rounded(theme.bgModal, dp(4), theme.accent, dp(2))
            setPadding(dp(6), dp(4), dp(6), dp(4))
            setTextSize(13f)
            gravity = Gravity.TOP or Gravity.START
            elevation = dp(8).toFloat()
            // Multi-line: Enter adds a cell line; Tab moves to the next cell.
            inputType = if (hit.isHeader) {
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            } else {
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            }
            setSingleLine(hit.isHeader)
            imeOptions = if (hit.isHeader) EditorInfo.IME_ACTION_DONE else EditorInfo.IME_ACTION_NEXT
            setHorizontallyScrolling(false)
        }
        val state = ActiveCellEdit(editor, field, schemeId, itemId, hit, existingLines)
        editor.activeTableCellEdit = hit
        // Tab moves to the next/previous cell; Shift+Tab goes back.
        field.setOnKeyListener { _, keyCode, event ->
            if (keyCode == KeyEvent.KEYCODE_TAB && event.action == KeyEvent.ACTION_DOWN) {
                moveInlineCellEdit(editor, forward = !event.isShiftPressed)
                true
            } else {
                false
            }
        }
        // The IME "Next" action moves down to the cell below (or commits if last).
        field.setOnEditorActionListener { _, actionId, _ ->
            when (actionId) {
                EditorInfo.IME_ACTION_NEXT -> {
                    moveInlineCellEditVertical(editor)
                    true
                }
                EditorInfo.IME_ACTION_DONE -> {
                    commitActiveCellEdit(rerender = true)
                    dismissKeyboard()
                    true
                }
                else -> false
            }
        }
        field.setOnFocusChangeListener { _, hasFocus ->
            if (!hasFocus && activeCellEdit?.field === field && !tableStructureDialogOpen) dismissInlineCellEditor()
        }
        // The cell rect already encodes the editor's own scroll (it is drawn
        // with `- scrollY`); the editor is full-height inside the page scroller,
        // so its internal scrollY is ~0 and the rect maps directly to the host.
        val lp = FrameLayout.LayoutParams(
            max(dp(56), rect.width().roundToInt()),
            max(dp(32), rect.height().roundToInt())
        ).apply {
            leftMargin = rect.left.roundToInt()
            topMargin = rect.top.roundToInt()
        }
        host.addView(field, lp)
        activeCellEdit = state
        // Swap the bottom format bar to the cell controls (iOS replaces the
        // keyboard accessory rather than floating a second toolbar).
        showCellEditFormatBar(hit)
        field.requestFocus()
        field.setSelection(field.text.length)
        (getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
        keyboardActive = true
    }

    internal fun tableOverlayRect(host: FrameLayout, editor: SchemeEditText, rect: RectF): RectF {
        val out = RectF(rect)
        out.offset(editor.left.toFloat(), editor.top.toFloat())
        if (host.width > 0) {
            val overflow = out.right - host.width
            if (overflow > 0) out.offset(-overflow, 0f)
            if (out.left < 0f) out.offset(-out.left, 0f)
        }
        if (host.height > 0 && out.top < 0f) out.offset(0f, -out.top)
        return out
    }

    internal fun showTableStructureDialog(rowActions: Boolean) {
        val state = activeCellEdit ?: return
        if (rowActions && state.hit.isHeader) return
        tableStructureDialogOpen = true
        val entries = if (rowActions) {
            listOf(
                "Insert Row Above" to TableStructureAction.INSERT_ROW_ABOVE,
                "Insert Row Below" to TableStructureAction.INSERT_ROW_BELOW,
                "Delete Row" to TableStructureAction.DELETE_ROW
            )
        } else {
            listOf(
                "Insert Column Left" to TableStructureAction.INSERT_COLUMN_LEFT,
                "Insert Column Right" to TableStructureAction.INSERT_COLUMN_RIGHT,
                "Delete Column" to TableStructureAction.DELETE_COLUMN
            )
        }
        AlertDialog.Builder(this)
            .setTitle(if (rowActions) "Rows" else "Columns")
            .setItems(entries.map { it.first }.toTypedArray()) { _, which ->
                performTableStructureAction(entries[which].second)
            }
            .setOnDismissListener {
                tableStructureDialogOpen = false
                activeCellEdit?.field?.requestFocus()
            }
            .show()
    }

    internal fun performTableStructureAction(action: TableStructureAction) {
        val state = activeCellEdit ?: return
        val editor = editorForScheme(state.schemeId)
        val target = tableStructureFocusTarget(state.hit, action)
        commitActiveCellEdit(rerender = false)
        try {
            when (action) {
                TableStructureAction.INSERT_ROW_ABOVE ->
                    bridge.insertTableRow(state.schemeId, state.itemId, state.hit.row.coerceAtLeast(0))
                TableStructureAction.INSERT_ROW_BELOW ->
                    bridge.insertTableRow(state.schemeId, state.itemId, state.hit.row + 1)
                TableStructureAction.DELETE_ROW ->
                    bridge.deleteTableRow(state.schemeId, state.itemId, state.hit.row)
                TableStructureAction.INSERT_COLUMN_LEFT ->
                    bridge.insertTableColumn(state.schemeId, state.itemId, state.hit.column)
                TableStructureAction.INSERT_COLUMN_RIGHT ->
                    bridge.insertTableColumn(state.schemeId, state.itemId, state.hit.column + 1)
                TableStructureAction.DELETE_COLUMN ->
                    bridge.deleteTableColumn(state.schemeId, state.itemId, state.hit.column)
            }
            loadSnapshot()
            requestSyncSoon()
            val refreshed = findScheme(state.schemeId)
            if (editor != null && refreshed != null) {
                editor.lineAdornments = editorLineAdornments(refreshed, timeFormat24())
                editor.invalidate()
                openCellAfterLayout(state.schemeId, editor, state.hit, target.first, target.second)
            } else {
                renderAfterEditorMutation()
            }
        } catch (error: RuntimeException) {
            toast(error.message)
            loadSnapshot()
            renderAfterEditorMutation()
        }
    }

    internal fun tableStructureFocusTarget(hit: TableCellHit, action: TableStructureAction): Pair<Int, Int> =
        when (action) {
            TableStructureAction.INSERT_ROW_ABOVE -> hit.row to hit.column
            TableStructureAction.INSERT_ROW_BELOW -> (hit.row + 1) to hit.column
            TableStructureAction.DELETE_ROW -> hit.row to hit.column
            TableStructureAction.INSERT_COLUMN_LEFT -> hit.row to hit.column
            TableStructureAction.INSERT_COLUMN_RIGHT -> hit.row to (hit.column + 1)
            TableStructureAction.DELETE_COLUMN -> hit.row to hit.column
        }

    /// Commits the current cell, then opens the next/previous cell to its
    /// left/right, wrapping across rows.
    internal fun moveInlineCellEdit(editor: SchemeEditText, forward: Boolean) {
        val state = activeCellEdit ?: return
        val hit = state.hit
        val schemeId = state.schemeId
        commitActiveCellEdit(rerender = false)
        val item = findItem(schemeId, state.itemId) ?: return
        val table = tableFromItem(item, hit.tableIndex) ?: return
        val (rows, columns) = tableDimensions(table)
        if (rows == 0 || columns == 0) return
        var row = hit.row
        var col = hit.column + if (forward) 1 else -1
        if (col >= columns) { col = 0; row++ }
        if (col < 0) { col = columns - 1; row-- }
        if (row < -1 || row >= rows) return
        openCellAfterLayout(schemeId, editor, hit, row, col)
    }

    /// Moves to the cell directly below (used for the IME "Next" action).
    internal fun moveInlineCellEditVertical(editor: SchemeEditText) {
        val state = activeCellEdit ?: return
        val hit = state.hit
        val schemeId = state.schemeId
        commitActiveCellEdit(rerender = false)
        val item = findItem(schemeId, state.itemId) ?: return
        val table = tableFromItem(item, hit.tableIndex) ?: return
        val (rows, _) = tableDimensions(table)
        val row = hit.row + 1
        if (row >= rows) return
        openCellAfterLayout(schemeId, editor, hit, row, hit.column)
    }

    internal fun tableDimensions(table: JSONObject): Pair<Int, Int> {
        val rows = table.optJSONArray("rows")?.length() ?: 0
        val columns = max(
            table.optJSONArray("columns")?.length() ?: 0,
            table.optJSONArray("rows")?.optJSONObject(0)?.optJSONArray("cells")?.length() ?: 0
        )
        return rows to columns
    }

    /// Re-opens the inline editor on a target cell once the editor has redrawn
    /// (its cell rects are recomputed on the next draw pass).
    internal fun openCellAfterLayout(schemeId: String, editor: SchemeEditText, hit: TableCellHit, row: Int, col: Int) {
        editor.post {
            editor.cellRectFor(hit.lineIndex, hit.tableIndex, row, col)?.let { nextRect ->
                beginInlineCellEdit(
                    schemeId,
                    editor,
                    hit.copy(row = row, column = col, rect = nextRect, text = "")
                )
            }
        }
    }

    /// Commits the active inline cell editor (if any), applying the per-line diff
    /// between its starting lines and the edited text. With `rerender` the whole
    /// UI is rebuilt; otherwise only the owning editor's adornments are refreshed.
    internal fun commitActiveCellEdit(rerender: Boolean) {
        val state = activeCellEdit ?: return
        activeCellEdit = null
        state.editor.activeTableCellEdit = null
        (state.field.parent as? ViewGroup)?.removeView(state.field)
        hideCellEditFormatBar()
        val draft = state.field.text.toString()
        if (state.hit.isHeader) {
            if (draft == state.hit.text) {
                if (rerender) { loadSnapshot(); renderAfterEditorMutation() }
                return
            }
            try {
                bridge.setTableColumnName(state.schemeId, state.itemId, state.hit.column, draft)
                loadSnapshot()
                requestSyncSoon()
                if (rerender) {
                    renderAfterEditorMutation()
                } else {
                    val editor = editorForScheme(state.schemeId)
                    findScheme(state.schemeId)?.let { scheme -> editor?.lineAdornments = editorLineAdornments(scheme, timeFormat24()) }
                }
            } catch (error: RuntimeException) {
                toast(error.message)
            }
            return
        }
        val oldLines = state.oldLines
        val newLines = if (draft.isEmpty()) emptyList() else draft.split("\n")
        if (newLines == oldLines) {
            if (rerender) { loadSnapshot(); renderAfterEditorMutation() }
            return
        }
        val schemeId = state.schemeId
        val itemId = state.itemId
        val row = state.hit.row
        val column = state.hit.column
        try {
            // Overwrite existing line slots.
            val shared = min(oldLines.size, newLines.size)
            for (i in 0 until shared) {
                if (oldLines[i] != newLines[i]) {
                    bridge.setTableCellLineText(schemeId, itemId, row, column, i, newLines[i])
                }
            }
            // Append any new lines beyond the old count.
            for (i in shared until newLines.size) {
                bridge.addTableCellLine(schemeId, itemId, row, column, i, newLines[i])
            }
            // Remove trailing lines that were deleted (back to front).
            for (i in oldLines.size - 1 downTo newLines.size) {
                bridge.removeTableCellLine(schemeId, itemId, row, column, i)
            }
            // An entirely emptied cell keeps one blank line so the grid still has
            // a cell to tap.
            if (newLines.isEmpty()) {
                bridge.setTableCellText(schemeId, itemId, row, column, "")
            }
            loadSnapshot()
            requestSyncSoon()
            if (rerender) {
                renderAfterEditorMutation()
            } else {
                // Refresh just the owning editor's table/image adornments in place.
                val editor = editorForScheme(schemeId)
                findScheme(schemeId)?.let { scheme -> editor?.lineAdornments = editorLineAdornments(scheme, timeFormat24()) }
            }
        } catch (error: RuntimeException) {
            toast(error.message)
        }
    }

    internal fun editorForScheme(schemeId: String): SchemeEditText? =
        editorSchemeIds.entries.firstOrNull { it.value == schemeId }?.key as? SchemeEditText

    internal fun dismissInlineCellEditor() {
        commitActiveCellEdit(rerender = true)
    }

    internal fun occurrenceRow(occurrence: JSONObject, striped: Boolean): View {
        val accent = occurrenceSchemeColor(occurrence)
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(if (striped) theme.rowAlt else Color.TRANSPARENT, dp(3))
            alpha = if (occurrence.optBoolean("done")) 0.45f else 1f
            addView(View(this@MainActivity).apply { setBackgroundColor(accent) }, LinearLayout.LayoutParams(dp(2), -1).apply {
                setMargins(dp(4), dp(8), dp(6), dp(8))
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(7), dp(8), dp(7))
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(text(occurrence.optString("scheme_name"), accent, 11f, true), LinearLayout.LayoutParams(0, -2, 1f))
                    addView(text(MobileDateFormatting.occurrenceLabel(occurrence, timeFormat24(), showDay = true), occurrenceStatusTimeColor(occurrence), 10f, true).apply {
                        typeface = Typeface.MONOSPACE
                    })
                })
                addView(text(occurrence.optString("title").ifEmpty { occurrence.optString("kind").replaceFirstChar(Char::titlecase) }, theme.textPrimary, 13f, false).apply {
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                    if (occurrence.optBoolean("done")) {
                        paintFlags = paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
                    }
                })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            // iOS row interactions: tap toggles done, a quick long-press opens
            // the editor.
            setOnClickListener {
                mutate(obj(
                    "type" to "toggle_occurrence",
                    "scheme_id" to occurrence.optString("scheme_id"),
                    "item_id" to occurrence.optString("item_id"),
                    "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}")
                ))
            }
            setOnLongClickListener {
                showEventEditorDialog(occurrence)
                true
            }
        }
    }

    /// iOS `occurrenceSchemeColor`: the Daily queue gets its own steel-blue
    /// accent instead of the scheme palette.
    internal fun occurrenceSchemeColor(occurrence: JSONObject): Int =
        if (occurrence.optString("scheme_name") == "Daily") dailyAccent()
        else schemeColor(occurrence.optInt("color_index"))

    /// iOS `occurrenceStatusTimeColor`: urgency-tinted time labels (red when
    /// overdue, blue when current/today, lavender for tomorrow).
    internal fun occurrenceStatusTimeColor(occurrence: JSONObject): Int {
        if (occurrence.optBoolean("done")) return theme.textMuted
        val anchorRaw = if (occurrence.optString("kind") == "assignment") {
            occurrence.optionalString("end")
        } else {
            occurrence.optionalString("start") ?: occurrence.optionalString("end")
        }
        val anchor = MobileDateFormatting.parseInstant(anchorRaw) ?: return theme.textSoft
        val now = Instant.now()
        val end = MobileDateFormatting.parseInstant(occurrence.optionalString("end"))
        if (occurrence.optString("kind") == "event" && end != null && !anchor.isAfter(now) && end.isAfter(now)) {
            return todayTimeColor()
        }
        if (anchor.isBefore(now)) return if (theme.isDark) rgb(0xff5a53) else rgb(0xd20f39)
        val anchorDay = anchor.atZone(ZoneId.systemDefault()).toLocalDate()
        val dayDiff = java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), anchorDay)
        return when {
            dayDiff <= 0 -> todayTimeColor()
            dayDiff <= 1 -> if (theme.isDark) rgb(0xe5e5ff) else rgb(0x4f5f8f)
            else -> theme.textSoft
        }
    }

    // Matches the iOS home "+" menu: New Scheme, New Folder, Google Calendar.
    internal fun showNewMenu() {
        AlertDialog.Builder(this)
            .setTitle("New")
            .setItems(arrayOf("New Scheme", "New Folder", "Google Calendar")) { _, which ->
                when (which) {
                    0 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
                        mutate(obj("type" to "create_scheme", "name" to name, "position" to 0))
                        snapshot.optJSONArray("schemes")?.let { schemes ->
                            for (index in schemes.length() - 1 downTo 0) {
                                val scheme = schemes.optJSONObject(index) ?: continue
                                if (scheme.optString("display_name") == name || scheme.optString("name") == name) {
                                    openScheme(scheme.optString("id"))
                                    return@showNameDialog
                                }
                            }
                        }
                    }
                    1 -> showNameDialog("New Folder", "", { validateFolderName(it) }) { name -> mutate(obj("type" to "create_folder", "name" to name)) }
                    2 -> startGoogleCalendarImport()
                }
            }
            .show()
    }

    internal fun showItemDialog(schemeId: String, item: JSONObject?) {
        val editing = item != null
        val form = page(compact = true)
        val text = edit(item?.optString("text") ?: "").apply { hint = "Item" }
        val markerValues = arrayOf("checkbox", "blank", "bullet", "numbered")
        val marker = spinner(markerValues)
        if (editing) marker.setSelection(markerValues.indexOf(item?.optString("marker")).coerceAtLeast(0))
        form.addView(text, spaced())
        form.addView(marker, spaced())
        AlertDialog.Builder(this)
            .setTitle(if (editing) "Edit Item" else "New Item")
            .setView(form)
            .setPositiveButton(if (editing) "Save" else "Add") { _, _ ->
                if (item != null) {
                    mutate(obj("type" to "update_item_text", "scheme_id" to schemeId, "item_id" to item.optString("id"), "text" to text.text.toString().trim()))
                    mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to item.optString("id"), "marker" to marker.selectedItem.toString()))
                } else {
                    mutate(obj("type" to "add_item", "scheme_id" to schemeId, "text" to text.text.toString().trim(), "marker" to marker.selectedItem.toString()))
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    internal fun showCalendarItemDialog() {
        showEventEditorDialog(null)
    }

    internal fun showEventEditorDialog(
        occurrence: JSONObject?,
        initialDate: LocalDate? = null,
        initialMinute: Float? = null,
        preferredKind: String? = null,
        openForNew: Boolean = false,
        onDismiss: (() -> Unit)? = null
    ) {
        val editing = occurrence != null
        val readOnly = occurrence?.optBoolean("is_read_only", false) == true
        val initialKind = if (editing) {
            occurrence.optString("kind").takeIf { it.isNotEmpty() } ?: "task"
        } else {
            preferredKind?.takeIf { it.isNotEmpty() } ?: "task"
        }
        val startDateTime = if (editing) MobileDateFormatting.localDateTime(occurrence?.optionalString("start"))?.toLocalDateTime() else null
        val endDateTime = if (editing) MobileDateFormatting.localDateTime(occurrence?.optionalString("end"))?.toLocalDateTime() else null
        val selectedMinute = initialMinute?.toInt()?.coerceIn(0, (24 * 60) - 1)
        val seedDate = initialDate ?: selectedDate
        val seedTime = selectedMinute?.let { LocalTime.of(it / 60, it % 60) }
        val anchor = when {
            openForNew && seedTime != null -> LocalDateTime.of(seedDate, seedTime)
            editing -> startDateTime ?: endDateTime
            else -> startDateTime ?: endDateTime ?: selectedDate.atStartOfDay()
        } ?: selectedDate.atStartOfDay()
        val defaultStart = startDateTime ?: anchor
        val defaultEnd = if (editing) {
            endDateTime ?: if (initialKind == "event") defaultStart.plusHours(1) else defaultStart
        } else {
            when (initialKind) {
                "event" -> defaultStart.plusHours(1)
                "assignment", "reminder" -> defaultStart
                else -> defaultStart
            }
        }
        val initialDialogDate = if (editing) {
            (startDateTime ?: endDateTime)?.toLocalDate() ?: seedDate
        } else {
            seedDate
        }
        val titleInput = edit(occurrence?.optString("title") ?: "").apply {
            hint = "Title"
            isEnabled = !readOnly
        }
        // iOS-style segmented kind selector instead of a raw lowercase spinner.
        val kindValues = arrayOf("event", "reminder", "assignment", "task")
        val kindTitles = arrayOf("Event", "Reminder", "Assignment", "Task")
        var activeKindValue = if (kindValues.contains(initialKind)) initialKind else "task"
        val kindChips = HashMap<String, TextView>()
        val kindRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            kindValues.forEachIndexed { index, value ->
                val chip = text(kindTitles[index], theme.textDim, 12.5f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                }
                kindChips[value] = chip
                addView(chip, LinearLayout.LayoutParams(0, dp(34), 1f).apply {
                    setMargins(if (index == 0) 0 else dp(3), 0, if (index == kindValues.lastIndex) 0 else dp(3), 0)
                })
            }
        }
        fun refreshKindChips() {
            kindValues.forEach { value ->
                kindChips[value]?.apply {
                    val active = value == activeKindValue
                    background = rounded(
                        if (active) theme.rowSelected else theme.buttonBg,
                        dp(8),
                        if (active) theme.accent else Color.TRANSPARENT
                    )
                    setTextColor(if (active) theme.textPrimary else theme.textDim)
                }
            }
        }
        val schemeLabels = mutableListOf("Daily")
        val schemeIds = mutableListOf<String?>(null)
        snapshot.optJSONArray("schemes")?.forEachObject { scheme ->
            if (!scheme.optBoolean("is_daily_queue") && !scheme.optBoolean("is_read_only")) {
                schemeLabels.add(scheme.optString("display_name"))
                schemeIds.add(scheme.optString("id"))
            }
        }
        val scheme = spinner(schemeLabels.toTypedArray()).apply {
            val selected = occurrence?.optString("scheme_id")
            val index = schemeIds.indexOfFirst { it == selected }
            setSelection(index.coerceAtLeast(0))
            isEnabled = !editing && !readOnly
        }
        var selectedLocalDate = initialDialogDate
        var startTime = defaultStart.toLocalTime().takeIf { it != LocalTime.MIDNIGHT } ?: LocalTime.now().withSecond(0).withNano(0)
        var endTime = defaultEnd.toLocalTime()
        val repeatValues = arrayOf("none", "daily", "weekly", "monthly", "yearly")
        val repeatLabels = arrayOf("Never", "Daily", "Weekly", "Monthly", "Yearly")
        val repeat = spinner(repeatLabels).apply {
            setSelection(repeatValues.indexOf(MobileRecurrence.repeatChoiceFromRrule(occurrence?.optionalString("repeat_rule"))).coerceAtLeast(0))
            isEnabled = !readOnly
        }
        // iOS WeeklyRepeatDaysPicker: weekday circles shown for weekly repeats.
        val selectedWeekdays = MobileRecurrence.selectedWeekdays(occurrence?.optionalString("repeat_rule"), initialDialogDate)
        val weekdayChips = ArrayList<Pair<String, TextView>>()
        lateinit var refreshWeekdayChips: () -> Unit
        val weekdayRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            MobileRecurrence.weekdayCodes.forEachIndexed { index, code ->
                val chip = text(MobileRecurrence.weekdayChipLabels[index], theme.textDim, 12f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                    setOnClickListener {
                        if (readOnly) return@setOnClickListener
                        if (selectedWeekdays.contains(code)) {
                            // Never allow an empty weekly selection, like iOS.
                            if (selectedWeekdays.size > 1) selectedWeekdays.remove(code)
                        } else {
                            selectedWeekdays.add(code)
                        }
                        refreshWeekdayChips()
                    }
                }
                weekdayChips.add(code to chip)
                addView(chip, LinearLayout.LayoutParams(dp(34), dp(34)).apply {
                    setMargins(dp(3), 0, dp(3), 0)
                })
            }
        }
        refreshWeekdayChips = {
            weekdayChips.forEach { (code, chip) ->
                val active = selectedWeekdays.contains(code)
                chip.background = rounded(
                    if (active) theme.accent else Color.TRANSPARENT,
                    dp(17),
                    if (active) Color.TRANSPARENT else theme.borderOverlay
                )
                chip.setTextColor(
                    if (active) {
                        if (theme.isDark) rgb(0x10131a) else Color.WHITE
                    } else {
                        theme.textDim
                    }
                )
            }
        }
        refreshWeekdayChips()
        val defaultOffset = defaultNotificationOffset(initialKind)
        val currentOffset = occurrence?.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs") ?: defaultOffset
        val notificationOptions = occurrenceNotificationOptionsIncluding(currentOffset)
        val notification = spinner(notificationOptions.map { it.label }.toTypedArray()).apply {
            setSelection(notificationOptions.indexOfFirst { it.offsetSecs == currentOffset }.coerceAtLeast(0))
            isEnabled = !readOnly
        }
        // iOS-style toggle row: label on the left, switch on the right.
        val completed = Switch(this).apply {
            isChecked = occurrence?.optBoolean("done", false) == true
            isEnabled = !readOnly
        }
        val completedRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
            addView(text("Completed", theme.textPrimary, 15f, false), LinearLayout.LayoutParams(0, -2, 1f))
            addView(completed, LinearLayout.LayoutParams(-2, -2))
            setOnClickListener { if (!readOnly) completed.toggle() }
        }

        titleInput.apply {
            setSingleLine(true)
            background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
            minHeight = dp(42)
        }
        styleDialogSpinner(scheme)
        styleDialogSpinner(notification)
        styleDialogSpinner(repeat)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(theme.bgModal, dp(16), theme.borderOverlay)
            isFocusableInTouchMode = true
        }
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(7))
            addView(text(if (readOnly) "Details" else if (editing) "Edit" else "New", theme.textPrimary, 21f, true))
            val subtitle = when {
                readOnly -> "Imported calendar item"
                editing -> occurrence?.optString("scheme_name").orEmpty()
                else -> "Calendar item"
            }
            if (subtitle.isNotBlank()) {
                addView(text(subtitle, theme.textMuted, 12f, false).apply {
                    setPadding(0, dp(3), 0, 0)
                })
            }
        })

        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(4))
            addView(dialogLabel("Title"))
            addView(titleInput, LinearLayout.LayoutParams(-1, dp(42)).apply { setMargins(0, 0, 0, dp(9)) })
            if (!editing) {
                addView(dialogSpinnerField("Scheme", scheme), LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
            }
            addView(dialogLabel("Type"))
            addView(kindRow, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, dp(2), 0, dp(9)) })
        }
        lateinit var dateField: DialogField
        lateinit var startField: DialogField
        lateinit var endField: DialogField
        lateinit var notificationFieldView: View
        lateinit var repeatFieldView: View
        fun selectedKind(): String = activeKindValue
        fun refreshScheduleFields() {
            val activeKind = selectedKind()
            dateField.value.text = dialogDateLabel(selectedLocalDate)
            startField.label.text = if (activeKind == "reminder") "At" else "Start"
            startField.value.text = dialogTimeLabel(startTime)
            endField.label.text = if (activeKind == "assignment") "Due" else "End"
            endField.value.text = dialogTimeLabel(endTime)
            dateField.view.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
            startField.view.visibility = if (activeKind == "event" || activeKind == "reminder") View.VISIBLE else View.GONE
            endField.view.visibility = if (activeKind == "event" || activeKind == "assignment") View.VISIBLE else View.GONE
            notificationFieldView.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
            repeatFieldView.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
        }
        dateField = dialogField("Date", dialogDateLabel(selectedLocalDate), enabled = !readOnly) {
            DatePickerDialog(this, dateDialogTheme(), { _, year, month, day ->
                selectedLocalDate = LocalDate.of(year, month + 1, day)
                refreshScheduleFields()
            }, selectedLocalDate.year, selectedLocalDate.monthValue - 1, selectedLocalDate.dayOfMonth).show()
        }
        startField = dialogField("Start", dialogTimeLabel(startTime), enabled = !readOnly) {
            TimePickerDialog(this, timeDialogTheme(), { _, hour, minute ->
                startTime = LocalTime.of(hour, minute)
                refreshScheduleFields()
            }, startTime.hour, startTime.minute, timeFormat24()).show()
        }
        endField = dialogField("End", dialogTimeLabel(endTime), enabled = !readOnly) {
            TimePickerDialog(this, timeDialogTheme(), { _, hour, minute ->
                endTime = LocalTime.of(hour, minute)
                refreshScheduleFields()
            }, endTime.hour, endTime.minute, timeFormat24()).show()
        }
        form.addView(dateField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(7)) })
        form.addView(startField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(7)) })
        form.addView(endField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        notificationFieldView = dialogSpinnerField("Notification", notification)
        repeatFieldView = dialogSpinnerField("Repeat", repeat)
        form.addView(notificationFieldView, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        form.addView(repeatFieldView, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        form.addView(weekdayRow, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(10)) })
        fun refreshWeekdayRowVisibility() {
            weekdayRow.visibility = if (selectedKind() != "task" && repeat.selectedItemPosition == repeatValues.indexOf("weekly")) {
                View.VISIBLE
            } else {
                View.GONE
            }
        }
        repeat.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                refreshWeekdayRowVisibility()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        if (editing) {
            form.addView(completedRow, LinearLayout.LayoutParams(-1, dp(46)).apply { setMargins(0, dp(2), 0, dp(8)) })
        }
        if (readOnly) {
            form.addView(text("Imported calendar items are read-only.", theme.textMuted, 12f, false), LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        }
        kindValues.forEach { value ->
            kindChips[value]?.setOnClickListener {
                if (readOnly || activeKindValue == value) return@setOnClickListener
                activeKindValue = value
                refreshKindChips()
                refreshScheduleFields()
                refreshWeekdayRowVisibility()
            }
        }
        refreshKindChips()
        refreshScheduleFields()
        refreshWeekdayRowVisibility()
        card.addView(ScrollView(this).apply {
            isFillViewport = false
            addView(form)
        }, LinearLayout.LayoutParams(-1, -2))

        lateinit var dialog: AlertDialog
        fun saveAndDismiss() {
            if (readOnly) {
                occurrence?.optString("scheme_id")?.let(::openScheme)
                dialog.dismiss()
                return
            }
            val activeKind = selectedKind()
            val startValue = when (activeKind) {
                "event", "reminder" -> MobileDateFormatting.iso(selectedLocalDate, startTime.hour, startTime.minute)
                else -> null
            }
            val endValue = when (activeKind) {
                "event", "assignment" -> MobileDateFormatting.iso(selectedLocalDate, endTime.hour, endTime.minute)
                else -> null
            }
            val rrule = if (activeKind == "task") null else MobileRecurrence.rruleForRepeat(repeatValues[repeat.selectedItemPosition.coerceIn(0, repeatValues.lastIndex)], selectedLocalDate, selectedWeekdays)
            val notificationOffset = if (activeKind == "task") null else notificationOptions[notification.selectedItemPosition].offsetSecs
            if (occurrence != null) {
                val commit = { scope: String ->
                    commitEventEdit(
                        occurrence = occurrence,
                        title = titleInput.text.toString().trim(),
                        start = startValue,
                        end = endValue,
                        rrule = rrule,
                        notificationOffsetSecs = notificationOffset,
                        notificationDirty = activeKind != "task",
                        done = completed.isChecked,
                        scope = scope
                    )
                }
                if (occurrence.optBoolean("is_recurring", false)) {
                    showOccurrenceScopeDialog("Recurring task", occurrence, forDelete = false) { scope ->
                        commit(scope)
                    }
                } else {
                    commit("all_events")
                }
            } else {
                val schemeId = schemeIds.getOrNull(scheme.selectedItemPosition)
                val newId = createCalendarItemReturningID(
                    kind = activeKind,
                    text = titleInput.text.toString().trim(),
                    date = selectedLocalDate,
                    start = startValue,
                    end = endValue,
                    schemeId = schemeId
                )
                val resolvedScheme = schemeId ?: todayDailySchemeId()
                if (newId != null && resolvedScheme != null) {
                    if (rrule != null) {
                        bridge.request(obj("type" to "set_item_recurrence", "scheme_id" to resolvedScheme, "item_id" to newId, "rrule" to rrule))
                    }
                    if (activeKind != "task") {
                        bridge.request(
                            obj(
                                "type" to "set_occurrence_notification_offset",
                                "scheme_id" to resolvedScheme,
                                "item_id" to newId,
                                "occurrence_json" to null,
                                "offset_secs" to notificationOffset
                            )
                        )
                    }
                    loadSnapshot()
                    rescheduleNotifications()
                    render()
                }
            }
            dialog.dismiss()
        }
        fun deleteAndDismiss() {
            if (occurrence == null) return
            val delete = { scope: String -> deleteEventOccurrence(occurrence, scope) }
            if (occurrence.optBoolean("is_recurring", false)) {
                showOccurrenceScopeDialog("Delete recurring task?", occurrence, forDelete = true, onScope = delete)
            } else {
                AlertDialog.Builder(this)
                    .setTitle("Delete this task?")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Delete") { _, _ -> delete("all_events") }
                    .show()
            }
            dialog.dismiss()
        }
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(6), dp(12), dp(12))
            if (editing && !readOnly) {
                addView(dialogActionButton("Delete", danger = true) { deleteAndDismiss() }, LinearLayout.LayoutParams(-2, dp(38)))
            }
            addView(View(this@MainActivity), LinearLayout.LayoutParams(0, 1, 1f))
            addView(dialogActionButton(if (readOnly) "Done" else "Cancel") { dialog.dismiss() }, LinearLayout.LayoutParams(-2, dp(38)).apply {
                setMargins(0, 0, dp(8), 0)
            })
            addView(dialogActionButton(if (readOnly) "Open Scheme" else "Save", primary = !readOnly) { saveAndDismiss() }, LinearLayout.LayoutParams(-2, dp(38)))
        })

        dialog = AlertDialog.Builder(this)
            .setView(card)
            .create()
        onDismiss?.let { callback -> dialog.setOnDismissListener { callback() } }
        dialog.show()
        card.requestFocus()
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(min(resources.displayMetrics.widthPixels - dp(32), dp(500)), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun commitEventEdit(
        occurrence: JSONObject,
        title: String,
        start: String?,
        end: String?,
        rrule: String?,
        notificationOffsetSecs: Int?,
        notificationDirty: Boolean,
        done: Boolean,
        scope: String
    ) {
        mutate(
            obj(
                "type" to "commit_event_edit",
                "scheme_id" to occurrence.optString("scheme_id"),
                "item_id" to occurrence.optString("item_id"),
                "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}"),
                "occurrence_index" to occurrence.optInt("occurrence_index", 0),
                "title" to title,
                "occurrence_start" to occurrence.optionalString("start"),
                "occurrence_end" to occurrence.optionalString("end"),
                "start" to start,
                "end" to end,
                "rrule" to rrule,
                "notification_offset_secs" to notificationOffsetSecs,
                "notification_dirty" to notificationDirty,
                "done" to done,
                "scope" to scope
            )
        )
    }

    internal fun deleteEventOccurrence(occurrence: JSONObject, scope: String) {
        mutate(
            obj(
                "type" to "delete_event_occurrence",
                "scheme_id" to occurrence.optString("scheme_id"),
                "item_id" to occurrence.optString("item_id"),
                "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}"),
                "occurrence_index" to occurrence.optInt("occurrence_index", 0),
                "scope" to scope
            )
        )
    }

    internal fun showOccurrenceScopeDialog(
        title: String,
        occurrence: JSONObject,
        forDelete: Boolean,
        onCancel: (() -> Unit)? = null,
        onScope: (String) -> Unit
    ) {
        val choices = mutableListOf("This task" to "this_event")
        if (occurrence.optBoolean("can_delete_future", false)) {
            choices.add("This and future tasks" to "all_future")
        }
        choices.add("All tasks" to "all_events")
        var chose = false
        // No setMessage here: AlertDialog drops the item list when a message is
        // set, which left this dialog with nothing but Cancel.
        AlertDialog.Builder(this)
            .setTitle(if (forDelete) "$title — which tasks should be deleted?" else "$title — which tasks should these changes apply to?")
            .setItems(choices.map { it.first }.toTypedArray()) { _, which ->
                chose = true
                onScope(choices[which].second)
            }
            .setNegativeButton("Cancel", null)
            .setOnDismissListener { if (!chose) onCancel?.invoke() }
            .show()
    }

    internal fun createCalendarItemReturningID(
        kind: String,
        text: String,
        date: LocalDate,
        start: String?,
        end: String?,
        schemeId: String?
    ): String? {
        val targetId = if (schemeId != null) {
            schemeId
        } else {
            bridge.request(obj("type" to "ensure_daily_queue", "date" to LocalDate.now().toString()))
            loadSnapshot()
            todayDailySchemeId() ?: return null
        }
        val before = schemeItemIds(targetId)
        bridge.request(
            obj(
                "type" to "add_calendar_item",
                "scheme_id" to targetId,
                "kind" to kind,
                "text" to text,
                "date" to date.toString(),
                "start" to start,
                "end" to end
            )
        )
        loadSnapshot()
        requestSyncSoon()
        return schemeItemIds(targetId).firstOrNull { !before.contains(it) }
    }

    internal fun schemeItemIds(schemeId: String): Set<String> {
        val ids = mutableSetOf<String>()
        findScheme(schemeId)?.optJSONArray("items")?.forEachObject { item ->
            ids.add(item.optString("id"))
        }
        return ids
    }

    internal fun todayDailySchemeId(): String? {
        val today = LocalDate.now().toString()
        val daily = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until daily.length()) {
            val entry = daily.optJSONObject(index) ?: continue
            if (entry.optString("date") == today) return entry.optJSONObject("scheme")?.optString("id")
        }
        return null
    }

    internal fun defaultNotificationOffset(kind: String): Int {
        val settings = snapshot.optJSONObject("settings")
        return when (kind) {
            "event" -> settings?.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS
            "assignment" -> settings?.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
            else -> 0
        }
    }

    internal fun showMarkerDialog(schemeId: String, itemId: String) {
        val markers = arrayOf("checkbox", "blank", "bullet", "numbered")
        AlertDialog.Builder(this)
            .setTitle("Marker")
            .setItems(markers) { _, which ->
                mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to itemId, "marker" to markers[which]))
            }
            .show()
    }

    /// iOS `ItemDateSheet` equivalent: the full schedule editor (type chips,
    /// date/time fields, notification, repeat) instead of a Set/Clear list.
    internal fun showDateKindDialog(schemeId: String, itemId: String) {
        val item = findItem(schemeId, itemId) ?: return
        val scheme = findScheme(schemeId)
        val hasStart = item.optionalString("start") != null
        val hasEnd = item.optionalString("end") != null
        val kind = when {
            hasStart && hasEnd -> "event"
            hasStart -> "reminder"
            hasEnd -> "assignment"
            else -> "task"
        }
        showEventEditorDialog(obj(
            "scheme_id" to schemeId,
            "item_id" to itemId,
            "title" to item.optString("text"),
            "kind" to kind,
            "start" to item.optionalString("start"),
            "end" to item.optionalString("end"),
            "occurrence_json" to "{\"kind\":\"single\"}",
            "is_recurring" to (item.optionalString("repeat_rule") != null),
            "repeat_rule" to item.optionalString("repeat_rule"),
            "notification_offset_secs" to item.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs"),
            "done" to item.optBoolean("done", false),
            "scheme_name" to (scheme?.optString("display_name").orEmpty()),
            "color_index" to (scheme?.optInt("color_index") ?: 0)
        ))
    }

    internal fun showItemDateDialog(schemeId: String, itemId: String, kind: String) {
        val form = page(compact = true)
        val initial = MobileDateFormatting.localDateTime(findItem(schemeId, itemId)?.optionalString(kind))
        val pickerCtx = inlinePickerContext()
        val date = DatePicker(pickerCtx).apply {
            val local = initial?.toLocalDate() ?: selectedDate
            updateDate(local.year, local.monthValue - 1, local.dayOfMonth)
        }
        val time = TimePicker(pickerCtx).apply {
            setIs24HourView(timeFormat24())
            val local = initial?.toLocalTime() ?: LocalTime.now().withSecond(0).withNano(0)
            hour = local.hour
            minute = local.minute
        }
        form.addView(date, spaced())
        form.addView(time)
        AlertDialog.Builder(this)
            .setTitle(kind.replaceFirstChar(Char::titlecase))
            .setView(form)
            .setPositiveButton("Save") { _, _ ->
                val localDate = LocalDate.of(date.year, date.month + 1, date.dayOfMonth)
                mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to kind, "date" to MobileDateFormatting.iso(localDate, time.hour, time.minute)))
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    internal fun showItemActions(schemeId: String, item: JSONObject, index: Int, count: Int) {
        val actions = arrayOf("Move Up", "Move Down", "Indent", "Outdent", "Edit", "Delete")
        AlertDialog.Builder(this)
            .setTitle(item.optString("text").ifEmpty { "Item" })
            .setItems(actions) { _, which ->
                when (which) {
                    0 -> if (index > 0) mutate(obj("type" to "reorder_item", "scheme_id" to schemeId, "from" to index, "to" to index - 1))
                    1 -> if (index < count - 1) mutate(obj("type" to "reorder_item", "scheme_id" to schemeId, "from" to index, "to" to index + 1))
                    2 -> mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to min(item.optInt("indent") + 1, 8)))
                    3 -> mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to max(item.optInt("indent") - 1, 0)))
                    4 -> showItemDialog(schemeId, item)
                    5 -> mutate(obj("type" to "delete_item", "scheme_id" to schemeId, "item_id" to item.optString("id")))
                }
            }
            .show()
    }

    internal fun showSchemeActions(nodeOrScheme: JSONObject) {
        val id = nodeOrScheme.optString("id")
        val isDaily = nodeOrScheme.optBoolean("is_daily_queue", false)
        if (nodeOrScheme.optBoolean("is_read_only", false)) {
            AlertDialog.Builder(this)
                .setTitle(nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")))
                .setItems(arrayOf("Open Scheme")) { _, _ -> openScheme(id) }
                .show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")))
            .setItems(arrayOf("Rename", "Color", "Reorder", "Move to Folder", "Archive")) { _, which ->
                when (which) {
                    0 -> showNameDialog(
                        "Rename Scheme",
                        nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")),
                        { validateSchemeName(it, folderId = parentFolderIdForScheme(id), excludingId = id, checkDuplicates = !isDaily) }
                    ) { name -> mutate(obj("type" to "rename_scheme", "scheme_id" to id, "name" to name)) }
                    1 -> showColorDialog(id)
                    2 -> showReorderDialog(id)
                    3 -> showMoveToFolderDialog("scheme", id)
                    4 -> if (!isDaily) mutate(obj("type" to "delete_scheme", "scheme_id" to id))
                }
            }
            .show()
    }

    /// iOS-style swatch grid (3x2, same color order as the iOS popover) instead
    /// of a text list.
    internal fun showColorDialog(schemeId: String) {
        val currentIndex = findScheme(schemeId)?.optInt("color_index") ?: 0
        lateinit var dialog: AlertDialog
        val order = intArrayOf(0, 1, 5, 2, 3, 4)
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = rounded(theme.bgModal, dp(14), theme.borderOverlay)
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }
        for (rowStart in order.indices step 3) {
            grid.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                for (cell in rowStart until min(rowStart + 3, order.size)) {
                    val colorIndex = order[cell]
                    val selected = colorIndex == currentIndex
                    addView(FrameLayout(this@MainActivity).apply {
                        background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(8))
                        addView(FrameLayout(this@MainActivity).apply {
                            background = rounded(
                                schemeColor(colorIndex),
                                dp(6),
                                if (selected) theme.textPrimary else theme.borderOverlay,
                                if (selected) dp(2) else max(1, (0.8f * resources.displayMetrics.density).roundToInt())
                            )
                            if (selected) {
                                addView(
                                    iconImage(R.drawable.ic_knotq_check_24, if (theme.isDark) adjustAlpha(Color.BLACK, 0.82f) else Color.WHITE),
                                    FrameLayout.LayoutParams(dp(13), dp(13), Gravity.CENTER)
                                )
                            }
                        }, FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER))
                        setOnClickListener {
                            mutate(obj("type" to "set_scheme_color", "scheme_id" to schemeId, "color_index" to colorIndex))
                            dialog.dismiss()
                        }
                    }, LinearLayout.LayoutParams(dp(46), dp(46)).apply { setMargins(dp(3), dp(3), dp(3), dp(3)) })
                }
            }, LinearLayout.LayoutParams(-2, -2))
        }
        dialog = AlertDialog.Builder(this)
            .setView(grid)
            .create()
        dialog.show()
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun showFolderActions(node: JSONObject) {
        AlertDialog.Builder(this)
            .setTitle(node.optString("name"))
            .setItems(arrayOf("New Scheme", "New Folder", "Rename", "Reorder", "Move to Folder", "Archive")) { _, which ->
                when (which) {
                    0 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = node.optString("id")) }) { name ->
                        mutate(obj("type" to "create_scheme", "folder_id" to node.optString("id"), "name" to name, "position" to 0))
                    }
                    1 -> showNameDialog("New Folder", "", { validateFolderName(it) }) { name ->
                        mutate(obj("type" to "create_folder", "parent_id" to node.optString("id"), "name" to name))
                    }
                    2 -> showNameDialog("Rename Folder", node.optString("name"), { validateFolderName(it, excludingId = node.optString("id")) }) { name ->
                        mutate(obj("type" to "rename_folder", "folder_id" to node.optString("id"), "name" to name))
                    }
                    3 -> showReorderDialog(node.optString("id"))
                    4 -> showMoveToFolderDialog("folder", node.optString("id"), excludedFolderId = node.optString("id"))
                    5 -> AlertDialog.Builder(this)
                        .setTitle("Archive \"${node.optString("name")}\"?")
                        .setMessage("The folder and everything inside it move to the archive.")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Archive") { _, _ ->
                            mutate(obj("type" to "delete_folder", "folder_id" to node.optString("id")))
                        }
                        .show()
                }
            }
            .show()
    }

    internal fun showArchiveActions() {
        AlertDialog.Builder(this)
            .setTitle("Archive")
            .setItems(arrayOf("Empty Archive")) { _, which ->
                if (which == 0) mutate(obj("type" to "empty_archive"))
            }
            .show()
    }

    /// iOS `SettingsArchiveList`: the archive tree always expanded (folders by
    /// icon, schemes by color square), each row restorable inline; deletes are
    /// permanent and confirmed.
    internal fun renderArchivePage(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, "Back", iconSize = 20) {
                settingsShowingArchive = false
                render()
            })
            addView(text("Archive", theme.textPrimary, 16f, true).apply {
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(View(this@MainActivity), LinearLayout.LayoutParams(dp(32), dp(28)))
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val body = page()
        val nodes = snapshot.optJSONArray("archived_nodes") ?: JSONArray()
        if (nodes.length() == 0) {
            body.addView(text("No archived items", theme.textMuted, 14f, false).apply {
                setPadding(dp(2), dp(10), 0, 0)
            })
        } else {
            fun addRows(array: JSONArray, depth: Int) {
                array.forEachObject { node ->
                    body.addView(archiveNodeRow(node, depth), LinearLayout.LayoutParams(-1, dp(40)))
                    if (node.optString("kind") == "folder") {
                        node.optJSONArray("children")?.let { addRows(it, depth + 1) }
                    }
                }
            }
            addRows(nodes, 0)
            body.addView(text("Empty Archive", theme.danger, 14f, true).apply {
                setPadding(dp(2), dp(16), dp(8), dp(10))
                setOnClickListener {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Empty archive?")
                        .setMessage("Permanently deletes every archived item. This can't be undone.")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Delete All") { _, _ -> mutate(obj("type" to "empty_archive")) }
                        .show()
                }
            })
        }
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun archiveNodeRow(node: JSONObject, depth: Int): View {
        val isFolder = node.optString("kind") == "folder"
        val id = node.optString("id")
        val name = node.optString("name").ifEmpty { if (isFolder) "Folder" else "Untitled" }
        fun restore() {
            mutate(obj(
                "type" to if (isFolder) "restore_folder" else "restore_scheme",
                (if (isFolder) "folder_id" else "scheme_id") to id
            ))
        }
        fun confirmPermanentDelete() {
            AlertDialog.Builder(this)
                .setTitle("Delete \"$name\" permanently?")
                .setMessage(if (isFolder) "Deletes the folder and everything inside it. This can't be undone." else "This can't be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete") { _, _ ->
                    mutate(obj(
                        "type" to if (isFolder) "permanently_delete_folder" else "permanently_delete_scheme",
                        (if (isFolder) "folder_id" else "scheme_id") to id
                    ))
                }
                .show()
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(2 + depth * 16), 0, 0, 0)
            addView(FrameLayout(this@MainActivity).apply {
                if (isFolder) {
                    addView(
                        iconImage(R.drawable.ic_knotq_folder_24, theme.textMuted),
                        FrameLayout.LayoutParams(dp(13), dp(13), Gravity.CENTER)
                    )
                } else {
                    addView(View(this@MainActivity).apply {
                        background = rounded(adjustAlpha(schemeColor(node.optInt("color_index")), 0.72f), dp(2))
                    }, FrameLayout.LayoutParams(dp(11), dp(11), Gravity.CENTER))
                }
            }, LinearLayout.LayoutParams(dp(18), dp(18)))
            addView(text(name, theme.textPrimary, 14f, false).apply {
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(8), 0, dp(8), 0) })
            addView(text("Restore", theme.accent, 13f, true).apply {
                setPadding(dp(8), dp(8), dp(8), dp(8))
                setOnClickListener { restore() }
            }, LinearLayout.LayoutParams(-2, -2))
            setOnLongClickListener {
                AlertDialog.Builder(this@MainActivity)
                    .setTitle(name)
                    .setItems(arrayOf("Restore", "Delete Permanently")) { _, which ->
                        when (which) {
                            0 -> restore()
                            1 -> confirmPermanentDelete()
                        }
                    }
                    .show()
                true
            }
        }
    }

    internal fun showArchivedSchemeActions(scheme: JSONObject) {
        AlertDialog.Builder(this)
            .setTitle(scheme.optString("display_name"))
            .setItems(arrayOf("Restore", "Delete Permanently")) { _, which ->
                when (which) {
                    0 -> mutate(obj("type" to "restore_scheme", "scheme_id" to scheme.optString("id")))
                    1 -> mutate(obj("type" to "permanently_delete_scheme", "scheme_id" to scheme.optString("id")))
                }
            }
            .show()
    }

    internal fun showNameDialog(title: String, initial: String, validator: (String) -> String?, callback: (String) -> Unit) {
        val input = edit(initial).apply {
            setSingleLine(true)
            background = rounded(theme.bgModal, dp(5), theme.borderOverlay)
            setPadding(dp(10), 0, dp(10), 0)
        }
        val error = text("", theme.danger, 11f, true).apply {
            visibility = View.GONE
            setPadding(dp(2), dp(5), dp(2), 0)
        }
        fun refreshError(): String? {
            val message = validator(input.text.toString())
            error.text = message.orEmpty()
            error.visibility = if (message == null) View.GONE else View.VISIBLE
            return message
        }
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                refreshError()
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        val form = page(compact = true).apply {
            setPadding(0, 0, 0, 0)
            addView(input, LinearLayout.LayoutParams(-1, dp(44)))
            addView(error, LinearLayout.LayoutParams(-1, -2))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(title)
            .setView(form)
            .setPositiveButton("Save", null)
            .setNegativeButton("Cancel", null)
            .create()
        dialog.setOnShowListener {
            refreshError()
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (refreshError() == null) {
                    callback(input.text.toString())
                    dialog.dismiss()
                }
            }
        }
        dialog.show()
    }

    internal fun showDatePicker() {
        DatePickerDialog(this, dateDialogTheme(), { _, year, month, day ->
            selectedDate = LocalDate.of(year, month + 1, day)
            ensureDaily()
        }, selectedDate.year, selectedDate.monthValue - 1, selectedDate.dayOfMonth).show()
    }

    internal fun showMonthPickerDialog() {
        var displayMonth = selectedDate.withDayOfMonth(1)
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(12))
            background = rounded(theme.bgApp, dp(16), theme.borderOverlay)
        }
        val title = text(monthTitle(displayMonth), theme.textPrimary, 20f, true).apply {
            gravity = Gravity.CENTER
        }
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(theme.bgModal, dp(10), theme.borderOverlay)
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        lateinit var dialog: AlertDialog

        fun renderMonth() {
            title.text = monthTitle(displayMonth)
            grid.removeAllViews()
            grid.addView(monthWeekdayRow(), LinearLayout.LayoutParams(-1, dp(22)))
            val days = monthDayOccurrences(displayMonth)
            val first = displayMonth.withDayOfMonth(1)
            val gridStart = first.minusDays((first.dayOfWeek.value % 7).toLong())
            for (rowIndex in 0 until 6) {
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                }
                for (columnIndex in 0 until 7) {
                    val date = gridStart.plusDays((rowIndex * 7 + columnIndex).toLong())
                    row.addView(monthDayCell(date, displayMonth, days[date.toString()] ?: JSONArray()) {
                        selectedDate = date
                        weekOffset = 0
                        loadSnapshot()
                        render()
                        dialog.dismiss()
                    }, LinearLayout.LayoutParams(0, dp(52), 1f))
                }
                grid.addView(row, LinearLayout.LayoutParams(-1, dp(52)))
            }
        }

        container.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, "Previous month", iconSize = 18) {
                displayMonth = displayMonth.minusMonths(1)
                renderMonth()
            })
            addView(title, LinearLayout.LayoutParams(0, dp(38), 1f))
            addView(iconChipImage(R.drawable.ic_knotq_chevron_right_24, "Next month", iconSize = 18) {
                displayMonth = displayMonth.plusMonths(1)
                renderMonth()
            })
        }, LinearLayout.LayoutParams(-1, dp(42)).apply {
            setMargins(0, 0, 0, dp(8))
        })
        container.addView(grid)

        dialog = AlertDialog.Builder(this)
            .setView(container)
            .create()
        renderMonth()
        dialog.show()
        // Card-style chrome (rounded, no button bar) — dismiss by tapping a
        // day or outside the card.
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(min(resources.displayMetrics.widthPixels - dp(24), dp(520)), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun monthWeekdayRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            listOf("S", "M", "T", "W", "T", "F", "S").forEach { label ->
                addView(text(label, theme.textMuted, 11f, true).apply {
                    gravity = Gravity.CENTER
                }, LinearLayout.LayoutParams(0, -1, 1f))
            }
        }

    internal fun monthDayCell(date: LocalDate, displayMonth: LocalDate, occurrences: JSONArray, onSelect: () -> Unit): View {
        val inMonth = date.monthValue == displayMonth.monthValue && date.year == displayMonth.year
        val isToday = date == LocalDate.now()
        val isSelected = date == selectedDate
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val day = text(date.dayOfMonth.toString(), monthDayTextColor(inMonth, isToday || isSelected), 14f, isToday || isSelected).apply {
                gravity = Gravity.CENTER
                if (isToday || isSelected) {
                    background = rounded(theme.accent, dp(17))
                }
            }
            addView(day, LinearLayout.LayoutParams(dp(34), dp(34)))
            addView(monthOccurrenceDots(occurrences), LinearLayout.LayoutParams(-1, dp(8)))
            setOnClickListener { onSelect() }
        }
    }

    internal fun monthOccurrenceDots(occurrences: JSONArray): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            val seen = LinkedHashSet<String>()
            occurrences.forEachObject { occurrence ->
                if (seen.size >= 4) return@forEachObject
                val key = occurrence.optString("scheme_name").takeIf { it == "Daily" }
                    ?: "scheme-${occurrence.optInt("color_index")}"
                if (seen.add(key)) {
                    addView(View(this@MainActivity).apply {
                        background = rounded(schemeColor(occurrence.optInt("color_index")), dp(3))
                    }, LinearLayout.LayoutParams(dp(5), dp(5)).apply {
                        setMargins(dp(1), 0, dp(1), 0)
                    })
                }
            }
        }

    internal fun monthDayTextColor(inMonth: Boolean, highlighted: Boolean): Int =
        when {
            highlighted -> Color.WHITE
            inMonth -> theme.textPrimary
            else -> theme.textMuted
        }

    internal fun monthDayOccurrences(month: LocalDate): Map<String, JSONArray> {
        return runCatching {
            val byDate = LinkedHashMap<String, JSONArray>()
            bridge.requestArray(obj("type" to "month_days", "year" to month.year, "month" to month.monthValue))
                .forEachObject { day ->
                    byDate[day.optString("date")] = day.optJSONArray("occurrences") ?: JSONArray()
                }
            byDate
        }.getOrElse { error ->
            showError("Calendar", error.message)
            emptyMap()
        }
    }

    internal fun openScheme(id: String) {
        // Remember where the editor was opened from so the back button returns
        // there (Home on phone), rather than the otherwise-unreachable lists page.
        if (selectedTab != TAB_SCHEMES) schemeReturnTab = selectedTab
        selectedTab = TAB_SCHEMES
        selectedSchemeId = id
        render()
    }

    internal fun exitSchemeEditor() {
        selectedSchemeId = null
        selectedTab = if (schemeReturnTab == TAB_SCHEMES) TAB_HOME else schemeReturnTab
        render()
    }

    internal fun addDailyItemFromHome() {
        ensureDaily()
        dailyScheme()?.let { scheme ->
            showItemDialog(scheme.optString("id"), null)
        } ?: toast("Daily not ready")
    }

    internal fun ensureDaily() {
        if (selectedTab == TAB_DAILY) {
            pendingDailyAutoFocusDate = selectedDate.toString()
        }
        mutate(obj("type" to "ensure_daily_queue", "date" to selectedDate.toString()))
    }

    internal fun ensureTodayDailyQueue() {
        val today = LocalDate.now().toString()
        val existing = snapshot.optJSONArray("daily")
        if (existing != null) {
            for (index in 0 until existing.length()) {
                if (existing.optJSONObject(index)?.optString("date") == today) return
            }
        }
        bridge.request(obj("type" to "ensure_daily_queue", "date" to today))
        loadSnapshot()
    }

    internal fun mutate(body: JSONObject) {
        try {
            bridge.request(body)
            loadSnapshot()
            rescheduleNotifications()
            render()
            requestSyncSoon()
        } catch (error: RuntimeException) {
            showError("Could not save", error.message)
        }
    }

    internal fun loadSnapshot() {
        snapshot = bridge.request(obj(
            "type" to "snapshot",
            "today" to selectedDate.toString(),
            "week_offset" to weekOffset,
            "daily_history_days" to dailyHistoryDays
        ))
        configureGoogleSyncPolling()
    }

    /// Mirrors iOS `loadOlderDailyEntries`: extend the daily history window by a
    /// month when the feed is scrolled to its oldest entry.
    internal fun loadOlderDailyEntries(oldestDate: String) {
        if (dailyHistoryLoadTriggerDate == oldestDate) return
        if (dailyHistoryDays >= 3650) return
        dailyHistoryLoadTriggerDate = oldestDate
        dailyHistoryDays = min(dailyHistoryDays + 31, 3650)
        pendingDailyAnchorDate = oldestDate
        loadSnapshot()
        render()
    }

    internal fun rescheduleNotifications() {
        if (!::bridge.isInitialized) return
        try {
            MobileNotificationScheduler.reschedule(
                this,
                bridge.requestArray(obj("type" to "pending_notifications"))
            )
        } catch (error: RuntimeException) {
            showError("Notifications unavailable", error.message)
        }
    }

    internal fun applyTheme() {
        val mode = snapshot.optJSONObject("settings")?.optString("theme_mode", "system") ?: "system"
        val darkSystem = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        theme = when (mode) {
            "light" -> UiTheme.light
            "system" -> if (darkSystem) UiTheme.dark else UiTheme.light
            else -> UiTheme.dark
        }
        applySystemBarColors()
    }

    @Suppress("DEPRECATION")
    internal fun applySystemBarColors() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            window.statusBarColor = theme.bgToolbar
            window.navigationBarColor = theme.bgSidebar
        }
    }

    internal fun calendar(): JSONObject = snapshot.optJSONObject("calendar") ?: JSONObject()

    internal fun dailyScheme(): JSONObject? {
        val days = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until days.length()) {
            val day = days.optJSONObject(index)
            if (day != null && selectedDate.toString() == day.optString("date")) {
                return day.optJSONObject("scheme")
            }
        }
        return null
    }

    internal fun dailyEntries(): List<JSONObject> {
        val days = snapshot.optJSONArray("daily") ?: return emptyList()
        val entries = ArrayList<JSONObject>(days.length())
        for (index in 0 until days.length()) {
            days.optJSONObject(index)?.let(entries::add)
        }
        entries.sortBy { it.optString("date") }
        return entries
    }

    internal fun dailyEntryForHome(): JSONObject? {
        val days = snapshot.optJSONArray("daily") ?: return null
        val selected = selectedDate.toString()
        val today = LocalDate.now().toString()
        var todayEntry: JSONObject? = null
        for (index in 0 until days.length()) {
            val entry = days.optJSONObject(index) ?: continue
            when (entry.optString("date")) {
                selected -> return entry
                today -> todayEntry = entry
            }
        }
        return todayEntry
    }

    internal fun archivedSchemes(): JSONArray = snapshot.optJSONArray("archived_schemes") ?: JSONArray()

    internal fun findScheme(id: String): JSONObject? {
        listOf(snapshot.optJSONArray("schemes"), snapshot.optJSONArray("archived_schemes")).forEach { schemes ->
            if (schemes != null) {
                for (index in 0 until schemes.length()) {
                    val scheme = schemes.optJSONObject(index)
                    if (scheme != null && id == scheme.optString("id")) return scheme
                }
            }
        }
        val daily = snapshot.optJSONArray("daily")
        if (daily != null) {
            for (index in 0 until daily.length()) {
                val scheme = daily.optJSONObject(index)?.optJSONObject("scheme")
                if (scheme != null && id == scheme.optString("id")) return scheme
            }
        }
        return null
    }

    internal fun findItem(schemeId: String, itemId: String): JSONObject? {
        val items = findScheme(schemeId)?.optJSONArray("items") ?: return null
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index)
            if (item != null && itemId == item.optString("id")) return item
        }
        return null
    }

    internal fun rootFolderId(): String? = snapshot.optJSONObject("root")?.optString("id")

    internal fun parentFolderIdForScheme(schemeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForScheme(schemeId, root)
    }

    internal fun parentFolderIdForScheme(schemeId: String, node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            if (child.optString("kind") == "scheme" && child.optString("id") == schemeId) {
                return node.optString("id")
            }
            if (child.optString("kind") == "folder") {
                parentFolderIdForScheme(schemeId, child)?.let { return it }
            }
        }
        return null
    }

    internal fun parentFolderIdForNode(nodeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForNode(nodeId, root)
    }

    internal fun parentFolderIdForNode(nodeId: String, node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            if (child.optString("id") == nodeId) {
                return node.optString("id")
            }
            if (child.optString("kind") == "folder") {
                parentFolderIdForNode(nodeId, child)?.let { return it }
            }
        }
        return null
    }

    internal fun moveNavigatorNode(kind: String, nodeId: String, delta: Int) {
        when (applyNodeMove(kind, nodeId, delta)) {
            true -> { rescheduleNotifications(); render() }
            false -> toast("Already there")
        }
    }

    // Shifts a node one slot within its parent; returns false at a boundary. Applies
    // the change and reloads the snapshot but does NOT re-render, so callers (e.g. the
    // reorder sheet) can apply several moves and refresh their own UI cheaply.
    internal fun applyNodeMove(kind: String, nodeId: String, delta: Int): Boolean {
        val parentId = parentFolderIdForNode(nodeId) ?: return false
        val parent = nodeById(parentId, snapshot.optJSONObject("root")) ?: return false
        val children = parent.optJSONArray("children") ?: return false
        var index = -1
        for (i in 0 until children.length()) {
            if (children.optJSONObject(i)?.optString("id") == nodeId) {
                index = i
                break
            }
        }
        if (index < 0) return false
        // move_node removes the node first, so positions index the
        // post-removal sibling list.
        val position = if (delta < 0) index - 1 else index + 1
        if (position < 0 || position > children.length() - 1) return false
        bridge.request(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to parentId, "position" to position))
        loadSnapshot()
        requestSyncSoon()
        return true
    }

    // A live reorder sheet for a node's siblings: stays open while you nudge items
    // up/down (instead of reopening the context menu for each single step, as iOS
    // drag-to-reorder avoids). Highlights the item the sheet was opened for.
    internal fun showReorderDialog(nodeId: String) {
        val parentId = parentFolderIdForNode(nodeId) ?: return toast("Cannot reorder this item")
        val parentName = nodeById(parentId, snapshot.optJSONObject("root"))?.optString("name")?.takeIf { it.isNotBlank() && parentId != rootFolderId() } ?: "Home"
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        val scrollView = ScrollView(this).apply { addView(list) }
        var changed = false
        lateinit var rebuild: () -> Unit
        fun siblings(): JSONArray =
            nodeById(parentId, snapshot.optJSONObject("root"))?.optJSONArray("children") ?: JSONArray()
        fun moveButton(iconRes: Int, description: String, enabled: Boolean, action: () -> Unit): View =
            FrameLayout(this).apply {
                contentDescription = description
                background = rounded(theme.buttonBg, dp(7), theme.borderOverlay)
                alpha = if (enabled) 1f else 0.3f
                addView(iconImage(iconRes, theme.textPrimary, description), FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER))
                if (enabled) setOnClickListener { action() }
                layoutParams = LinearLayout.LayoutParams(dp(40), dp(38)).apply { setMargins(dp(6), 0, 0, 0) }
            }
        rebuild = {
            list.removeAllViews()
            val children = siblings()
            val lastIndex = children.length() - 1
            if (children.length() == 0) {
                list.addView(text("Nothing to reorder", theme.textMuted, 13f, false))
            }
            for (i in 0 until children.length()) {
                val child = children.optJSONObject(i) ?: continue
                val childId = child.optString("id")
                val childKind = child.optString("kind")
                val isFolder = childKind == "folder"
                val highlight = childId == nodeId
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(8), 0, dp(6), 0)
                    background = rounded(if (highlight) theme.rowSelected else Color.TRANSPARENT, dp(8))
                    if (isFolder) {
                        addView(inlineIcon(R.drawable.ic_knotq_folder_24, theme.textMuted, widthDp = 18, iconSize = 15))
                    } else {
                        addView(colorSquare(schemeColor(child.optInt("color_index")), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply { setMargins(dp(4), 0, dp(4), 0) })
                    }
                    addView(text(child.optString("name").ifEmpty { child.optString("display_name") }, theme.textPrimary, 14f, highlight || isFolder).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, -1, 1f).apply { setMargins(dp(6), 0, 0, 0) })
                    addView(moveButton(R.drawable.ic_knotq_chevron_up_24, "Move up", i > 0) {
                        if (applyNodeMove(childKind, childId, -1)) { changed = true; rebuild() }
                    })
                    addView(moveButton(R.drawable.ic_knotq_chevron_down_24, "Move down", i < lastIndex) {
                        if (applyNodeMove(childKind, childId, 1)) { changed = true; rebuild() }
                    })
                }
                list.addView(row, LinearLayout.LayoutParams(-1, dp(46)))
            }
        }
        rebuild()
        val dialog = AlertDialog.Builder(this)
            .setTitle("Reorder · $parentName")
            .setView(scrollView)
            .setPositiveButton("Done", null)
            .create()
        dialog.setOnDismissListener { if (changed) render() }
        dialog.show()
    }

    internal fun showMoveToFolderDialog(kind: String, nodeId: String, excludedFolderId: String? = null) {
        val root = snapshot.optJSONObject("root") ?: return toast("Cannot move this item")
        val currentParentId = parentFolderIdForNode(nodeId) ?: return toast("Cannot move this item")
        val destinations = mutableListOf(FolderDestination(root.optString("id"), "Home", 0))
        collectFolderDestinations(root.optJSONArray("children"), 1, excludedFolderId, destinations)
        AlertDialog.Builder(this)
            .setTitle("Move To Folder")
            .setItems(destinations.map { destination ->
                "${"   ".repeat(destination.depth)}${destination.name}${if (destination.id == currentParentId) "  (current)" else ""}"
            }.toTypedArray()) { _, which ->
                val destination = destinations[which]
                if (destination.id == currentParentId) return@setItems toast("Already there")
                val target = nodeById(destination.id, root) ?: return@setItems toast("Cannot find folder")
                val position = target.optJSONArray("children")?.length() ?: 0
                mutate(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to destination.id, "position" to position))
            }
            .show()
    }

    internal fun collectFolderDestinations(nodes: JSONArray?, depth: Int, excludedFolderId: String?, destinations: MutableList<FolderDestination>) {
        nodes?.forEachObject { node ->
            if (node.optString("kind") == "folder" && node.optString("id") != excludedFolderId) {
                destinations.add(FolderDestination(node.optString("id"), node.optString("name"), depth))
                collectFolderDestinations(node.optJSONArray("children"), depth + 1, excludedFolderId, destinations)
            }
        }
    }

    internal fun validateSchemeName(name: String, folderId: String? = null, excludingId: String? = null, checkDuplicates: Boolean = true): String? {
        return null
    }

    internal fun validateFolderName(name: String, excludingId: String? = null): String? {
        return null
    }

    internal fun nodeById(id: String?, node: JSONObject?): JSONObject? {
        if (id == null || node == null) return null
        if (node.optString("id") == id) return node
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            nodeById(id, children.optJSONObject(index))?.let { return it }
        }
        return null
    }

    internal fun todayOccurrences(): JSONArray {
        val out = JSONArray()
        calendar().optJSONArray("days")?.forEachObject { day ->
            if (day.optString("date") == LocalDate.now().toString()) {
                day.optJSONArray("occurrences")?.forEachObject { out.put(it) }
            }
        }
        return out
    }

}
