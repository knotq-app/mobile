package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
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
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
import android.view.animation.PathInterpolator
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import com.enigmadux.knotq.ffi.setLocale
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
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal enum class ContentTransitionDirection {
    FORWARD,
    BACKWARD,
}

private data class NavigatorTraversalFrame(
    val children: JSONArray,
    val parentId: String,
    val depth: Int,
    var nextIndex: Int = 0,
)

class MainActivity : Activity() {
    internal lateinit var bridge: RustBridge
    internal lateinit var rootFrame: FrameLayout
    internal lateinit var shell: LinearLayout
    internal lateinit var titleBar: LinearLayout
    internal lateinit var content: FrameLayout
    internal lateinit var dock: LinearLayout
    // Vector resources are used throughout the chrome and repeated in every
    // row. Cache their immutable constant states per Activity; each ImageView
    // still receives a fresh mutable drawable for its tint, but startup and
    // route rebuilds no longer re-inflate the same XML over and over.
    internal val iconDrawableStates = HashMap<Int, Drawable.ConstantState>()
    // Foreground state belongs to this Activity instance. A process-wide flag
    // can be cleared by the old Activity's onStop while a replacement Activity
    // is already live during recreation.
    @Volatile internal var activityForeground = false
    // The main content is intentionally rebuilt from the immutable snapshot, but
    // the title bar and phone dock are stable chrome. Recreating them on every
    // sync/status repaint adds measure work and briefly detaches their icons.
    // These signatures let a data refresh reuse the existing controls while
    // navigation, theme, account, or title changes still rebuild them.
    private data class TitleBarRenderSignature(
        val title: String,
        val selectedTab: Int,
        val selectedSchemeId: String?,
        val leadingColor: Int,
        val accountEmail: String,
        val theme: UiTheme,
    )

    private data class DockRenderSignature(
        val selectedTab: Int,
        val wide: Boolean,
        val theme: UiTheme,
    )

    /**
     * State that changes the main content subtree itself. Sync/account status
     * often asks for a repaint while the immutable workspace snapshot and route
     * are unchanged; keeping that repaint from tearing down the whole native
     * tree is the Android equivalent of SwiftUI's stable identity here.
     */
    private data class ContentRenderState(
        val selectedTab: Int,
        val selectedSchemeId: String?,
        val selectedDate: LocalDate,
        val weekOffset: Int,
        val wide: Boolean,
        val theme: UiTheme,
        val settingsShowingArchive: Boolean,
        val settingsShowingTiming: Boolean,
        val settingsShowingGoogle: Boolean,
        val dailyHistoryDays: Int,
        val collapsedFolderIds: Set<String>,
        val pendingDailyAnchorDate: String?,
        val pendingDailyAutoFocusDate: String?,
        val pendingTitleFocusSchemeId: String?,
        val keyboardActive: Boolean,
        val showPhoneDock: Boolean,
        val showPhoneQuickActions: Boolean,
        // Settings includes account/Google status that is intentionally kept
        // outside the workspace snapshot. Include only the visible fields so
        // status changes repaint that route without making every render rebuild
        // it unconditionally.
        val settingsAccountEmail: String,
        val settingsAccountSupportsSync: Boolean?,
        val settingsSyncOffline: Boolean,
        val settingsSyncInProgress: Boolean,
        val settingsSubscriptionCancelled: Boolean,
        val settingsEmailVerified: Boolean?,
        val settingsResendInProgress: Boolean,
        val settingsResendCooldown: Int,
        val settingsPurchaseInProgress: Boolean,
        val settingsGoogleAuthInProgress: Boolean,
        val settingsGoogleSyncInProgress: Boolean,
        val settingsGoogleCalendarStatus: String?,
    )

    private var renderedTitleBarSignature: TitleBarRenderSignature? = null
    private var renderedDockSignature: DockRenderSignature? = null
    private var renderedContentSnapshot: JSONObject? = null
    private var renderedContentState: ContentRenderState? = null
    private var pendingContentTransition: ContentTransitionDirection? = null
    private var activeContentTransition: Animator? = null
    private var activeTransitionIncomingView: View? = null
    private var activeTransitionOutgoingView: View? = null
    // Read-only transition state used by device-side motion regressions. Keep
    // the animator and its view ownership private so callers can observe the
    // invariant without being able to mutate an in-flight animation.
    internal val contentTransitionActive: Boolean
        get() = activeContentTransition != null
    internal val contentTransitionIncomingTranslationX: Float
        get() = activeTransitionIncomingView?.translationX ?: 0f
    // A scheme save can finish while its Back transition is still running.
    // Defer that snapshot-driven rebuild until the transition has released the
    // outgoing page, otherwise the render would cancel the animation mid-flight.
    private var pendingContentTransitionRender = false
    // `updateChromeVisibility()` is also called directly by IME/window-inset
    // callbacks. Keep those visibility changes atomic without unsuppressing
    // the outer transaction while `renderNow()` is rebuilding the page.
    private var renderingMainTree = false
    internal lateinit var theme: UiTheme
    // System-bar/window colors are process chrome, not per-render content. Keep
    // the last applied value so snapshot refreshes do not repeatedly cross the
    // window manager boundary and briefly repaint the bars.
    internal var lastSystemBarTheme: UiTheme? = null

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
    // The viewer's timezone is part of calendar presentation state. Android can
    // change it while this Activity stays alive, so keep a lifecycle checkpoint
    // and refresh the snapshot when the zone changes.
    internal var lastObservedTimeZoneId: String = ZoneId.systemDefault().id
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
    // Timing controls live on a dedicated page so the root settings list stays
    // scannable on a phone instead of becoming a wall of selectors.
    internal var settingsShowingTiming = false
    internal var settingsShowingGoogle = false
    // The month picker owns a separate Dialog window. Track it so a fast
    // rotation/background/destroy cannot leave a stale window attached to an
    // old Activity (or flash over the newly recreated shell).
    internal var activeMonthPickerDialog: AlertDialog? = null
    // Daily feed paging + scroll anchoring, mirroring the iOS bottom-pinned
    // feed: history grows by a month each time the user scrolls to the top.
    internal var homeScrollY = 0
    internal var dailyHistoryDays = 3
    internal var dailyHistoryLoadTriggerDate: String? = null
    internal var dailyScrollY = 0
    internal var dailyScrollDate: String? = null
    internal var dailyFirstVisibleDate: String? = null
    internal var dailyFirstVisibleTop = 0
    internal var pendingDailyAnchorDate: String? = null
    internal var pendingDailyAutoFocusDate: String? = null
    internal var pendingTitleFocusSchemeId: String? = null
    internal var lastRenderedTab: Int? = null
    // The first native snapshot can be large (calendar expansion + JSON
    // materialization). Keep the shell responsive while it is loaded off the
    // main thread, then publish one coherent snapshot/render on completion.
    internal var workspaceReady = false
    // Startup can finish while the Activity is stopped. Keep the loaded
    // snapshot until onStart can publish it into the live view tree exactly
    // once.
    internal var workspaceUiPublished = false
        // Publish the first full workspace tree after the loading shell has had
        // one frame to settle. Building hundreds of native views is synchronous
        // on Android; doing it in the same turn as the first focus transition
        // can make the window manager report an input ANR even though the app is
        // otherwise healthy. Keep this pending state explicit so onStart and a
        // late snapshot completion cannot schedule duplicate full renders.
    internal var workspaceRenderPending = false
    private var workspaceRenderRunnable: Runnable? = null
    internal var startupEffectsApplied = false
    internal var startupSeededScreenshotFixture = false
    internal var pendingStartupAuthIntent: Uri? = null
    // Android's notification permission dialog is a full-window system surface
    // on some landscape/tablet configurations. Do not launch it in the same
    // frame as the first workspace tree, or the user can briefly see only the
    // dialog and mistake the underlying Home/Settings shell for a blank page.
    private var notificationPermissionRunnable: Runnable? = null
    private var notificationPermissionDeferred = false
    private val notificationPermissionDelayMs = 650L
    // JNA/native loading is expensive on a cold Android process. Keep it off
    // Activity.onCreate so the platform can display the stable shell while the
    // bridge opens in the same serialized executor used by all core work.
    internal var bridgeStartupPending = false
    // Background sync/status completions can arrive in a burst. Coalesce their
    // full-tree redraws onto the next frame so the old tree is not torn down and
    // rebuilt several times before Android has drawn any of them.
    internal var renderRequestPending = false
    internal var renderDeferredWhileEditing = false
    // Snapshot callbacks must not replace the CalendarTimelineView while a
    // swipe is settling. Replacing it cancels the animator and can drop the
    // user's second rapid swipe before it commits its adjacent day.
    internal var calendarGestureActive = false
    internal var renderDeferredWhileCalendarGesture = false
    internal val renderRequestRunnable = Runnable {
        renderRequestPending = false
        if (!isUiActive()) return@Runnable
        // The request may have been posted just before the user's swipe
        // crossed the touch slop. Re-check ownership at execution time too;
        // guarding only requestRender() still lets an already queued runnable
        // detach the timeline in the middle of the snap animation.
        if (calendarGestureActive) {
            renderDeferredWhileCalendarGesture = true
            return@Runnable
        }
        if (activeContentTransition != null) {
            // A status/sync repaint must not cancel an in-flight page slide.
            // The transition listener will flush this request after both
            // pages have reached their final positions.
            pendingContentTransitionRender = true
            return@Runnable
        }
        render()
    }
    internal val editorSchemeIds = WeakHashMap<EditText, String>()
    // The FrameLayout wrapping each editor, used to float the inline table-cell
    // editor over a tapped cell.
    internal val editorHosts = WeakHashMap<EditText, FrameLayout>()
    internal var lastActiveEditor: EditText? = null
    internal var suppressEditorBlurCommit = false
    // A render can be triggered by two adjacent table/editor mutations. The
    // older posted clear must not release the suppression window belonging to
    // the newer render.
    private var editorMutationGeneration = 0L
    // Pending debounced live flush of the active editor into the core (push-on-type).
    internal var editorFlushRunnable: Runnable? = null
    // A live editor flush is a replace-the-whole-document write. If it is still
    // queued behind sync or a blur commit, a newer document supersedes it; let
    // the core queue skip that stale payload before it enters native code.
    internal val editorFlushGate = LatestRequestGate()
    // One FIFO boundary for every native-core call. Writes/snapshots use
    // `execute`; background loops that need a result use `call` on their own
    // thread. Keeping both on the same queue avoids native-lock contention and
    // preserves edit order (like iOS's serial bridge queue) without blocking UI.
    internal val coreExecutor = SerialCoreExecutor()
    // The inline cell editor currently shown (if any), so a second tap commits
    // the first before moving on.
    internal var activeCellEdit: ActiveCellEdit? = null
    internal var tableStructureDialogOpen = false

    // Re-tints the format bar's marker buttons for the caret's line; rebuilt
    // with each rendered format bar and invoked from editor selection changes.
    internal var formatBarMarkerRefresh: (() -> Unit)? = null
    // Keep the format bar's horizontal scroll position across re-renders.
    internal var formatBarScrollX = 0
    // Search runs through the same serial core executor as edits, but never on
    // the UI thread. The serial invalidates stale results when typing quickly.
    internal var searchRequestSerial = 0L
    internal var searchRequestRunnable: Runnable? = null
    // Search can be triggered by text changes, IME action, and focus loss. Keep
    // the last query's snapshot identity so those overlapping callbacks do not
    // submit the same core search twice, while a newer workspace snapshot can
    // still refresh an unchanged query.
    internal var searchLastQuery: String? = null
    internal var searchLastSnapshot: JSONObject? = null
    // Calendar/day rollover/external refreshes share one serialized core
    // executor. Only the newest snapshot may reach the view tree; older queued
    // completions otherwise flash an intermediate week before the latest choice.
    internal val snapshotRefreshGate = LatestRequestGate()
    // The bottom format bar's FrameLayout host plus its two interchangeable
    // contents: the normal format controls and (while a table cell is open) the
    // cell controls that replace them, matching iOS.
    internal var formatBarHost: FrameLayout? = null
    internal var formatBarNormalContent: View? = null
    internal var formatBarCellContent: View? = null
    // Scheme + line awaiting an image pick from the system photo chooser.
    internal var pendingImageAttach: Pair<String, Int>? = null
    // URI reads/bitmap decoding/file writes must not occupy the serialized
    // native-core queue. The executor is lazy because most sessions never
    // attach media, and is torn down with this Activity instance.
    private var imageAttachExecutor: ExecutorService? = null
    internal val imageAttachGate = LatestRequestGate()

    internal fun imageAttachExecutor(): ExecutorService = synchronized(this) {
        imageAttachExecutor ?: Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "KnotQ-image-attach")
        }.also { imageAttachExecutor = it }
    }
    internal var syncSession: SyncSession? = null
    internal var syncLoginChallenge: SyncLoginChallenge? = null
    internal var syncAuthInProgress = false
    internal var syncAccountActionInProgress = false
    internal var syncInProgress = false
    // Entitlement/status refresh is auxiliary metadata, not a CRDT sync. Keep
    // it out of syncInProgress so a slow status request cannot make the UI say
    // "Resyncing" after the actual pull has already completed.
    internal var syncStatusInProgress = false
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
    internal var pendingGoogleParentId: String? = null
    // Resumes the Google Identity authorization that is currently on screen as a
    // consent PendingIntent (see MainActivitySyncGoogle). Only one authorization
    // runs at a time — the settings rows are inert while googleAuthInProgress —
    // so a single slot is enough. It is deliberately not persisted: if the
    // activity is recreated behind the consent screen the flow is simply
    // abandoned and the user can tap connect again.
    internal var pendingGoogleAuthorizationCallback:
        ((Result<com.google.android.gms.auth.api.identity.AuthorizationResult>) -> Unit)? = null
    internal val syncPollHandler = Handler(Looper.getMainLooper())
    internal val syncPollRunnable = object : Runnable {
        override fun run() {
            if (!isUiActive()) return
            syncOnce()
            syncPollHandler.postDelayed(this, 30_000)
        }
    }
    // The initial pull must not race a newly-created WebSocket. Start the
    // socket only after that first sync has finished, so it cannot route the
    // bootstrap request through a not-yet-ready or stale connection.
    internal val syncInitialTransportRunnable = object : Runnable {
        override fun run() {
            if (!isUiActive()) return
            val session = syncSession
            when {
                session == null || !session.supportsSync -> Unit
                syncInProgress -> syncPollHandler.postDelayed(this, 50)
                else -> {
                    startWsSync { startWsNudge() }
                }
            }
        }
    }
    // Subscription lifecycle is auxiliary UI state. Run it after the initial
    // CRDT sync instead of racing/serializing ahead of it on every onStart.
    internal val syncStatusRunnable = Runnable {
        if (isUiActive() && syncSession != null && !syncInProgress) refreshSubscriptionStatus()
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
            if (!isUiActive()) return
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
            if (!isUiActive()) return
            syncGoogleCalendars(silent = true)
            googleSyncHandler.postDelayed(this, GOOGLE_SYNC_INTERVAL_MS)
        }
    }
    // Debounce foreground notification rescheduling: a burst of sync pulls / edits
    // would otherwise re-arm the same OS schedule on every change. Leading-window
    // (like syncEditRunnable): the first call applies immediately, further calls
    // inside the window collapse into one trailing apply. The background worker
    // calls MobileNotificationScheduler.reschedule directly and is not throttled.
    internal val notifRescheduleHandler = Handler(Looper.getMainLooper())
    internal var notifRescheduleCooldown = false
    internal var notifReschedulePending = false
    internal val resendCooldownHandler = Handler(Looper.getMainLooper())
    internal var resendCooldownRunnable: Runnable? = null
    // Set while a reschedule is running off the main thread, so two of them can
    // never register alarms over each other.
    internal var notifRescheduleRunning = false

    companion object {
        private const val STATE_SELECTED_TAB = "knotq.state.selected_tab"
        private const val STATE_SELECTED_DATE = "knotq.state.selected_date"
        private const val STATE_WEEK_OFFSET = "knotq.state.week_offset"
        private const val STATE_SELECTED_SCHEME_ID = "knotq.state.selected_scheme_id"
        private const val STATE_SCHEME_RETURN_TAB = "knotq.state.scheme_return_tab"
        private const val STATE_CALENDAR_SCROLL_Y = "knotq.state.calendar_scroll_y"
        private const val STATE_CALENDAR_SCROLL_DATE = "knotq.state.calendar_scroll_date"
        private const val STATE_COLLAPSED_FOLDER_IDS = "knotq.state.collapsed_folder_ids"
        private const val STATE_SETTINGS_ARCHIVE = "knotq.state.settings_archive"
        private const val STATE_SETTINGS_TIMING = "knotq.state.settings_timing"
        private const val STATE_SETTINGS_GOOGLE = "knotq.state.settings_google"
        private const val STATE_DAILY_HISTORY_DAYS = "knotq.state.daily_history_days"

        // The background sync worker runs in this process: it reuses the live
        // bridge when the activity exists (two open cores would clobber each
        // other's in-memory workspace) and skips work while in the foreground.
        @Volatile internal var sharedBridge: RustBridge? = null
        // Prevent a background worker from opening a second MobileCore during
        // the short window where this Activity has stopped but its cold-start
        // bridge is still being constructed on the core executor.
        @Volatile internal var bridgeStartupInProgress = false

        // The live activity, so out-of-UI state changes (a "Done"/snooze tapped on
        // a notification, handled in NotificationReceiver) can refresh it.
        internal val liveActivity = LiveInstanceGate<MainActivity>()

        /** True only when the currently published Activity is foregrounded. */
        fun hasForegroundActivity(): Boolean =
            liveActivity.current()?.activityForeground == true

        /**
         * Return the Activity that actually owns [sharedBridge]. During fast
         * recreation the live Activity can briefly be the replacement while
         * the old instance is still closing its bridge; callers must not pair
         * that old handle with the replacement's executor.
         */
        fun sharedBridgeOwner(): MainActivity? {
            val activity = liveActivity.current() ?: return null
            val bridge = sharedBridge ?: return null
            return activity.takeIf { it.ownsBridge(bridge) }
        }

        /**
         * The static flag is kept for the no-Activity cold-start window, but a
         * live Activity is authoritative during recreation. The old instance's
         * onDestroy must not clear the replacement's startup guard.
         */
        fun hasBridgeStartupInProgress(): Boolean =
            liveActivity.current()?.bridgeStartupPending == true || bridgeStartupInProgress

        // Set when the core was mutated from outside the UI. Consumed either
        // immediately (activity in the foreground) or at the next onStart, so a
        // change made while the app sat backgrounded is picked up on return
        // instead of leaving a completed item on screen until the next launch.
        @Volatile private var externalRefreshPending = false

        /// Call after mutating the core from outside the activity's own UI flow.
        /// Safe from any thread, and safe when no activity exists (a receiver can
        /// run with the app never having been opened) — the flag then simply has
        /// no one to apply to, and the next launch reads the fresh state anyway.
        fun notifyExternalStateChanged() {
            externalRefreshPending = true
            val activity = liveActivity.current() ?: return
            activity.runOnUiThread { activity.consumeExternalRefresh() }
        }
    }

    /// Rebuild the snapshot + UI if something outside the activity changed the
    /// core. No-ops when nothing is pending, or while the activity is stopped
    /// (onStart re-runs it), or before the bridge exists. Returns whether it
    /// actually refreshed, so a caller that would otherwise refresh anyway can
    /// skip a second rebuild.
    internal fun consumeExternalRefresh(): Boolean {
        if (!externalRefreshPending) return false
        if (!isUiActive()) return false
        if (!::bridge.isInitialized) return false
        if (hasFocusedEditableField()) {
            renderDeferredWhileEditing = true
            return false
        }
        externalRefreshPending = false
        refreshSnapshotAsync(
            onFailure = { externalRefreshPending = true },
        )
        return true
    }

    /**
     * Core work can finish after onStop/onDestroy. Only these callbacks may
     * publish UI state or show a dialog; stopped/dead Activities discard the
     * result and let the next foreground refresh load the durable state.
     */
    // The live-instance identity rejects completions from an older Activity
    // during recreation, while `activityForeground` rejects callbacks after
    // this instance's onStop without allowing the old instance to affect the
    // replacement's state.
    internal fun isLiveActivity(): Boolean =
        liveActivity.isCurrent(this) && !isFinishing && !isDestroyed

    internal fun ownsBridge(candidate: RustBridge): Boolean =
        ::bridge.isInitialized && bridge === candidate

    internal fun isUiActive(): Boolean =
        isLiveActivity() && activityForeground && ::rootFrame.isInitialized

    internal val purchasesUpdatedListener = PurchasesUpdatedListener { result, purchases ->
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val purchase = purchases?.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                if (purchase != null) {
                    verifyGooglePlayPurchase(purchase)
                } else {
                    runOnUiThread {
                        if (!isUiActive()) return@runOnUiThread
                        purchaseInProgress = false
                        requestRender()
                    }
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED ->
                runOnUiThread {
                    if (!isUiActive()) return@runOnUiThread
                    purchaseInProgress = false
                    requestRender()
                }
            else -> runOnUiThread {
                if (!isUiActive()) return@runOnUiThread
                purchaseInProgress = false
                requestRender()
                showError("Purchase failed", result.debugMessage.ifEmpty { "Could not complete the purchase." })
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before super.onCreate(). Holding the OS splash (background
        // set to match UiTheme.light/dark.bgApp; see Theme.App.Starting) until
        // the workspace publishes its first frame turns what used to be two
        // visibly different loading screens back to back -- the system splash,
        // then this Activity's own "Loading workspace..." shell -- into one
        // continuous screen for the common (fast) cold start. The old shell in
        // renderStartupLoading() is left in place as the fallback for whatever
        // the system does not let this condition hold indefinitely.
        val splashScreen = installSplashScreen()
        splashScreen.setKeepOnScreenCondition { !workspaceUiPublished }
        super.onCreate(savedInstanceState)
        restoreActivityState(savedInstanceState)
        // Treat the Activity as foreground from the start of construction. A
        // WorkManager job can be delivered while the splash screen is still up;
        // publishing this state before opening the core prevents that job from
        // opening a second MobileCore against the same on-disk workspace.
        activityForeground = true
        try {
            // Build a lightweight local shell immediately. Native loading,
            // snapshot expansion, fixture seeding, and daily-queue creation all
            // happen asynchronously, so a cold process never blocks the first
            // Activity frame on JNA or the native core lock.
            applyTheme()
            buildShell()
            renderStartupLoading()
            liveActivity.publish(this)
            startBridgeForStartup(intent?.data)
        } catch (error: Throwable) {
            activityForeground = false
            theme = UiTheme.dark
            showFatal(error.message)
        }
    }

    /**
     * Keep route state across rotation/recreation without serializing the
     * workspace snapshot into Android's saved-state bundle. The snapshot is
     * authoritative on disk/native; only the small presentation checkpoint is
     * restored here, then validated when that snapshot is published.
     */
    private fun restoreActivityState(state: Bundle?) {
        if (state == null) return
        selectedTab = when (state.getInt(STATE_SELECTED_TAB, TAB_HOME)) {
            TAB_HOME, TAB_CALENDAR, TAB_SCHEMES, TAB_DAILY, TAB_SEARCH, TAB_SETTINGS ->
                state.getInt(STATE_SELECTED_TAB, TAB_HOME)
            else -> TAB_HOME
        }
        selectedDate = state.getString(STATE_SELECTED_DATE)?.let {
            runCatching { LocalDate.parse(it) }.getOrNull()
        } ?: selectedDate
        weekOffset = state.getInt(STATE_WEEK_OFFSET, 0).coerceIn(-520, 520)
        selectedSchemeId = state.getString(STATE_SELECTED_SCHEME_ID)?.takeIf { it.isNotBlank() }
        schemeReturnTab = when (state.getInt(STATE_SCHEME_RETURN_TAB, TAB_HOME)) {
            TAB_HOME, TAB_CALENDAR, TAB_DAILY -> state.getInt(STATE_SCHEME_RETURN_TAB, TAB_HOME)
            else -> TAB_HOME
        }
        calendarScrollY = state.getInt(STATE_CALENDAR_SCROLL_Y, 0).coerceAtLeast(0)
        calendarScrollDate = state.getString(STATE_CALENDAR_SCROLL_DATE)
        collapsedFolderIds.clear()
        state.getStringArrayList(STATE_COLLAPSED_FOLDER_IDS)
            ?.filter { it.isNotBlank() }
            ?.let(collapsedFolderIds::addAll)
        settingsShowingArchive = state.getBoolean(STATE_SETTINGS_ARCHIVE, false)
        settingsShowingTiming = state.getBoolean(STATE_SETTINGS_TIMING, false)
        settingsShowingGoogle = state.getBoolean(STATE_SETTINGS_GOOGLE, false)
        dailyHistoryDays = state.getInt(STATE_DAILY_HISTORY_DAYS, dailyHistoryDays)
            .coerceIn(3, 3_650)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt(STATE_SELECTED_TAB, selectedTab)
        outState.putString(STATE_SELECTED_DATE, selectedDate.toString())
        outState.putInt(STATE_WEEK_OFFSET, weekOffset)
        outState.putString(STATE_SELECTED_SCHEME_ID, selectedSchemeId)
        outState.putInt(STATE_SCHEME_RETURN_TAB, schemeReturnTab)
        outState.putInt(STATE_CALENDAR_SCROLL_Y, calendarScrollY)
        outState.putString(STATE_CALENDAR_SCROLL_DATE, calendarScrollDate)
        outState.putStringArrayList(STATE_COLLAPSED_FOLDER_IDS, ArrayList(collapsedFolderIds))
        outState.putBoolean(STATE_SETTINGS_ARCHIVE, settingsShowingArchive)
        outState.putBoolean(STATE_SETTINGS_TIMING, settingsShowingTiming)
        outState.putBoolean(STATE_SETTINGS_GOOGLE, settingsShowingGoogle)
        outState.putInt(STATE_DAILY_HISTORY_DAYS, dailyHistoryDays)
        super.onSaveInstanceState(outState)
    }

    private fun startBridgeForStartup(incomingAuthIntent: Uri?) {
        if (bridgeStartupPending || ::bridge.isInitialized) return
        bridgeStartupPending = true
        bridgeStartupInProgress = true
        coreExecutor.execute {
            // UniFFI/JNA registration is native startup work too. Keep locale
            // initialization beside RustBridge construction so onCreate can
            // publish the first shell without entering the native library.
            val result = runCatching {
                // Activity recreation can publish the replacement before the
                // previous instance's closeAfter finalizer has cleared the
                // process-wide bridge. Wait off the UI thread so two native
                // cores never observe and overwrite the same workspace.
                awaitPreviousBridgeRelease()
                setLocale(java.util.Locale.getDefault().toLanguageTag())
                RustBridge(applicationContext)
            }
            runOnUiThread {
                bridgeStartupPending = false
                bridgeStartupInProgress = false
                result.onSuccess { opened ->
                    // A destroyed Activity can still receive the executor's
                    // completion after shutdown. Do not publish a bridge that
                    // no live Activity can own; close it on this path instead.
                    if (!isLiveActivity()) {
                        opened.close()
                        return@onSuccess
                    }
                    bridge = opened
                    // Publish the one live core before any snapshot work.
                    // BackgroundSyncWorker reuses this handle while the Activity
                    // is alive instead of opening a second core over the same
                    // on-disk workspace.
                    sharedBridge = opened
                    syncSession = loadSyncSession()
                    // onNewIntent may have delivered an auth callback while
                    // native loading was still in flight; preserve that newer
                    // URI instead of replacing it with the launch-time null.
                    loadWorkspaceForStartup(pendingStartupAuthIntent ?: incomingAuthIntent)
                }.onFailure { error ->
                    if (isUiActive()) {
                        theme = UiTheme.dark
                        showFatal(error.message)
                    }
                }
            }
        }
    }

    /**
     * Wait for an older Activity's queued native teardown before opening this
     * instance's bridge. The old executor owns the close, so waiting here is
     * safe and keeps the UI shell responsive. A stuck teardown becomes a
     * visible startup failure instead of silently opening a second core.
     */
    private fun awaitPreviousBridgeRelease() {
        val deadline = System.nanoTime() + 15_000_000_000L
        while (sharedBridge != null) {
            if (System.nanoTime() >= deadline) {
                error("Timed out waiting for the previous KnotQ core to close")
            }
            try {
                Thread.sleep(10)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IllegalStateException("Interrupted while waiting for the previous KnotQ core", interrupted)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        activityForeground = true
        if (!::bridge.isInitialized || !workspaceReady) return
        if (!workspaceUiPublished) {
            scheduleWorkspaceUiPublication()
            return
        }
        finishWorkspaceStart()
    }

    private fun scheduleWorkspaceUiPublication() {
        if (!workspaceReady || workspaceUiPublished || workspaceRenderPending || !isUiActive()) return
        workspaceRenderPending = true
        val runnable = Runnable {
            workspaceRenderRunnable = null
            workspaceRenderPending = false
            if (!isUiActive() || !workspaceReady || workspaceUiPublished) return@Runnable
            // Select the first onboarding destination before building the real
            // tree. Otherwise the first-run guide would render Home and then
            // immediately tear it down to show Schemes, causing an avoidable
            // flash and another synchronous view-tree build.
            if (!startupSeededScreenshotFixture) maybeStartOnboarding(renderUi = false)
            applyTheme()
            render()
            workspaceUiPublished = true
            // Let the first complete workspace frame reach the window before
            // adding onboarding's software-layer scrim/card and kicking off
            // notification/sync startup. On a slow renderer, doing all three
            // in this same turn can leave the window waiting for focus while
            // Android is still uploading the newly-built view tree.
            rootFrame.postOnAnimation {
                if (!isUiActive()) return@postOnAnimation
                if (onboardingActive) showOnboardingOverlay()
                finishWorkspaceStart(initialPublication = true)
            }
        }
        workspaceRenderRunnable = runnable
        // Let the already-visible loading shell receive one complete frame
        // before replacing its subtree. A fixed quarter-second delay made cold
        // startup feel sluggish on fast devices without adding protection; the
        // next-vsync callback preserves the frame boundary without idle time.
        rootFrame.postOnAnimation(runnable)
    }

    private fun finishWorkspaceStart(initialPublication: Boolean = false) {
        if (!workspaceUiPublished || !isUiActive()) return
        // The startup snapshot was read for the current zone. Treat that zone
        // as observed before onResume can schedule a duplicate refresh.
        lastObservedTimeZoneId = ZoneId.systemDefault().id
        maybeStartOnboarding()
        if (BuildConfig.ACCOUNTS_ENABLED) {
            // Loading the local session is cheap, but Firebase/FCM is not. A
            // local-first user without a sync entitlement has no reason to
            // initialize the messaging stack during launch.
            syncSession = loadSyncSession()
        }
        if (!startupEffectsApplied) {
            if (!startupSeededScreenshotFixture && !onboardingActive) {
                scheduleNotificationPermissionRequest()
            }
            rescheduleNotifications()
            if (BuildConfig.ACCOUNTS_ENABLED) {
                if (syncSession?.supportsSync == true) registerForPushNotifications()
                // An auth callback may be the event that creates the session,
                // so it must still be handled when the pre-launch session was
                // empty.
                handleIncomingAuthIntent(pendingStartupAuthIntent)
                pendingStartupAuthIntent = null
            }
            startupEffectsApplied = true
        }
        // Pick up a core mutation made while backgrounded — notably a "Done" or
        // snooze tapped on a notification, which NotificationReceiver applies in
        // this process without the (stopped) activity noticing.
        val externalRefreshConsumed = consumeExternalRefresh()
        if (shouldRefreshTimeDerivedSnapshot(
                initialPublication = initialPublication,
                externalRefreshConsumed = externalRefreshConsumed,
                editorFocused = hasFocusedEditableField(),
            )
        ) {
            // Nothing changed the data, but time passed: the snapshot on screen was
            // built when the app was last foregrounded and the core buckets
            // occurrences against that moment, so returning hours later leaves items
            // that are now overdue sitting under Upcoming. Skipped while an editor
            // holds focus — render() rebuilds the shell and would drop the caret
            // along with any not-yet-flushed typing.
            // The cached tree is already on screen. Let the asynchronous snapshot
            // completion request the one redraw that reflects any time-based
            // occurrence changes; scheduling a redraw here too needlessly tears
            // down and rebuilds the whole home tree.
            refreshSnapshotAsync()
        }
        // The app may have been backgrounded across midnight; roll the daily/home
        // "today" forward so it isn't stuck on yesterday.
        handleDayRolloverIfNeeded()

        // Render the cached local workspace before starting sync. `syncOnce()`
        // runs on a worker thread, but the native core is mutex-protected; if it
        // starts first, the snapshot above would wait behind a large catch-up
        // pull and make a cold launch look hung (and can trip Android's ANR
        // watchdog). The cached workspace is already durable, so it is safe to
        // show it while the worker reconciles remote changes; its completion
        // callback reloads the snapshot and refreshes the UI.
        if (BuildConfig.ACCOUNTS_ENABLED) startSyncPolling()
        configureGoogleSyncPolling()
    }

    private fun loadWorkspaceForStartup(incomingAuthIntent: Uri?) {
        pendingStartupAuthIntent = incomingAuthIntent
        coreExecutor.execute {
            val result = runCatching {
                val seededScreenshotFixture = seedScreenshotFixtureIfRequested()
                // The loaded snapshot below is the one publication boundary;
                // do not make daily-queue creation expand the entire workspace
                // once and then immediately expand it again here.
                ensureTodayDailyQueue(refreshSnapshot = false)
                val loaded = snapshotFromCore()
                seededScreenshotFixture to loaded
            }
            runOnUiThread {
                if (!isLiveActivity()) return@runOnUiThread
                result.onSuccess { (seededScreenshotFixture, loaded) ->
                    snapshot = loaded
                    // Search text and transient dialogs are intentionally not
                    // persisted; restore a stable Home route instead of
                    // recreating an empty search shell. Likewise, a deleted
                    // scheme must never leave recreation pointing at a blank
                    // editor page.
                    if (selectedTab == TAB_SEARCH) selectedTab = TAB_HOME
                    val restoredSchemeId = selectedSchemeId
                    if (selectedTab == TAB_SCHEMES &&
                        restoredSchemeId != null &&
                        findScheme(restoredSchemeId) == null
                    ) {
                        selectedSchemeId = null
                        selectedTab = TAB_HOME
                    }
                    if (selectedTab != TAB_SETTINGS) {
                        settingsShowingArchive = false
                        settingsShowingTiming = false
                        settingsShowingGoogle = false
                    }
                    workspaceReady = true
                    startupSeededScreenshotFixture = seededScreenshotFixture
                    // The durable snapshot is still useful when the Activity
                    // stopped while startup work was running, but rebuilding
                    // the stopped view tree (or prompting for permission) is
                    // unnecessary. onStart will publish it when visible.
                    if (!activityForeground) return@onSuccess
                    scheduleWorkspaceUiPublication()
                }.onFailure { error ->
                    if (isUiActive()) {
                        theme = UiTheme.dark
                        showFatal(error.message)
                    }
                }
            }
        }
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
        mutate(obj("type" to "ensure_daily_queue", "date" to today.toString()))
    }

    override fun onResume() {
        super.onResume()
        if (!::bridge.isInitialized) return
        if (workspaceUiPublished && timeZoneChangedSinceLastResume()) {
            refreshSnapshotAsync()
        }
        maybeRequestStoreReview()
    }

    internal fun timeZoneChangedSinceLastResume(): Boolean {
        val current = ZoneId.systemDefault().id
        if (current == lastObservedTimeZoneId) return false
        lastObservedTimeZoneId = current
        return true
    }

    override fun onStop() {
        activityForeground = false
        cancelContentTransition()
        pendingContentTransition = null
        pendingContentTransitionRender = false
        calendarGestureActive = false
        renderDeferredWhileCalendarGesture = false
        suppressEditorBlurCommit = false
        editorMutationGeneration++
        if (::rootFrame.isInitialized) {
            rootFrame.removeCallbacks(renderRequestRunnable)
            renderRequestPending = false
        }
        // Search is view-scoped. Drop a pending debounce when the view leaves
        // the foreground instead of spending core time on a result nobody can
        // see; the serial also invalidates an already-running result.
        searchRequestSerial++
        searchRequestRunnable?.let(syncPollHandler::removeCallbacks)
        searchRequestRunnable = null
        searchLastQuery = null
        searchLastSnapshot = null
        val flushEditSync = if (BuildConfig.ACCOUNTS_ENABLED) syncEditPending else false
        if (BuildConfig.ACCOUNTS_ENABLED) {
            syncPollHandler.removeCallbacks(syncPollRunnable)
            syncPollHandler.removeCallbacks(syncInitialTransportRunnable)
            syncPollHandler.removeCallbacks(syncStatusRunnable)
            stopWsNudge()
            syncPollHandler.removeCallbacks(syncEditRunnable)
            syncEditPending = false
        }
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        googleSyncPollingActive = false
        if (::bridge.isInitialized) {
            // Apply a reschedule the debounce deferred — the trailing runnable may
            // never run once the process is cached/frozen, which would leave the
            // alarms armed from a now-stale schedule.
            if (notifReschedulePending) {
                notifReschedulePending = false
                rescheduleNotificationsNow()
            }
            if (BuildConfig.ACCOUNTS_ENABLED) {
                // Mirror iOS applicationDidEnterBackground: keep workspace data fresh
                // via periodic background refresh while signed in to sync.
                scheduleBackgroundSyncWork()
                if (flushEditSync) {
                    // A debounced edit hadn't pushed yet. Push it over the live
                    // socket first, then tear the socket down. The one-off worker is
                    // the durable fallback.
                    flushEditsOverWsThenStop()
                    enqueueOneTimeSync(this)
                } else {
                    stopWsSync()
                }
            }
        } else if (BuildConfig.ACCOUNTS_ENABLED) {
            stopWsSync()
        }
        super.onStop()
    }

    override fun onDestroy() {
        activityForeground = false
        activeMonthPickerDialog?.dismiss()
        activeMonthPickerDialog = null
        cancelContentTransition()
        pendingContentTransition = null
        pendingContentTransitionRender = false
        calendarGestureActive = false
        renderDeferredWhileCalendarGesture = false
        searchRequestSerial++
        searchRequestRunnable?.let(syncPollHandler::removeCallbacks)
        searchRequestRunnable = null
        searchLastQuery = null
        searchLastSnapshot = null
        if (::rootFrame.isInitialized) {
            rootFrame.removeCallbacks(renderRequestRunnable)
            workspaceRenderRunnable?.let(rootFrame::removeCallbacks)
            notificationPermissionRunnable?.let(rootFrame::removeCallbacks)
            notificationPermissionRunnable = null
            notificationPermissionDeferred = false
            workspaceRenderRunnable = null
            workspaceRenderPending = false
        }
        if (BuildConfig.ACCOUNTS_ENABLED) {
            syncPollHandler.removeCallbacks(syncPollRunnable)
            syncPollHandler.removeCallbacks(syncInitialTransportRunnable)
            syncPollHandler.removeCallbacks(syncStatusRunnable)
            syncPollHandler.removeCallbacks(syncEditRunnable)
            syncEditPending = false
            stopWsNudge()
            stopWsSync()
        }
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        notifRescheduleHandler.removeCallbacksAndMessages(null)
        resendCooldownRunnable?.let(resendCooldownHandler::removeCallbacks)
        resendCooldownRunnable = null
        editorFlushRunnable?.let(syncPollHandler::removeCallbacks)
        editorFlushRunnable = null
        synchronized(this) {
            imageAttachExecutor?.shutdownNow()
            imageAttachExecutor = null
        }
        if (BuildConfig.ACCOUNTS_ENABLED) {
            billingClient?.endConnection()
            billingClient = null
        }
        // A replacement Activity may already be live. Only the current
        // instance may clear the process-wide startup guard; otherwise an old
        // recreation can make a worker open a second core during the new
        // instance's startup window.
        if (liveActivity.isCurrent(this)) {
            bridgeStartupInProgress = false
        }
        if (::bridge.isInitialized) {
            // Native requests may already be queued (notably ws_stop and a
            // final edit flush). Close the bridge only after that FIFO work has
            // finished; closing it inline races in-flight JNA calls during fast
            // Activity recreation. Keep the static bridge/live-instance markers
            // until the finalizer runs: a WorkManager or notification callback
            // must see the closing core and queue/retry, never open a second
            // MobileCore over the same on-disk workspace.
            val closingBridge = bridge
            coreExecutor.closeAfter {
                try {
                    closingBridge.close()
                } finally {
                    if (sharedBridge === closingBridge) sharedBridge = null
                    liveActivity.clearIfCurrent(this)
                }
            }
        } else {
            if (liveActivity.isCurrent(this)) {
                sharedBridge = null
                liveActivity.clearIfCurrent(this)
            }
            coreExecutor.close()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (BuildConfig.ACCOUNTS_ENABLED) {
            if (::bridge.isInitialized) {
                handleIncomingAuthIntent(intent?.data)
            } else {
                pendingStartupAuthIntent = intent?.data
            }
        }
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
                if (!isUiActive()) return@addOnCompleteListener
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
        if (selectedTab == TAB_SETTINGS) {
            if (settingsShowingArchive || settingsShowingTiming || settingsShowingGoogle) {
                settingsShowingArchive = false
                settingsShowingTiming = false
                settingsShowingGoogle = false
            } else {
                // Settings is a pushed mobile route, not a second Activity.
                // System Back must return to the stable Home shell instead of
                // finishing the Activity (especially in the wide navigator,
                // where Settings is opened from the side rail).
                selectedTab = TAB_HOME
                selectedSchemeId = null
            }
            queueContentTransition(ContentTransitionDirection.BACKWARD)
            render()
            return
        }
        if (selectedTab == TAB_SCHEMES && selectedSchemeId != null) {
            val schemeId = selectedSchemeId
            activeEditor()?.let { editor ->
                if (schemeId != null) {
                    // A no-op Back still commits through the serial core path,
                    // but it does not need a second render. Compare against the
                    // snapshot currently on screen so repeated open/back taps
                    // cannot publish late no-op frames after a later render.
                    val (_, nextLines) = buildSchemeItemsPayload(schemeId, editor)
                    val visibleLines = findScheme(schemeId)?.let(::documentLines)
                    val destinationNeedsRefresh = visibleLines == null || visibleLines != nextLines
                    commitSchemeDocument(schemeId, editor, rerender = false) {
                        if (destinationNeedsRefresh) requestRenderAfterContentTransition()
                    }
                }
            }
            exitSchemeEditor()
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
        renderedTitleBarSignature = null
        renderedDockSignature = null
        shell = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        titleBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(10), 0)
            setBackgroundColor(theme.bgToolbar)
            // Keep the legacy host around for compatibility with the render
            // state/tests, but never put a desktop toolbar above the content.
            // The mobile shell uses in-content actions and the iOS-style
            // navigator/dock instead; hiding it here also prevents a one-frame
            // toolbar flash while the workspace is loading or rotating.
            visibility = View.GONE
        }
        content = FrameLayout(this).apply {
            setBackgroundColor(theme.bgApp)
        }
        dock = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(6), dp(5), dp(6), dp(5))
        }

        // The legacy title bar is intentionally not attached at all. Keeping a
        // GONE toolbar in the shell would normally cost little, but an attached
        // chrome host can still participate in visibility/layout callbacks
        // during rotation and is an unnecessary place for a stale control to
        // flash. The mobile shell owns its actions in content and the dock.
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        // Host the shell inside a root frame so the onboarding overlay can sit on
        // top of (and survive) `render()`, which only rebuilds the shell's children.
        rootFrame = LayoutTransactionFrameLayout(this).apply {
            setBackgroundColor(theme.bgApp)
        }
        rootFrame.addView(shell, FrameLayout.LayoutParams(-1, -1))
        setContentView(rootFrame)
        installSafeAreaInsets()
        installKeyboardVisibilityWatcher()
    }

    internal fun render() {
        if (!::content.isInitialized) return
        if (!::rootFrame.isInitialized) {
            renderingMainTree = true
            try {
                renderNow()
            } finally {
                renderingMainTree = false
            }
            return
        }
        // A render replaces several sibling subtrees. Suppress layout while the
        // replacement is assembled so Android cannot measure/draw an intermediate
        // state (which otherwise presents as a one-frame blank or flicker on
        // slower devices). The final requestLayout publishes one coherent tree.
        setRootLayoutSuppressed(true)
        val layoutChanged = try {
            renderingMainTree = true
            renderNow()
        } finally {
            renderingMainTree = false
            setRootLayoutSuppressed(false)
        }
        if (layoutChanged) rootFrame.requestLayout()
    }

    private fun renderNow(): Boolean {
        if (!::content.isInitialized) return false
        if (::rootFrame.isInitialized) {
            rootFrame.removeCallbacks(renderRequestRunnable)
            renderRequestPending = false
        }
        renderDeferredWhileEditing = false
        if (lastRenderedTab != TAB_DAILY && selectedTab == TAB_DAILY) {
            pendingDailyAutoFocusDate = selectedDate.toString()
        }
        lastRenderedTab = selectedTab
        // The whole view tree (including any floating inline cell editor) is
        // rebuilt below; drop the stale reference without re-committing.
        activeCellEdit = null
        val previousTheme = if (::theme.isInitialized) theme else null
        applyTheme()
        val themeChanged = previousTheme != theme
        if (themeChanged) {
            rootFrame.setBackgroundColor(theme.bgApp)
            shell.setBackgroundColor(theme.bgApp)
            titleBar.setBackgroundColor(theme.bgToolbar)
            content.setBackgroundColor(theme.bgApp)
        }
        applySafeAreaPadding()

        val wide = isWideLayout()
        // Both phone and wide layouts use the same mobile chrome. In particular,
        // do not resurrect the old desktop toolbar after a rotation; rebuilding
        // hidden children would also create avoidable measure/draw work.
        if (titleBar.visibility != View.GONE) titleBar.visibility = View.GONE
        if (titleBar.childCount != 0) titleBar.removeAllViews()
        renderedTitleBarSignature = null
        val showPhoneDock = shouldShowPhoneDock()
        val showPhoneQuickActions = shouldShowPhoneQuickActions()
        val routeScope = contentRenderRouteScope(selectedTab)
        val contentState = ContentRenderState(
            selectedTab = selectedTab,
            selectedSchemeId = selectedSchemeId,
            selectedDate = selectedDate,
            weekOffset = weekOffset,
            wide = wide,
            theme = theme,
            settingsShowingArchive = routeScope.settings && settingsShowingArchive,
            settingsShowingTiming = routeScope.settings && settingsShowingTiming,
            settingsShowingGoogle = routeScope.settings && settingsShowingGoogle,
            // These pending values are one-shot route inputs. Ignoring them on
            // unrelated routes prevents a background preparation step from
            // rebuilding the visible Home/Calendar tree.
            dailyHistoryDays = if (routeScope.settings || routeScope.daily) dailyHistoryDays else 0,
            // Keep the actual immutable set in the signature instead of only
            // its hash. A hash collision must never leave a stale navigator
            // visible after a folder is expanded/collapsed.
            collapsedFolderIds = collapsedFolderIds.toSet(),
            pendingDailyAnchorDate = pendingDailyAnchorDate.takeIf { routeScope.daily },
            pendingDailyAutoFocusDate = pendingDailyAutoFocusDate.takeIf { routeScope.daily },
            pendingTitleFocusSchemeId = pendingTitleFocusSchemeId.takeIf { routeScope.schemes },
            keyboardActive = keyboardActive,
            showPhoneDock = showPhoneDock,
            showPhoneQuickActions = showPhoneQuickActions,
            // Account/sync/Google status is visible only under Settings. Keep
            // stable neutral values elsewhere so a status poll cannot detach
            // the active editor, calendar, or search tree.
            settingsAccountEmail = if (routeScope.settings) syncSession?.email.orEmpty() else "",
            settingsAccountSupportsSync = if (routeScope.settings) syncSession?.supportsSync else null,
            settingsSyncOffline = routeScope.settings && syncOffline,
            settingsSyncInProgress = routeScope.settings && syncInProgress,
            settingsSubscriptionCancelled = routeScope.settings && syncSubscriptionCancelled,
            settingsEmailVerified = if (routeScope.settings) syncEmailVerified else null,
            settingsResendInProgress = routeScope.settings && resendVerificationInProgress,
            settingsResendCooldown = if (routeScope.settings) resendVerificationCooldown else 0,
            settingsPurchaseInProgress = routeScope.settings && purchaseInProgress,
            settingsGoogleAuthInProgress = routeScope.settings && googleAuthInProgress,
            settingsGoogleSyncInProgress = routeScope.settings && googleSyncInProgress,
            settingsGoogleCalendarStatus = if (routeScope.settings) googleCalendarStatus else null,
        )
        // Search owns its query/result subtree and updates it through its own
        // debounce. Do not replace that tree merely because a background sync
        // published a new workspace snapshot; Settings and the other routes
        // still rebuild when their snapshot-backed content changes.
        val rebuildContent = shouldRebuildMainContent(
            selectedTab = selectedTab,
            snapshotChanged = renderedContentSnapshot !== snapshot,
            renderStateChanged = renderedContentState != contentState,
        )
        val transitionDirection = contentTransitionForRebuild(rebuildContent, pendingContentTransition)
        // Direction is a one-shot input even when this render does not need to
        // replace the tree. Otherwise a no-op status/search render can leave a
        // stale direction that animates a later unrelated rebuild.
        pendingContentTransition = null

        if (rebuildContent) {
            val previousMainView = activeTransitionIncomingView ?: content.getChildAt(0)
            cancelContentTransition()
            currentFocus?.clearFocus()
            content.clearFocus()
            content.removeAllViews()
            editorSchemeIds.clear()
            editorHosts.clear()
            lastActiveEditor = null
            val view = if (wide) renderWideShell() else renderPhoneMain()
            content.addView(view, FrameLayout.LayoutParams(-1, -1))
            startContentTransitionIfNeeded(previousMainView, view, transitionDirection)
            val dockSignature = DockRenderSignature(selectedTab, wide, theme)
            if (renderedDockSignature != dockSignature) {
                renderDock()
                renderedDockSignature = dockSignature
            }
            if (showPhoneQuickActions) {
                content.addView(homeFloatingActions(), FrameLayout.LayoutParams(-2, dp(58), Gravity.BOTTOM or Gravity.END).apply {
                    setMargins(0, 0, dp(22), dp(83))
                })
            }
            if (showPhoneDock) {
                content.addView(dock, FrameLayout.LayoutParams(-2, dp(58), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                    setMargins(0, 0, 0, dp(6))
                })
            }
            renderedContentSnapshot = snapshot
            renderedContentState = contentState
        }
        if (notificationPermissionDeferred && canPresentNotificationPermission()) {
            notificationPermissionDeferred = false
            scheduleNotificationPermissionRequest()
        }
        return rebuildContent || updateChromeVisibility()
    }

    private fun cancelContentTransition() {
        val incomingView = activeTransitionIncomingView
        val outgoingView = activeTransitionOutgoingView
        activeContentTransition?.cancel()
        incomingView?.translationX = 0f
        incomingView?.setLayerType(View.LAYER_TYPE_NONE, null)
        outgoingView?.translationX = 0f
        outgoingView?.setLayerType(View.LAYER_TYPE_NONE, null)
        if (outgoingView?.parent === content) content.removeView(outgoingView)
        activeContentTransition = null
        activeTransitionIncomingView = null
        activeTransitionOutgoingView = null
        if (pendingContentTransitionRender && isUiActive()) {
            pendingContentTransitionRender = false
            rootFrame.postOnAnimation {
                if (isUiActive()) requestRender()
            }
        }
    }

    internal fun queueContentTransition(direction: ContentTransitionDirection) {
        pendingContentTransition = direction
    }

    private fun startContentTransitionIfNeeded(
        previousView: View?,
        incomingView: View,
        direction: ContentTransitionDirection?,
    ) {
        if (direction == null || previousView == null || previousView === incomingView) return
        val width = content.width
        val duration = animationDuration(this, 190L)
        if (width <= 0 || duration == 0L) return

        // Keep the old page above the new one while it slides away. The old
        // page moves only a quarter-width (iOS-style parallax), while the new
        // page makes the full quick slide. Dock/floating actions are added
        // afterward and remain visually stable during the transition.
        val sign = if (direction == ContentTransitionDirection.FORWARD) 1f else -1f
        val outgoingTarget = -sign * width * 0.24f
        incomingView.translationX = sign * width.toFloat()
        previousView.translationX = 0f
        content.addView(previousView, FrameLayout.LayoutParams(-1, -1))

        // Both pages are full-tree renders (the editor's canvas-drawn markdown
        // chrome in particular), and TRANSLATION_X alone does not stop a plain
        // software view from re-running its full measure/layout/draw on every
        // animation frame. Cache each page to a GPU layer for the slide so the
        // animator is just compositing two bitmaps -- the difference between a
        // 60-110ms frame (measured via dumpsys gfxinfo) and a smooth 60fps push,
        // and how this reads as an iOS-style layer-backed transition rather than
        // a live re-render.
        previousView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        incomingView.setLayerType(View.LAYER_TYPE_HARDWARE, null)

        val animator = AnimatorSet().apply {
            playTogether(
                ObjectAnimator.ofFloat(previousView, View.TRANSLATION_X, 0f, outgoingTarget),
                ObjectAnimator.ofFloat(incomingView, View.TRANSLATION_X, sign * width.toFloat(), 0f),
            )
            this.duration = duration
            interpolator = PathInterpolator(0.18f, 0.82f, 0.24f, 1f)
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (activeContentTransition !== animation) return
                    val refreshAfterTransition = !cancelled && pendingContentTransitionRender
                    pendingContentTransitionRender = false
                    activeContentTransition = null
                    activeTransitionIncomingView = null
                    activeTransitionOutgoingView = null
                    incomingView.translationX = 0f
                    incomingView.setLayerType(View.LAYER_TYPE_NONE, null)
                    previousView.translationX = 0f
                    previousView.setLayerType(View.LAYER_TYPE_NONE, null)
                    if (!cancelled && previousView.parent === content) content.removeView(previousView)
                    if (
                        !cancelled &&
                        notificationPermissionDeferred &&
                        canPresentNotificationPermission()
                    ) {
                        notificationPermissionDeferred = false
                        scheduleNotificationPermissionRequest()
                    }
                    if (refreshAfterTransition && isUiActive()) {
                        rootFrame.postOnAnimation {
                            if (isUiActive()) requestRender()
                        }
                    }
                }
            })
        }
        activeContentTransition = animator
        activeTransitionIncomingView = incomingView
        activeTransitionOutgoingView = previousView
        animator.start()
    }

    /**
     * Requests a snapshot-backed rebuild without interrupting an active page
     * transition. This is used by the editor's asynchronous Back save.
     */
    internal fun requestRenderAfterContentTransition() {
        if (!isUiActive()) return
        if (activeContentTransition != null) {
            pendingContentTransitionRender = true
        } else {
            requestRender()
        }
    }

    /**
     * Shows one stable frame while the first native snapshot is expanding.
     * Rendering an empty Home tree here made larger workspaces flash from
     * "nothing" to their real content; a static shell keeps the transition
     * coherent without introducing a spinner animation.
     */
    internal fun renderStartupLoading() {
        if (!::content.isInitialized || !::titleBar.isInitialized) return
        val activity = this
        renderedTitleBarSignature = null
        renderedDockSignature = null
        renderedContentSnapshot = null
        renderedContentState = null
        titleBar.removeAllViews()
        content.removeAllViews()
        content.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
            addView(brandMark(52), LinearLayout.LayoutParams(dp(52), dp(52)).apply {
                setMargins(0, 0, 0, dp(18))
            })
            addView(text(L10n.t(activity, "mobile.workspace.loading"), theme.textMuted, 15f, false).apply {
                gravity = Gravity.CENTER
            })
        }, FrameLayout.LayoutParams(-1, -1))
    }

    internal fun scheduleNotificationPermissionRequest() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (!::rootFrame.isInitialized || notificationPermissionRunnable != null) return
        // A permission sheet is full-window system UI. Never place it over a
        // settings page, scheme editor, keyboard, or an active route slide;
        // defer until the user is back on the stable Home route so it cannot
        // look like the page disappeared or the transition flickered.
        if (!canPresentNotificationPermission()) {
            notificationPermissionDeferred = true
            return
        }
        val request = Runnable {
            notificationPermissionRunnable = null
            if (!canPresentNotificationPermission()) {
                notificationPermissionDeferred = true
                return@Runnable
            }
            notificationPermissionDeferred = false
            MobileNotificationScheduler.requestPermission(this)
        }
        notificationPermissionRunnable = request
        rootFrame.postDelayed(request, notificationPermissionDelayMs)
    }

    private fun canPresentNotificationPermission(): Boolean = shouldPresentNotificationPermission(
        uiActive = isUiActive(),
        onboardingActive = onboardingActive,
        workspaceUiPublished = workspaceUiPublished,
        selectedTab = selectedTab,
        selectedSchemeId = selectedSchemeId,
        contentTransitionActive = activeContentTransition != null,
        editableFieldFocused = hasFocusedEditableField(),
    )

    internal fun requestRender() {
        if (!isUiActive()) return
        // Startup intentionally publishes the cached workspace through the
        // delayed one-shot above. Background/status callbacks can arrive while
        // the loading shell is still visible; they must not pull the expensive
        // full-tree render back into that first focus transition.
        if (!workspaceUiPublished) return
        // A background status/sync update must never steal the editor focus or
        // keyboard. The focused editor is refreshed in place by the merge path;
        // defer incidental chrome changes until the user leaves it.
        if (hasFocusedEditableField()) {
            renderDeferredWhileEditing = true
            return
        }
        // A calendar swipe owns the timeline until its snap commits. A
        // snapshot callback may arrive in the middle of a rapid second swipe;
        // rebuilding the tree here would detach the timeline and cancel that
        // swipe before it reaches its adjacent day.
        if (calendarGestureActive) {
            renderDeferredWhileCalendarGesture = true
            return
        }
        if (activeContentTransition != null) {
            pendingContentTransitionRender = true
            return
        }
        renderDeferredWhileCalendarGesture = false
        if (renderRequestPending) return
        renderRequestPending = true
        rootFrame.postOnAnimation(renderRequestRunnable)
    }

    internal fun beginCalendarGesture() {
        calendarGestureActive = true
    }

    internal fun endCalendarGesture(flushDeferredRender: Boolean = false) {
        calendarGestureActive = false
        if (flushDeferredRender && renderDeferredWhileCalendarGesture) {
            // Cancellation does not start a new snapshot refresh. Flush any
            // status redraw that arrived during the gesture once the timeline
            // is stable again.
            requestRender()
        }
    }

    internal fun flushDeferredRenderAfterEditorBlur() {
        if (hasFocusedEditableField()) return
        val shouldRefreshExternalState = externalRefreshPending
        if (!renderDeferredWhileEditing && !shouldRefreshExternalState) return
        renderDeferredWhileEditing = false
        if (shouldRefreshExternalState) {
            externalRefreshPending = false
            coreExecutor.execute {
                val result = runCatching { snapshotFromCore() }
                runOnUiThread {
                    if (!isUiActive()) return@runOnUiThread
                    result.onSuccess { refreshed ->
                        snapshot = refreshed
                        configureGoogleSyncPolling()
                        rescheduleNotifications()
                        requestRender()
                    }.onFailure {
                        // Leave the flag set so onStart or a later blur can retry.
                        externalRefreshPending = true
                    }
                }
            }
            return
        }
        requestRender()
    }

    internal fun renderAfterEditorMutation() {
        val generation = ++editorMutationGeneration
        suppressEditorBlurCommit = true
        render()
        rootFrame.post {
            if (generation == editorMutationGeneration) {
                suppressEditorBlurCommit = false
            }
        }
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
                settingsShowingTiming = false
                settingsShowingGoogle = false
                if (index == TAB_CALENDAR && selectedDate != LocalDate.now()) {
                    selectedDate = LocalDate.now()
                    weekOffset = 0
                    refreshSnapshotAsync()
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                updateKeyboardVisibility(insets.isVisible(android.view.WindowInsets.Type.ime()))
            }
            insets
        }
        rootFrame.requestApplyInsets()
        applySafeAreaPadding()
    }

    internal fun applySafeAreaPadding() {
        if (!::shell.isInitialized) return
        // `render()` runs for snapshot/status changes that do not affect the
        // window insets. Avoid calling setPadding with the same values: Android
        // treats it as a layout-affecting mutation and can schedule an extra
        // measure/draw pass in the middle of a large tree rebuild.
        if (
            shell.paddingLeft == 0 &&
            shell.paddingTop == safeAreaTop &&
            shell.paddingRight == 0 &&
            shell.paddingBottom == safeAreaBottom
        ) return
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
        queueContentTransition(ContentTransitionDirection.BACKWARD)
        render()
    }

    internal fun installKeyboardVisibilityWatcher() {
        // API 30+ reports IME visibility through WindowInsets. Avoid a global
        // layout listener there: it allocates a Rect and runs for every measure
        // pass, including the large tree rebuilds that follow a sync refresh.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) return
        shell.viewTreeObserver.addOnGlobalLayoutListener {
            if (!::shell.isInitialized) return@addOnGlobalLayoutListener
            val frame = Rect()
            shell.getWindowVisibleDisplayFrame(frame)
            val height = shell.rootView.height
            if (height <= 0) return@addOnGlobalLayoutListener
            val hidden = height - frame.bottom
            updateKeyboardVisibility(hidden > height * 0.15f)
        }
    }

    private fun updateKeyboardVisibility(next: Boolean) {
        if (keyboardActive == next) return
        keyboardActive = next
        updateChromeVisibility()
    }

    internal fun updateChromeVisibility(): Boolean {
        if (!::titleBar.isInitialized || !::dock.isInitialized) return false
        val titleVisibility = View.GONE
        val dockVisibility = if (shouldShowPhoneDock()) View.VISIBLE else View.GONE
        val ownLayoutTransaction =
            ::rootFrame.isInitialized &&
                !renderingMainTree
        if (ownLayoutTransaction) setRootLayoutSuppressed(true)
        var changed = false
        try {
            if (titleBar.visibility != titleVisibility) {
                titleBar.visibility = titleVisibility
                changed = true
            }
            if (dock.visibility != dockVisibility) {
                dock.visibility = dockVisibility
                changed = true
            }
        } finally {
            if (ownLayoutTransaction) {
                setRootLayoutSuppressed(false)
                if (changed) rootFrame.requestLayout()
            }
        }
        return changed
    }

    private fun setRootLayoutSuppressed(suppressed: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            rootFrame.suppressLayout(suppressed)
        } else {
            (rootFrame as? LayoutTransactionFrameLayout)?.setKnotQLayoutSuppressed(suppressed)
        }
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
        if (requestCode == REQUEST_GOOGLE_AUTHORIZE) {
            onGoogleAuthorizationResult(resultCode, data)
            return
        }
        if (requestCode == REQUEST_GOOGLE_CHOOSE_ACCOUNT) {
            onGoogleAccountChosen(resultCode, data)
            return
        }
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
        private val connectorRect = RectF()
        private val circleRect = RectF()

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
                circleRect.set(left, pillTop, left + circleSize, pillTop + circleSize)
                paint.color = if (date == LocalDate.now()) calendarDayHighlightColor() else calendarWeekSecondaryHighlightColor()
                canvas.drawOval(circleRect, paint)
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
            val upperY = pillTop + pillHeight * 0.29f
            val lowerY = pillTop + pillHeight * 0.71f - barHeight
            connectorRect.set(x, upperY, x + connectorWidth, upperY + barHeight)
            canvas.drawRoundRect(connectorRect, barHeight / 2f, barHeight / 2f, paint)
            connectorRect.set(x, lowerY, x + connectorWidth, lowerY + barHeight)
            canvas.drawRoundRect(connectorRect, barHeight / 2f, barHeight / 2f, paint)
        }
    }

    /// An hour-grid day timeline mirroring the iOS calendar: a left time gutter
    /// plus N day columns (2 on phone), with events drawn at their actual times
    /// and overlapping events split into side-by-side sub-columns. Tap an event to
    /// edit it; long-press to jump to its scheme.
    private data class CalendarSlot(
        val occ: JSONObject,
        val kind: String,
        val startMin: Float,
        val endMin: Float,
        val shortEvent: Boolean,
    )

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

        override fun performClick(): Boolean {
            super.performClick()
            return true
        }
        // Viewport (scroll offset + visible height) reported by the enclosing
        // ScrollView so the sticky off-screen-event pills can track the screen.
        private var viewportTop = 0
        private var viewportHeight = 0
        // Sticky pills are redrawn on every scroll/animation frame. Keep their
        // hit-test data in reusable parallel lists instead of allocating a
        // Pair for every visible pill on every frame.
        private val stickyHitRects = ArrayList<RectF>(18)
        private val stickyHitOccurrences = ArrayList<JSONObject>(18)
        private val stickyRectPool = ArrayList<RectF>(18)
        private var stickyRectPoolIndex = 0
        private val stickyTopCandidates = ArrayList<Laid>(3)
        private val stickyBottomCandidates = ArrayList<Laid>(3)
        // Built once alongside [laid]. Sticky-indicator frames can then inspect
        // only the events in the current column instead of rescanning every
        // event once per day on every scroll/snap frame.
        private var laidByObjectDay: List<List<Laid>> = emptyList()
        private var dayDates: List<LocalDate?> = emptyList()
        private var hourLabels: Array<String> = emptyArray()
        private var calendarZone: ZoneId = ZoneId.systemDefault()
        private var calendarZoneId: String = calendarZone.id
        // One short-lived clock sample keeps all time-dependent paint decisions
        // coherent during a swipe without repeating wall-clock/time-zone
        // lookups on every display frame.
        private var frameNow: Instant = Instant.now()
        private var frameToday: LocalDate = LocalDate.now(calendarZone)
        private var lastFrameClockUptimeMs = Long.MIN_VALUE
        private var lastZoneCheckUptimeMs = Long.MIN_VALUE
        private var layoutDirty = true
        // Event drags pick up on a faster long-press (0.22s, matching iOS) than
        // the empty-space create draft (the detector's default long-press).
        private var pendingDragRunnable: Runnable? = null

        // Device-side motion tests use this read-only checkpoint to ensure a
        // committed page reaches the exact zero-offset frame after its new
        // snapshot is published, rather than snapping back early.
        internal val pageOffsetX: Float
            get() = swipeOffsetX

        // Device-side tests use this to confirm a completed day-swipe leaves no
        // stray drag/create interaction armed (see the ACTION_CANCEL forwarded
        // to gestureDetector in maybeStartDaySwipe).
        internal val interactionMode: Int
            get() = dragMode

        private val hourPx = dp(44)
        private val gutterPx = dp(48)
        private val topOffset = dp(8)
        private val bottomPad = dp(88)
        private val hoursInDay = 24

        private fun refreshCalendarZoneIfNeeded(nowUptimeMs: Long) {
            if (lastZoneCheckUptimeMs != Long.MIN_VALUE && nowUptimeMs - lastZoneCheckUptimeMs < 1_000L) return
            lastZoneCheckUptimeMs = nowUptimeMs
            val currentId = ZoneId.systemDefault().id
            if (currentId == calendarZoneId) return
            calendarZoneId = currentId
            calendarZone = ZoneId.of(currentId)
            hourLabels = Array(hoursInDay) { hourLabel(it) }
            // Laid entries contain both zone-dependent y positions and cached
            // labels. Rebuild them before the next draw rather than showing a
            // mixed old/new timezone frame.
            layoutDirty = true
        }

        private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = max(1f, 0.6f * resources.displayMetrics.density)
        }
        private val horizontalGridPath = Path()
        private var horizontalGridPathWidth = -1
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
            val dayIndex: Int,
            // These values do not change while a laid-out occurrence is being
            // scrolled or swiped. Keeping them here avoids JSON reads,
            // timestamp parsing, and cache-key construction on every onDraw.
            val title: String = occ.optString("title").ifEmpty {
                occ.optString("kind").replaceFirstChar(Char::titlecase)
            },
            val timeLabel: String = MobileDateFormatting.compactOccurrenceLabel(occ, timeFormat24(), calendarZone),
            val compact: Boolean = MobileDateFormatting.isCompactEvent(occ),
            val done: Boolean = occ.optBoolean("done"),
            val itemTextColor: Int = calendarItemTextColor(occ),
            val colorIndex: Int = occ.optInt("color_index"),
            val isDaily: Boolean = occ.optString("scheme_name") == "Daily",
            val startInstant: Instant? = MobileDateFormatting.parseInstant(
                occ.optionalString("start") ?: occ.optionalString("end")
            ),
            val endInstant: Instant? = MobileDateFormatting.parseInstant(occ.optionalString("end")),
        ) {
            // Ellipsizing measures glyphs and may allocate a new CharSequence.
            // Cache the result for the current laid-out width so a calendar
            // swipe repaints pixels without repeating text layout every frame.
            private var cachedEventWidth = Float.NaN
            private var cachedEventTitle = ""
            private var cachedEventTime = ""
            private var cachedStickyWidth = Float.NaN
            private var cachedStickyTitle = ""

            fun eventTitleForWidth(width: Float): String {
                ensureEventText(width)
                return cachedEventTitle
            }

            fun eventTimeForWidth(width: Float): String {
                ensureEventText(width)
                return cachedEventTime
            }

            fun stickyTitleForWidth(width: Float): String {
                if (!cachedStickyWidth.isFinite() || abs(cachedStickyWidth - width) > 0.5f) {
                    cachedStickyWidth = width
                    cachedStickyTitle = TextUtils.ellipsize(
                        title,
                        stickyTitlePaint,
                        width,
                        TextUtils.TruncateAt.END,
                    ).toString()
                }
                return cachedStickyTitle
            }

            private fun ensureEventText(width: Float) {
                if (cachedEventWidth.isFinite() && abs(cachedEventWidth - width) <= 0.5f) return
                cachedEventWidth = width
                cachedEventTitle = TextUtils.ellipsize(
                    title,
                    titlePaint,
                    width,
                    TextUtils.TruncateAt.END,
                ).toString()
                cachedEventTime = TextUtils.ellipsize(
                    timeLabel,
                    timePaint,
                    width,
                    TextUtils.TruncateAt.END,
                ).toString()
            }
        }

        private var laid: List<Laid> = emptyList()
        private var dragMode = CALENDAR_INTERACTION_NONE
        private var createKind = "assignment"
        private var dragTargetDay = -1
        private var dragTargetMinute = 0f

        override fun onDetachedFromWindow() {
            // `render()` replaces the timeline view. Do not let a cancelled
            // screen keep invalidating itself or finish a swipe against the
            // newly-rendered screen after it has been detached.
            swipeAnimator?.cancel()
            swipeAnimator = null
            endCalendarGesture(flushDeferredRender = false)
            pendingDragRunnable?.let(::removeCallbacks)
            pendingDragRunnable = null
            velocityTracker?.recycle()
            velocityTracker = null
            super.onDetachedFromWindow()
        }

        private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                for (index in stickyHitRects.lastIndex downTo 0) {
                    if (stickyHitRects[index].contains(e.x, e.y)) {
                        showEventEditorDialog(stickyHitOccurrences[index])
                        return true
                    }
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

        private fun stickyHitContains(x: Float, y: Float): Boolean {
            for (index in stickyHitRects.lastIndex downTo 0) {
                if (stickyHitRects[index].contains(x, y)) return true
            }
            return false
        }

        init {
            isClickable = true
        }

        fun configure(days: List<JSONObject>, columns: Int, leadingColumns: Int = 0) {
            this.dayObjects = days
            this.dayDates = days.map { day ->
                runCatching { LocalDate.parse(day.optString("date")) }.getOrNull()
            }
            this.hourLabels = Array(hoursInDay) { hourLabel(it) }
            this.columns = max(1, columns)
            this.leadingColumns = leadingColumns.coerceIn(0, max(0, days.size - 1))
            this.swipeOffsetX = 0f
            this.swipingDays = false
            this.laid = emptyList()
            this.layoutDirty = true
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
            layoutDirty = true
            relayout()
        }

        private fun minuteOfDay(occ: JSONObject, key: String): Float? {
            val instant = MobileDateFormatting.parseInstant(occ.optionalString(key)) ?: return null
            val local = instant.atZone(calendarZone).toLocalTime()
            return (local.hour * 60 + local.minute).toFloat()
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

        private fun draggedTimeLabel(laid: Laid): String? {
            val time = activeDateTime(dragTargetDay, dragTargetMinute) ?: return null
            val kind = laid.occ.optString("kind")
            val start = when (kind) {
                "event", "reminder" -> MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute, calendarZone)
                else -> null
            }
            val end = when (kind) {
                "event" -> activeDateTime(dragTargetDay, dragTargetMinute + dragDuration)?.let {
                    MobileDateFormatting.iso(it.toLocalDate(), it.hour, it.minute, calendarZone)
                }
                "assignment" -> MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute, calendarZone)
                else -> null
            }
            return MobileDateFormatting.compactOccurrenceLabel(kind, start, end, timeFormat24(), calendarZone)
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
                "event", "reminder" -> MobileDateFormatting.iso(targetTime.toLocalDate(), targetTime.hour, targetTime.minute, calendarZone)
                else -> null
            }
            val end = when (kind) {
                "event" -> {
                    val endTime = activeDateTime(targetDay, dragTargetMinute + dragDuration)
                    endTime?.let { MobileDateFormatting.iso(it.toLocalDate(), it.hour, it.minute, calendarZone) }
                }
                "assignment" -> MobileDateFormatting.iso(targetTime.toLocalDate(), targetTime.hour, targetTime.minute, calendarZone)
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
            val kind = laid.occ.optString("kind")
            val rawMinute = if (kind == "assignment") {
                // The block hangs from its deadline, so snap the bottom edge
                // (the due line) to the grid, mirroring relayout.
                snappedMinute(y - dragOffsetY + dragRect.height(), 15, true)
            } else {
                snappedMinute(y - dragOffsetY + dragRect.height() / 2f, 15, true)
            }
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
            val top = if (kind == "assignment") {
                topOffset + snapped / 60f * hourPx - dragRect.height()
            } else {
                topOffset + snapped / 60f * hourPx
            }
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

                val slots = ArrayList<CalendarSlot>()
                occsArray.forEachObject { occ ->
                    val kind = occ.optString("kind")
                    if (kind == "procedure") return@forEachObject
                    val minDur = if (kind == "event") 30f else 45f
                    if (kind == "assignment") {
                        // An assignment is anchored to its deadline: the block
                        // grows upward so its bottom stroke sits at the due
                        // time, mirroring iOS/desktop.
                        val dueMin = (minuteOfDay(occ, "end") ?: minuteOfDay(occ, "start") ?: return@forEachObject)
                            .coerceIn(0f, 1440f)
                        slots.add(CalendarSlot(occ, kind, max(0f, dueMin - minDur), dueMin, false))
                        return@forEachObject
                    }
                    val rawStart = minuteOfDay(occ, "start") ?: minuteOfDay(occ, "end") ?: return@forEachObject
                    val startMin = rawStart.coerceIn(0f, 1440f)
                    val rawEnd = minuteOfDay(occ, "end")?.coerceIn(0f, 1440f) ?: (startMin + minDur)
                    val shortEvent = if (kind == "event") {
                        val start = MobileDateFormatting.parseInstant(occ.optionalString("start"))
                        val end = MobileDateFormatting.parseInstant(occ.optionalString("end"))
                        start != null && end != null && end.epochSecond - start.epochSecond <= 30 * 60
                    } else {
                        false
                    }
                    slots.add(CalendarSlot(occ, kind, startMin, max(startMin + minDur, rawEnd), shortEvent))
                }
                slots.sortWith(compareBy<CalendarSlot> { it.startMin }.thenByDescending { it.endMin })

                val columnX = gutterPx + (dayIndex - leadingColumns) * colWidth
                val placements = layoutCalendarIntervals(
                    slots.mapIndexed { index, slot ->
                        CalendarLayoutInterval(index, slot.startMin, slot.endMin)
                    },
                )
                placements.forEach { placement ->
                    val slot = slots[placement.key]
                    val kind = slot.kind
                    val subWidth = colWidth.toFloat() / max(1, placement.laneCount)
                    val minHeight = if (kind == "event") dp(20).toFloat() else dp(34).toFloat()
                    val height = max(minHeight, (slot.endMin - slot.startMin) / 60f * hourPx - 2f)
                    // Assignments hang from their deadline: the rect's bottom
                    // edge (its stroke line) lands exactly on the due time, and
                    // any height clamps grow the block upward.
                    val y = if (kind == "assignment") {
                        max(topOffset.toFloat(), topOffset + slot.endMin / 60f * hourPx - height)
                    } else {
                        topOffset + slot.startMin / 60f * hourPx
                    }
                    val x = columnX + placement.lane * subWidth + 1f
                    val rect = RectF(
                        x,
                        y,
                        x + max(dp(8).toFloat(), subWidth * placement.laneSpan - 2f),
                        y + height
                    )
                    out.add(Laid(slot.occ, rect, kind == "reminder", kind == "assignment", slot.shortEvent, dayIndex - leadingColumns))
                }
            }
            laid = out
            val groupedByDay = Array(dayObjects.size) { ArrayList<Laid>() }
            out.forEach { event ->
                val objectDay = event.dayIndex + leadingColumns
                if (objectDay in groupedByDay.indices) groupedByDay[objectDay].add(event)
            }
            laidByObjectDay = groupedByDay.asList()
            layoutDirty = false
        }

        override fun onDraw(canvas: Canvas) {
            if (width <= 0) return
            val nowUptimeMs = SystemClock.uptimeMillis()
            refreshCalendarZoneIfNeeded(nowUptimeMs)
            // The now-line and past shade only need sub-second freshness. Do
            // not allocate a new Instant and zone conversion on every display
            // frame while a page is being dragged; reuse one coherent sample
            // for up to 250ms instead.
            if (lastFrameClockUptimeMs == Long.MIN_VALUE || nowUptimeMs - lastFrameClockUptimeMs >= 250L) {
                lastFrameClockUptimeMs = nowUptimeMs
                frameNow = Instant.now()
                frameToday = frameNow.atZone(calendarZone).toLocalDate()
            }
            if (layoutDirty) relayout()
            drawPastShade(canvas)
            drawGrid(canvas)
            // Paint pinned off-screen indicators before the event layer. If a
            // visible event occupies the indicator lane, its time/title must
            // remain readable instead of being covered by the pill.
            drawStickyIndicators(canvas)
            val dayCanvas = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), 0f, width.toFloat(), height.toFloat())
            canvas.translate(swipeOffsetX, 0f)
            // While dragging (or holding for the scope prompt), only the moving
            // copy is drawn — not the original.
            val dragActive = dragMode == CALENDAR_INTERACTION_DRAG || dragHeldForDialog
            laid.forEach {
                if ((!dragActive || it !== dragLaid) && isTimelineRectVisible(it.rect)) {
                    drawEvent(canvas, it)
                }
            }
            // The create draft stays visible after the touch ends, while its
            // editor dialog is open (cleared via the dialog's dismiss callback).
            draftRect?.let { drawDraftBlock(canvas, it) }
            if (dragActive) {
                dragLaid?.let { laid ->
                    drawEvent(canvas, laid, draggedTimeLabel(laid), dragRect)
                }
            }
            drawNowLine(canvas)
            canvas.restoreToCount(dayCanvas)
        }

        private fun isTimelineRectVisible(rect: RectF): Boolean {
            return calendarRectIntersectsViewport(
                rectTop = rect.top,
                rectBottom = rect.bottom,
                viewportTop = viewportTop,
                viewportHeight = viewportHeight,
            )
        }

        /// Tints the already-elapsed part of each day in the calendar blue, like
        /// iOS/desktop `cal_past`: full column for past days, top-to-now today.
        private fun drawPastShade(canvas: Canvas) {
            if (dayObjects.isEmpty()) return
            val colWidth = max(1, (width - gutterPx) / columns)
            val today = frameToday
            val saved = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), 0f, width.toFloat(), height.toFloat())
            canvas.translate(swipeOffsetX, 0f)
            fillPaint.color = adjustAlpha(calendarDayHighlightColor(), if (theme.isDark) 0.11f else 0.13f)
            for (objectIndex in dayObjects.indices) {
                val date = dayDates.getOrNull(objectIndex) ?: continue
                val shadeBottom = when {
                    date.isBefore(today) -> (topOffset + hoursInDay * hourPx).toFloat()
                    date == today -> {
                        val now = frameNow.atZone(calendarZone).toLocalTime()
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
                MobileDateFormatting.time(
                    MobileDateFormatting.iso(time.toLocalDate(), time.hour, time.minute, calendarZone),
                    timeFormat24(),
                    calendarZone,
                )
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
            stickyHitRects.clear()
            stickyHitOccurrences.clear()
            stickyRectPoolIndex = 0
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
                stickyTopCandidates.clear()
                stickyBottomCandidates.clear()
                val dayLaid = laidByObjectDay.getOrNull(objectIndex).orEmpty()
                dayLaid.forEach { candidate ->
                    if (candidate.rect.top < visibleMinY) {
                        insertStickyTop(candidate, stackDepth)
                    } else if (candidate.rect.top > visibleMaxY) {
                        insertStickyBottom(candidate, stackDepth)
                    }
                }
                var topDisplayed = 0
                for (index in stickyTopCandidates.lastIndex downTo 0) {
                    val candidate = stickyTopCandidates[index]
                    val alpha = ((visibleMinY - candidate.rect.top) / fadeDistance).coerceIn(0f, 1f) * horizontalAlpha
                    val pillY = topBaseY + topDisplayed * (pillH + spacing)
                    if (stickyLaneIsClear(dayLaid, pillY, pillH)) {
                        drawStickyPill(canvas, candidate, columnLeft, colWidth, pillY, pillH, alpha)
                        topDisplayed++
                    }
                }
                var bottomDisplayed = 0
                for (index in stickyBottomCandidates.lastIndex downTo 0) {
                    val candidate = stickyBottomCandidates[index]
                    val alpha = ((candidate.rect.top - visibleMaxY) / fadeDistance).coerceIn(0f, 1f) * horizontalAlpha
                    val pillY = max(topBaseY, bottomBaseY - bottomDisplayed * (pillH + spacing))
                    if (stickyLaneIsClear(dayLaid, pillY, pillH)) {
                        drawStickyPill(canvas, candidate, columnLeft, colWidth, pillY, pillH, alpha)
                        bottomDisplayed++
                    }
                }
            }
        }

        private fun stickyLaneIsClear(dayLaid: List<Laid>, top: Float, height: Float): Boolean =
            dayLaid.none { candidate ->
                candidate.rect.bottom > top && candidate.rect.top < top + height
            }

        private fun insertStickyTop(candidate: Laid, limit: Int) {
            var index = 0
            while (index < stickyTopCandidates.size) {
                val existing = stickyTopCandidates[index]
                if (existing.rect.top < candidate.rect.top ||
                    (existing.rect.top == candidate.rect.top && existing.rect.left > candidate.rect.left)
                ) break
                index++
            }
            if (index >= limit && stickyTopCandidates.size >= limit) return
            stickyTopCandidates.add(index.coerceAtMost(stickyTopCandidates.size), candidate)
            if (stickyTopCandidates.size > limit) stickyTopCandidates.removeAt(limit)
        }

        private fun insertStickyBottom(candidate: Laid, limit: Int) {
            var index = 0
            while (index < stickyBottomCandidates.size) {
                val existing = stickyBottomCandidates[index]
                if (existing.rect.top > candidate.rect.top ||
                    (existing.rect.top == candidate.rect.top && existing.rect.left > candidate.rect.left)
                ) break
                index++
            }
            if (index >= limit && stickyBottomCandidates.size >= limit) return
            stickyBottomCandidates.add(index.coerceAtMost(stickyBottomCandidates.size), candidate)
            if (stickyBottomCandidates.size > limit) stickyBottomCandidates.removeAt(limit)
        }

        private fun drawStickyPill(
            canvas: Canvas,
            event: Laid,
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
            val rect = if (stickyRectPoolIndex < stickyRectPool.size) {
                stickyRectPool[stickyRectPoolIndex]
            } else {
                RectF().also(stickyRectPool::add)
            }
            stickyRectPoolIndex++
            rect.set(x, y, x + pillW, y + pillH)
            val alpha255 = (alpha * 255).roundToInt().coerceIn(0, 255)
            val radius = pillH / 2f
            fillPaint.color = if (theme.isDark) adjustAlpha(rgb(0x333333), 0.92f) else adjustAlpha(theme.bgApp, 0.86f)
            fillPaint.alpha = (Color.alpha(fillPaint.color) * alpha / 1f).roundToInt().coerceIn(0, 255)
            canvas.drawRoundRect(rect, radius, radius, fillPaint)
            borderPaint.color = if (theme.isDark) adjustAlpha(Color.WHITE, 0.18f) else theme.dividerSoft
            borderPaint.alpha = (Color.alpha(borderPaint.color) * alpha).roundToInt().coerceIn(0, 255)
            borderPaint.strokeWidth = max(1f, 0.75f * resources.displayMetrics.density)
            canvas.drawRoundRect(rect, radius, radius, borderPaint)
            fillPaint.color = if (event.isDaily) dailyAccent() else schemeColor(event.colorIndex)
            fillPaint.alpha = alpha255
            canvas.drawCircle(rect.left + dp(9) + dp(7) / 2f, rect.centerY(), dp(7) / 2f, fillPaint)
            stickyTitlePaint.color = theme.textPrimary
            stickyTitlePaint.alpha = alpha255
            val availW = max(0f, pillW - dp(30))
            val label = event.stickyTitleForWidth(availW)
            val baseline = rect.centerY() - (stickyTitlePaint.ascent() + stickyTitlePaint.descent()) / 2f
            canvas.drawText(label, 0, label.length, rect.left + dp(22), baseline, stickyTitlePaint)
            stickyHitRects.add(rect)
            stickyHitOccurrences.add(event.occ)
        }

        private fun drawGrid(canvas: Canvas) {
            if (horizontalGridPathWidth != width) {
                horizontalGridPath.reset()
                for (hour in 0..hoursInDay) {
                    val y = (topOffset + hour * hourPx).toFloat()
                    horizontalGridPath.moveTo(gutterPx.toFloat(), y)
                    horizontalGridPath.lineTo(width.toFloat(), y)
                }
                horizontalGridPathWidth = width
            }
            val colWidth = max(1, (width - gutterPx) / columns)
            gridPaint.color = theme.dividerSoft
            gutterPaint.color = theme.textMuted
            val gridBottom = (topOffset + hoursInDay * hourPx).toFloat()
            // A vertical ScrollView clips the child in content coordinates.
            // Avoid replaying off-screen labels on every scroll frame; the
            // fallback draws the full day before the first viewport callback.
            val visibleTop = if (viewportHeight > 0) viewportTop.toFloat() else 0f
            val visibleBottom = if (viewportHeight > 0) {
                min(gridBottom, (viewportTop + viewportHeight).toFloat())
            } else {
                gridBottom
            }
            val firstHour = ((visibleTop - topOffset) / hourPx).toInt().coerceIn(0, hoursInDay)
            val lastHour = (((visibleBottom - topOffset) / hourPx).toInt() + 1)
                .coerceIn(firstHour, hoursInDay)
            canvas.drawPath(horizontalGridPath, gridPaint)
            for (hour in firstHour..lastHour) {
                val y = (topOffset + hour * hourPx).toFloat()
                // The very bottom of the timeline is the next midnight (12 AM).
                val baseline = y - (gutterPaint.ascent() + gutterPaint.descent()) / 2f
                canvas.drawText(hourLabels[hour % hoursInDay], (gutterPx - dp(6)).toFloat(), baseline, gutterPaint)
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

        private fun drawEvent(
            canvas: Canvas,
            e: Laid,
            timeLabelOverride: String? = null,
            rectOverride: RectF? = null,
        ) {
            val occ = e.occ
            val rect = rectOverride ?: e.rect
            val isPill = e.isReminder || e.isAssignment
            val done = e.done
            val fillAlpha = if (done) 115 else 255
            val radius = if (isPill) 0f else dp(3).toFloat()

            fillPaint.color = eventBg()
            fillPaint.alpha = fillAlpha
            canvas.drawRoundRect(rect, radius, radius, fillPaint)

            if (isPill) {
                pillLinePaint.color = eventBorder()
                pillLinePaint.alpha = fillAlpha
                val sw = calendarPillStrokeWidth().toFloat()
                if (e.isReminder) {
                    canvas.drawRect(rect.left, rect.top, rect.right, rect.top + sw, pillLinePaint)
                } else {
                    canvas.drawRect(rect.left, rect.bottom - sw, rect.right, rect.bottom, pillLinePaint)
                }
            } else {
                borderPaint.color = eventBorder()
                borderPaint.alpha = fillAlpha
                borderPaint.strokeWidth = calendarEventBorderWidth().toFloat()
                val inset = borderPaint.strokeWidth / 2f
                canvas.drawRoundRect(
                    rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset,
                    radius, radius, borderPaint
                )
            }

            val saved = canvas.save()
            canvas.clipRect(rect)
            val padX = dp(4).toFloat()
            val availW = max(0f, rect.width() - padX * 2)
            val cx = rect.centerX()
            val timeLabel = timeLabelOverride ?: e.timeLabel
            val showTime = !e.hideTime && timeLabel.isNotEmpty() && !e.compact
            titlePaint.color = e.itemTextColor
            titlePaint.alpha = if (done) 200 else 255
            val cachedTitle = if (timeLabelOverride == null) e.eventTitleForWidth(availW) else null
            if (showTime) {
                timePaint.color = calendarTimeColor(e.done, e.startInstant, e.endInstant, frameNow, calendarZone)
                timePaint.alpha = if (done) 150 else 255
                val timeTop = rect.top + dp(if (e.isReminder) 5 else 3)
                val time = timeLabelOverride ?: e.eventTimeForWidth(availW)
                canvas.drawText(time, 0, time.length, cx, timeTop - timePaint.ascent(), timePaint)
                val titleTop = timeTop + dp(12)
                val name = cachedTitle ?: TextUtils.ellipsize(e.title, titlePaint, availW, TextUtils.TruncateAt.END).toString()
                canvas.drawText(name, 0, name.length, cx, titleTop - titlePaint.ascent(), titlePaint)
            } else {
                val name = cachedTitle ?: TextUtils.ellipsize(e.title, titlePaint, availW, TextUtils.TruncateAt.END).toString()
                val baseline = rect.centerY() - (titlePaint.ascent() + titlePaint.descent()) / 2f
                canvas.drawText(name, 0, name.length, cx, baseline, titlePaint)
            }
            canvas.restoreToCount(saved)
        }

        private fun drawNowLine(canvas: Canvas) {
            val dayIndex = dayDates.indexOfFirst { it == frameToday }
            if (dayIndex < 0) return
            val colWidth = max(1, (width - gutterPx) / columns)
            val now = frameNow.atZone(calendarZone).toLocalTime()
            val y = topOffset + (now.hour * 60 + now.minute) / 60f * hourPx
            val x0 = (gutterPx + (dayIndex - leadingColumns) * colWidth).toFloat()
            nowPaint.color = theme.danger
            nowPaint.style = Paint.Style.STROKE
            nowPaint.strokeWidth = max(1f, 1.5f * resources.displayMetrics.density)
            // The grid, past shade, events, and sticky indicators all follow
            // the interactive page offset. Keep the now-line in that same
            // coordinate space so it cannot float in place during a swipe.
            // The caller has already translated the event layer by
            // [swipeOffsetX]; translating again here would make the line move
            // twice as far as the events during a page gesture.
            val saved = canvas.save()
            canvas.clipRect(gutterPx.toFloat(), 0f, width.toFloat(), height.toFloat())
            canvas.drawLine(x0, y, x0 + colWidth, y, nowPaint)
            canvas.restoreToCount(saved)
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
                beginCalendarGesture()
                parent?.requestDisallowInterceptTouchEvent(true)
                // Once a day-swipe claims the gesture, every later MOVE/UP/CANCEL
                // for it is consumed here and never reaches gestureDetector (see
                // onTouchEvent below). Android's GestureDetector still has a
                // long-press message armed from the initial ACTION_DOWN, keyed to
                // real elapsed time rather than this event's timestamp; without an
                // explicit cancel it fires ~500ms after the original touch-down
                // regardless of the swipe already having settled, opening a
                // phantom "New event" create on empty space (or grabbing a real
                // event for drag) well after the page has changed. Synthesizing a
                // CANCEL here clears that pending message the same way it would if
                // the detector had seen this gesture end normally.
                val cancel = MotionEvent.obtain(event)
                cancel.action = MotionEvent.ACTION_CANCEL
                try {
                    gestureDetector.onTouchEvent(cancel)
                } finally {
                    cancel.recycle()
                }
            }
            if (!swipingDays) return false
            swipeAnimator?.cancel()
            swipeOffsetX = rubberBandSwipe(dx, dayColumnWidth() * 0.96f)
            invalidate()
            return true
        }

        private fun finishDaySwipe() {
            val colWidth = dayColumnWidth()
            velocityTracker?.computeCurrentVelocity(1000)
            val vx = velocityTracker?.xVelocity ?: 0f
            velocityTracker?.recycle()
            velocityTracker = null
            // iOS commit rule: project the gesture 0.18s ahead by velocity (only
            // when that grows the travel) and page when the projection clears the
            // threshold, or when the raw drag passed 42% of a column.
            val dayDelta = calendarDaySwipeDelta(
                offsetPx = swipeOffsetX,
                velocityPxPerSecond = vx,
                columnWidthPx = colWidth,
                viewportWidthPx = width.toFloat(),
                minimumThresholdPx = dp(48).toFloat(),
            )
            if (dayDelta == 0L) {
                animateDaySwipe(0f) {
                    swipingDays = false
                    parent?.requestDisallowInterceptTouchEvent(false)
                    endCalendarGesture(flushDeferredRender = true)
                }
                return
            }
            val target = if (dayDelta > 0) -colWidth else colWidth
            animateDaySwipe(target) {
                val nextDate = selectedDate.plusDays(dayDelta)
                selectedDate = nextDate
                weekOffset = 0
                calendarScrollDate = nextDate.toString()
                swipingDays = false
                parent?.requestDisallowInterceptTouchEvent(false)
                // Keep the canvas parked on the fully travelled page until the
                // authoritative next-day snapshot is ready. Resetting the
                // offset here made the old day visibly jump back while the
                // async core read was still in flight; iOS keeps the page at
                // its settled edge until the destination is mounted.
                refreshSnapshotAsync(
                    renderAfter = false,
                    onSuccess = {
                        if (!isAttachedToWindow) return@refreshSnapshotAsync
                        swipeOffsetX = 0f
                        endCalendarGesture(flushDeferredRender = false)
                        requestRender()
                    },
                    onFailure = {
                        // A failed refresh must still release the gesture and
                        // restore the current page instead of leaving a blank
                        // edge parked on screen forever.
                        swipeOffsetX = 0f
                        endCalendarGesture(flushDeferredRender = false)
                        requestRender()
                    },
                )
            }
        }

        private fun animateDaySwipe(target: Float, onEnd: () -> Unit) {
            swipeAnimator?.cancel()
            val distance = abs(target - swipeOffsetX)
            val baseDuration = if (target == 0f) 165L else 205L
            val duration = animationDuration(
                context,
                snappingAnimationDurationMs(baseDuration, distance, dayColumnWidth()),
            )
            if (duration == 0L) {
                // Do not start a zero-duration ValueAnimator: Android can still
                // schedule an intermediate frame, which flashes the old page
                // when reduced-motion is enabled.
                swipeAnimator = null
                swipeOffsetX = target
                invalidate()
                onEnd()
                return
            }
            val animator = ValueAnimator.ofFloat(swipeOffsetX, target).apply {
                this.duration = duration
                // A fast ease-out gives the release a crisp iOS-like settle
                // without the late-frame braking that made short swipes feel
                // sticky or jagged.
                interpolator = PathInterpolator(0.18f, 0.82f, 0.24f, 1f)
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
            // A release starts a short page-settle animation. Do not let a
            // second pointer sequence cancel that animation and reset the
            // offset to zero mid-frame: doing so produces a visible jump (and
            // can commit the opposite day before the first page is published).
            // The settle lasts at most a couple hundred milliseconds, so
            // briefly ignoring the new sequence is both safer and closer to
            // iOS paging behavior than accepting a gesture against stale data.
            if (swipeAnimator != null) return true

            // After a committed page reaches its edge, keep that edge parked
            // until the destination snapshot has been installed. A new touch
            // during this short handoff must not run ACTION_DOWN below and
            // reset the offset to zero against the old day's canvas.
            if (calendarGestureActive && !swipingDays) return true

            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
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
                    if (dragMode == CALENDAR_INTERACTION_NONE && !stickyHitContains(downX, downY)) {
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
                    if (!swipingDays) performClick()
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
                            endCalendarGesture(flushDeferredRender = true)
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
        // Incremental navigator batches can add dozens of rows while this
        // panel is already attached during a scroll. Use the same transaction
        // aware container as the other high-churn lists so one batch produces
        // one measure/layout publication instead of one per row.
        private val list = LayoutTransactionLinearLayout(context).apply {
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
        // Keep both metadata traversal and View inflation bounded. The previous
        // implementation flattened every visible node before showing the first
        // row, which still froze pathological workspaces even though Views were
        // created in batches. This stack is expanded only as rows approach the
        // viewport tail.
        private val pendingFrames = ArrayDeque<NavigatorTraversalFrame>()
        private var traversalComplete = false
        private var buildGeneration = 0L
        private var buildContinuation: Runnable? = null
        private var hostScrollView: ScrollView? = null
        private val hostScrollListener = android.view.ViewTreeObserver.OnScrollChangedListener {
            maybeAppendRowsNearViewport()
        }
        private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var pressedRow: View? = null
        private var pressedMeta: NavRowMeta? = null
        private var dragging = false
        private var draggedSinceLift = false
        private var pendingPlacement: Pair<String, Int>? = null
        private var liftRunnable: Runnable? = null
        private var disallowingParentIntercept = false

        override fun performClick(): Boolean {
            super.performClick()
            return true
        }

        init {
            addView(list, LayoutParams(-1, -2))
            addView(folderHighlight, LayoutParams(0, 0))
            addView(dropLine, LayoutParams(0, dp(3)))
            buildRows()
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            var ancestor = parent
            while (ancestor != null && ancestor !is ScrollView) ancestor = ancestor.parent
            hostScrollView = ancestor as? ScrollView
            hostScrollView?.viewTreeObserver?.addOnScrollChangedListener(hostScrollListener)
        }

        override fun onDetachedFromWindow() {
            // A full render replaces this panel. Clear its long-press callback
            // and any transient drag transforms before the old rows disappear;
            // otherwise a delayed lift can mutate a stale row or flash above the
            // next screen.
            buildGeneration++
            buildContinuation?.let(::removeCallbacks)
            buildContinuation = null
            hostScrollView?.viewTreeObserver?.removeOnScrollChangedListener(hostScrollListener)
            hostScrollView = null
            if (dragging) finishDrag(commit = false) else cancelLift(releaseParentIntercept = false)
            super.onDetachedFromWindow()
        }

        private fun buildRows() {
            buildGeneration++
            buildContinuation?.let(::removeCallbacks)
            buildContinuation = null
            list.removeAllViews()
            rowMetas.clear()
            pendingFrames.clear()
            traversalComplete = false
            val root = snapshot.optJSONObject("root")
            val rootId = root?.optString("id").orEmpty()
            val roots = root?.optJSONArray("children")
            if (roots == null || roots.length() == 0) {
                traversalComplete = true
                addEmptyStateIfNeeded()
                return
            }
            // Keep one cursor for the root array instead of pushing every root
            // sibling into a stack. Expanded folders add one more frame per
            // nesting level, so memory stays O(depth), even for huge sibling
            // lists.
            pendingFrames.addLast(NavigatorTraversalFrame(roots, rootId, 0))
            appendRowBatch(NAVIGATOR_INITIAL_BATCH)
            maybeAppendRowsNearViewport()
        }

        private fun addEmptyStateIfNeeded() {
            if (list.childCount != 0) return
            list.addView(text("No schemes yet", theme.textMuted, 14f, false).apply {
                setPadding(dp(10), dp(8), dp(10), dp(8))
            }, LinearLayout.LayoutParams(-1, dp(36)))
        }

        /** True while unseen visible nodes remain in the incremental traversal. */
        internal fun hasPendingRows(): Boolean = pendingFrames.isNotEmpty()

        private fun appendRowBatch(batchSize: Int) {
            var appended = 0
            list.batchLayoutChanges {
                while (appended < batchSize && pendingFrames.isNotEmpty()) {
                    val frame = pendingFrames.last()
                    if (frame.nextIndex >= frame.children.length()) {
                        pendingFrames.removeLast()
                        continue
                    }
                    val siblingIndex = frame.nextIndex++
                    val node = frame.children.optJSONObject(siblingIndex) ?: continue
                    val kind = node.optString("kind")
                    val id = node.optString("id")
                    val meta = NavRowMeta(
                        node = node,
                        id = id,
                        kind = kind,
                        parentId = frame.parentId,
                        siblingIndex = siblingIndex,
                        depth = frame.depth,
                        childCount = node.optJSONArray("children")?.length() ?: 0,
                    )
                    val row = navigatorRow(meta)
                    rowMetas.add(row to meta)
                    list.addView(row, LinearLayout.LayoutParams(-1, rowHeight))
                    appended++
                    if (kind == "folder" && !collapsedFolderIds.contains(id)) {
                        node.optJSONArray("children")?.let { children ->
                            if (children.length() > 0) {
                                pendingFrames.addLast(NavigatorTraversalFrame(children, id, frame.depth + 1))
                            }
                        }
                    }
                }
            }
            traversalComplete = pendingFrames.isEmpty()
            if (traversalComplete && rowMetas.isEmpty()) addEmptyStateIfNeeded()
        }

        private fun maybeAppendRowsNearViewport() {
            val scroll = hostScrollView ?: return
            if (buildContinuation != null || traversalComplete) return
            if (!isAttachedToWindow || list.height <= 0 || scroll.height <= 0) return
            // The initial batch is intentionally larger than the phone's
            // capped viewport. Only materialize the next batch when the user
            // actually reaches the currently-built tail; an untouched screen
            // therefore never spends frames inflating off-screen rows.
            // Use window coordinates because NavigatorPanel can live directly
            // inside the page ScrollView (wide Home) or inside its own nested
            // side-rail ScrollView. Comparing local `bottom` to scrollY in the
            // former case would mix coordinate spaces and either starve or
            // eagerly drain the continuation batches.
            val listLocation = IntArray(2)
            val scrollLocation = IntArray(2)
            list.getLocationOnScreen(listLocation)
            scroll.getLocationOnScreen(scrollLocation)
            val listBottom = listLocation[1] + list.height
            val viewportBottom = scrollLocation[1] + scroll.height
            if (viewportBottom < listBottom - rowHeight * 6) return
            val generation = buildGeneration
            val continuation = Runnable {
                buildContinuation = null
                if (generation != buildGeneration || !isAttachedToWindow) return@Runnable
                appendRowBatch(NAVIGATOR_CONTINUATION_BATCH)
                maybeAppendRowsNearViewport()
            }
            buildContinuation = continuation
            postOnAnimation(continuation)
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
                        setParentInterceptDisallowed(true)
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
                        cancelLift(releaseParentIntercept = true)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> cancelLift(releaseParentIntercept = !dragging)
            }
            return dragging
        }

        private fun cancelLift(releaseParentIntercept: Boolean) {
            liftRunnable?.let { removeCallbacks(it) }
            liftRunnable = null
            if (releaseParentIntercept) setParentInterceptDisallowed(false)
        }

        private fun setParentInterceptDisallowed(disallowed: Boolean) {
            if (disallowingParentIntercept == disallowed) return
            parent?.requestDisallowInterceptTouchEvent(disallowed)
            disallowingParentIntercept = disallowed
        }

        private fun beginLift() {
            val row = pressedRow ?: return
            dragging = true
            draggedSinceLift = false
            pendingPlacement = null
            setParentInterceptDisallowed(true)
            row.elevation = dp(8).toFloat()
            val duration = animationDuration(context, 120L)
            if (duration == 0L) {
                row.scaleX = 0.97f
                row.scaleY = 0.97f
                row.alpha = 0.85f
            } else {
                row.animate().scaleX(0.97f).scaleY(0.97f).alpha(0.85f).setDuration(duration).start()
            }
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
                    performClick()
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
            setParentInterceptDisallowed(false)
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
            } else if (raw != null) {
                showIndicator(raw)
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
            val firstView = rowMetas.first().first
            val lastView = rowMetas.last().first
            val yInList = y - list.top
            if (yInList < firstView.top) {
                return RawNavDrop(rootId, 0, (firstView.top + list.top).toFloat(), 0, null)
            }
            if (yInList >= lastView.bottom) {
                val lastMeta = rowMetas.last().second
                return rawDropAfterRow(lastView, lastMeta)
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

        private fun rawDropAfterRow(view: View, meta: NavRowMeta): RawNavDrop {
            val lineY = (view.bottom + list.top).toFloat()
            if (meta.kind == "folder" && !collapsedFolderIds.contains(meta.id)) {
                return RawNavDrop(meta.id, meta.childCount, lineY, meta.depth + 1, null)
            }
            return RawNavDrop(meta.parentId, meta.siblingIndex + 1, lineY, meta.depth, null)
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
            val pending = ArrayDeque<JSONObject>()
            val children = node.optJSONArray("children") ?: return false
            for (index in children.length() - 1 downTo 0) {
                children.optJSONObject(index)?.let(pending::addLast)
            }
            while (pending.isNotEmpty()) {
                val current = pending.removeLast()
                if (current.optString("id") == id) return true
                val nested = current.optJSONArray("children") ?: continue
                for (index in nested.length() - 1 downTo 0) {
                    nested.optJSONObject(index)?.let(pending::addLast)
                }
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


    // Throttled entry point — coalesces bursts. Must be called on the UI thread
    // (all foreground callers are); the background worker bypasses this.
    internal fun rescheduleNotifications() {
        if (notifRescheduleCooldown) {
            notifReschedulePending = true
            return
        }
        rescheduleNotificationsCooldownStart()
    }

    private fun rescheduleNotificationsCooldownStart() {
        notifRescheduleCooldown = true
        notifReschedulePending = false
        rescheduleNotificationsNow()
        notifRescheduleHandler.postDelayed({
            notifRescheduleCooldown = false
            if (notifReschedulePending) rescheduleNotificationsCooldownStart()
        }, NOTIF_RESCHEDULE_DEBOUNCE_MS)
    }

    /**
     * Rebuilds the OS alarms for every pending notification.
     *
     * Off the main thread, deliberately. Asking the core for the pending
     * notifications takes its lock, and a sync or a Google import holds that lock
     * for seconds at a time — long enough that doing this on the UI thread ANR'd
     * the app (the trace showed `main` parked in `pending_notifications` →
     * `Mutex::lock_contended`) while the screen sat on whatever it last drew.
     */
    private fun rescheduleNotificationsNow() {
        if (!::bridge.isInitialized) return
        if (notifRescheduleRunning) {
            notifReschedulePending = true
            return
        }
        notifRescheduleRunning = true
        Thread {
            var failure: RuntimeException? = null
            try {
                MobileNotificationScheduler.reschedule(
                    this,
                    coreExecutor.call { bridge.requestArray(obj("type" to "pending_notifications")) }
                )
                // Also clear banners for events that ended or occurrences completed,
                // which reschedule() leaves in the tray once they've already fired.
                MobileNotificationScheduler.clearStale(
                    this,
                    coreExecutor.call { bridge.requestArray(obj("type" to "delivered_notifications_to_clear")) }
                )
            } catch (error: RuntimeException) {
                failure = error
            }
            val error = failure
            runOnUiThread {
                notifRescheduleRunning = false
                if (!isUiActive()) return@runOnUiThread
                if (error != null) showError("Notifications unavailable", error.message)
            }
        }.start()
    }

    /// Fetch the current FCM registration token and hand it to the live core so
    /// the next sync registers this device for silent background pushes. Token
    /// rotation is handled separately by KnotQMessagingService.onNewToken; this
    /// covers the common cold-start-with-existing-token case. Best-effort: if
    /// Play services are unavailable the listener simply never fires.
    internal fun registerForPushNotifications() {
        // FCM push registration only exists to drive cross-device sync, which is
        // compiled out of release builds.
        if (!BuildConfig.ACCOUNTS_ENABLED) return
        // FirebaseApp initialization is deliberately off the UI thread. The
        // first workspace frame is already visible by the time this is called,
        // but provider startup can still load Play-services classes and disk
        // state on a cold process.
        Thread {
            if (!KnotQFirebase.initialize(applicationContext)) return@Thread
            runCatching {
                com.google.firebase.messaging.FirebaseMessaging.getInstance().token
                    .addOnSuccessListener { token ->
                        if (token.isNullOrBlank()) return@addOnSuccessListener
                        if (!isUiActive()) return@addOnSuccessListener
                        PushRegistration.store(this, token)
                        if (::bridge.isInitialized) {
                            // Firebase delivers this callback on the main thread
                            // by default. Token registration touches the native
                            // core and can wait on disk/sync work, so never call
                            // it inline or a foreground refresh can block the UI.
                            runCatching {
                                PushRegistration.dispatch(coreExecutor) {
                                    PushRegistration.apply(bridge, token)
                                }
                            }
                        }
                    }
            }
        }.start()
    }

    internal fun showOnboardingOverlay() {
        if (!onboardingActive || !isUiActive()) return
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
