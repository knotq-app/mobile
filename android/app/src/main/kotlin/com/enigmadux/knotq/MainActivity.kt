package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.MotionEvent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
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
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val SYNC_SESSION_PREF = "knotq.localSyncSession"
private const val DEFAULT_SYNC_API_BASE = "https://api.knotq.com"
// The Google Play subscription product id for hosted sync (Play Console).
private const val SYNC_SUBSCRIPTION_PRODUCT_ID = "knotq.sync.monthly"
private const val GOOGLE_CLIENT_ID = "419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld.apps.googleusercontent.com"
private const val GOOGLE_REDIRECT_SCHEME = "com.googleusercontent.apps.419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld"
private const val GOOGLE_REDIRECT_URI = "$GOOGLE_REDIRECT_SCHEME:/oauth2redirect"
private const val GOOGLE_SYNC_INTERVAL_MS = 120_000L
private const val TAB_CALENDAR = 0
private const val TAB_SCHEMES = 1
private const val TAB_DAILY = 2
private const val TAB_SEARCH = 3
private const val TAB_SETTINGS = 4
private const val TAB_HOME = 5

private data class SyncSession(
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

private data class SyncLoginChallenge(
    val apiBase: String,
    val email: String,
    val challengeId: String,
    val devCode: String?
)

private data class SyncLoginStart(
    val challenge: SyncLoginChallenge?,
    val session: SyncSession?
)

private data class FolderDestination(val id: String, val name: String, val depth: Int)

class MainActivity : Activity() {
    private lateinit var bridge: RustBridge
    private lateinit var shell: LinearLayout
    private lateinit var titleBar: LinearLayout
    private lateinit var content: FrameLayout
    private lateinit var dock: LinearLayout
    private lateinit var theme: UiTheme

    private var snapshot = JSONObject()
    private var selectedTab = TAB_HOME
    private var weekOffset = 0
    private var selectedDate: LocalDate = LocalDate.now()
    private var selectedSchemeId: String? = null
    private var keyboardActive = false
    private val editorSchemeIds = WeakHashMap<EditText, String>()
    private var syncSession: SyncSession? = null
    private var syncLoginChallenge: SyncLoginChallenge? = null
    private var syncAuthInProgress = false
    private var syncAccountActionInProgress = false
    private var syncInProgress = false
    private var billingClient: BillingClient? = null
    private var purchaseInProgress = false
    private var googleAuthInProgress = false
    private var googleSyncInProgress = false
    private var googleSyncPollingActive = false
    private var googleCalendarStatus: String? = null
    private var pendingGoogleAuthRequest: JSONObject? = null
    private var pendingGoogleParentId: String? = null
    private val syncPollHandler = Handler(Looper.getMainLooper())
    private val syncPollRunnable = object : Runnable {
        override fun run() {
            syncOnce()
            syncPollHandler.postDelayed(this, 30_000)
        }
    }
    private val googleSyncHandler = Handler(Looper.getMainLooper())
    private val googleSyncRunnable = object : Runnable {
        override fun run() {
            syncGoogleCalendars(silent = true)
            googleSyncHandler.postDelayed(this, GOOGLE_SYNC_INTERVAL_MS)
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
            MobileNotificationScheduler.requestPermission(this)
            rescheduleNotifications()
            startSyncPolling()
            configureGoogleSyncPolling()
            handleGoogleCallback(intent?.data)
        } catch (error: Throwable) {
            theme = UiTheme.dark
            showFatal(error.message)
        }
    }

    override fun onDestroy() {
        syncPollHandler.removeCallbacks(syncPollRunnable)
        googleSyncHandler.removeCallbacks(googleSyncRunnable)
        billingClient?.endConnection()
        billingClient = null
        if (::bridge.isInitialized) {
            bridge.close()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleGoogleCallback(intent?.data)
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

    private fun buildShell() {
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
            setBackgroundColor(theme.bgSidebar)
        }

        shell.addView(titleBar, LinearLayout.LayoutParams(-1, dp(38)))
        shell.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        shell.addView(dock, LinearLayout.LayoutParams(-1, dp(58)))
        setContentView(shell)
        installKeyboardVisibilityWatcher()
    }

    private fun render() {
        if (!::content.isInitialized) return
        applyTheme()
        shell.setBackgroundColor(theme.bgApp)
        titleBar.setBackgroundColor(theme.bgToolbar)
        content.setBackgroundColor(theme.bgApp)
        dock.setBackgroundColor(theme.bgSidebar)

        renderTitleBar()
        renderDock()
        content.removeAllViews()
        val wide = resources.configuration.screenWidthDp >= 760
        updateChromeVisibility()
        val view = if (wide) renderWideShell() else renderPhoneMain()
        content.addView(view)
    }

    private fun renderTitleBar() {
        titleBar.removeAllViews()
        titleBar.addView(
            if (selectedTab == TAB_HOME) brandMark(20) else colorSquare(titleColor(), 18),
            LinearLayout.LayoutParams(dp(if (selectedTab == TAB_HOME) 20 else 18), dp(if (selectedTab == TAB_HOME) 20 else 18))
        )
        titleBar.addView(text(titleText(), theme.textPrimary, 14f, true).apply {
            gravity = Gravity.CENTER
            maxLines = 1
        }, LinearLayout.LayoutParams(0, -1, 1f))

        titleBar.addView(chip("Search") {
            selectedTab = TAB_SEARCH
            selectedSchemeId = null
            render()
        }, marginRight(dp(6), -2, dp(28)))
        titleBar.addView(chip(syncSession?.email ?: "Sign in") {
            showSyncAccountDialog()
        }, marginRight(dp(6), dp(104), dp(28)))
        titleBar.addView(chip("+") { showNewMenu() }, LinearLayout.LayoutParams(dp(32), dp(28)))
    }

    private fun renderDock() {
        dock.removeAllViews()
        listOf(TAB_HOME to "Home", TAB_CALENDAR to "Calendar", TAB_SETTINGS to "Settings").forEach { (index, label) ->
            val selected = selectedTab == index ||
                (index == TAB_HOME && selectedTab in listOf(TAB_SCHEMES, TAB_DAILY, TAB_SEARCH))
            val tab = text(label, if (selected) theme.textPrimary else theme.textMuted, 11f, true).apply {
                gravity = Gravity.CENTER
                setOnClickListener {
                    selectedTab = index
                    if (index != TAB_SCHEMES) selectedSchemeId = null
                    render()
                }
            }
            dock.addView(tab, LinearLayout.LayoutParams(0, -1, 1f))
        }
    }

    private fun hidePhoneDockForEditing() {
        keyboardActive = true
        updateChromeVisibility()
    }

    private fun showPhoneDockAfterEditing() {
        keyboardActive = false
        updateChromeVisibility()
    }

    private fun dismissKeyboard() {
        val focus = currentFocus
        if (focus is EditText) {
            focus.clearFocus()
        }
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow((focus ?: shell).windowToken, 0)
        keyboardActive = false
        updateChromeVisibility()
    }

    private fun installKeyboardVisibilityWatcher() {
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

    private fun updateChromeVisibility() {
        if (!::titleBar.isInitialized || !::dock.isInitialized) return
        val wide = resources.configuration.screenWidthDp >= 760
        titleBar.visibility = if (!wide && keyboardActive) View.GONE else View.VISIBLE
        dock.visibility = if (wide || keyboardActive) View.GONE else View.VISIBLE
    }

    private fun renderWideShell(): View {
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

    private fun renderPhoneMain(): View =
        when (selectedTab) {
            TAB_SEARCH, TAB_SETTINGS -> scroll(renderMain())
            else -> renderMain()
        }

    private fun renderMain(): View {
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

    private fun renderNavigator(): View {
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
            addView(chip("New") { showNewMenu() }, LinearLayout.LayoutParams(0, dp(30), 1f))
            addView(chip("⚙") {
                selectedTab = TAB_SETTINGS
                selectedSchemeId = null
                render()
            }, LinearLayout.LayoutParams(dp(33), dp(30)).apply { setMargins(dp(6), 0, 0, 0) })
        })
        return panel
    }

    private fun renderHome(): LinearLayout {
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
            calendar().optJSONArray("overdue")?.forEachObject { combined.put(it) }
            calendar().optJSONArray("upcoming")?.forEachObject { combined.put(it) }
            addOccurrenceSection(body, "Upcoming", "Nothing scheduled", combined)
        }
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    private fun homeHeader(): View =
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

    private fun homeQuickActions(): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(chip("Daily Item") { addDailyItemFromHome() }, marginRight(dp(6), -2, dp(30)))
                addView(chip("Calendar Item") { showCalendarItemDialog() }, marginRight(dp(6), -2, dp(30)))
                addView(chip("New Scheme") {
                    showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
                        mutate(obj("type" to "create_scheme", "name" to name, "position" to 0))
                    }
                }, marginRight(dp(6), -2, dp(30)))
                addView(chip("New Folder") {
                    showNameDialog("New Folder", "", { validateFolderName(it) }) { name ->
                        mutate(obj("type" to "create_folder", "name" to name))
                    }
                }, marginRight(dp(6), -2, dp(30)))
                addView(chip("Google Calendar") { startGoogleCalendarImport() }, LinearLayout.LayoutParams(-2, dp(30)))
            })
        }

    private fun homeDailySummaryRow(): View {
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
            addView(text("+", theme.textPrimary, 16f, true).apply {
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

    private fun countDoneItems(scheme: JSONObject?): Int {
        var done = 0
        scheme?.optJSONArray("items")?.forEachObject { item ->
            if (item.optBoolean("done")) done++
        }
        return done
    }

    private fun renderListsPage(): LinearLayout {
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

    private fun dailyShortcutRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(7), 0)
            background = rounded(Color.TRANSPARENT, dp(4))
            addView(colorSquare(dailyAccent(), 9), LinearLayout.LayoutParams(dp(9), dp(9)).apply {
                setMargins(0, 0, dp(7), 0)
            })
            addView(text("Daily", theme.textPrimary, 13f, true).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(text(">", theme.textMuted, 12f, true).apply { gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(16), -1))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                ensureDaily()
            }
        }

    private fun archiveNavigatorSection(compact: Boolean): View {
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

    private fun archivedSchemeRow(scheme: JSONObject, compact: Boolean): View =
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
                addView(chip("Restore") {
                    mutate(obj("type" to "restore_scheme", "scheme_id" to scheme.optString("id")))
                }, LinearLayout.LayoutParams(dp(78), dp(28)))
            }
            setOnClickListener { showArchivedSchemeActions(scheme) }
            setOnLongClickListener {
                showArchivedSchemeActions(scheme)
                true
            }
        }

    private fun renderUpcomingRail(): View {
        val root = page(compact = true)
        addOccurrenceSection(root, "Overdue", "None", calendar().optJSONArray("overdue"))
        addOccurrenceSection(root, "Today", "None today", todayOccurrences())
        addOccurrenceSection(root, "Upcoming", "None", calendar().optJSONArray("upcoming"))
        return scroll(root)
    }

    private fun renderCalendar(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(calendarToolbar())
        val body = page()
        val overdue = calendar().optJSONArray("overdue")
        if (overdue != null && overdue.length() > 0) {
            addOccurrenceSection(body, "Overdue", "None", overdue)
        }
        val days = calendar().optJSONArray("days")
        if (resources.configuration.screenWidthDp >= 760) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(dp(12), dp(12), dp(12), dp(12))
            }
            days?.forEachObject { day -> row.addView(dayColumn(day), marginRight(dp(8), dp(132), -2)) }
            root.addView(HorizontalScrollView(this).apply {
                setBackgroundColor(theme.bgApp)
                addView(row)
            }, LinearLayout.LayoutParams(-1, 0, 1f))
        } else {
            if (days != null) {
                for (index in 0 until min(phoneCalendarDayCount(), days.length())) {
                    days.optJSONObject(index)?.let { body.addView(dayList(it), spaced()) }
                }
            }
            root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        }
        return root
    }

    private fun calendarToolbar(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = underline(theme.bgApp)
            addView(calendarTitleView(), LinearLayout.LayoutParams(-1, dp(44)))
            addView(calendarWeekStrip(), LinearLayout.LayoutParams(-1, dp(56)))
        }.also {
            it.layoutParams = LinearLayout.LayoutParams(-1, dp(100))
        }
    }

    private fun calendarTitleView(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(8), dp(12), dp(4))
            addView(iconChip("<") {
                weekOffset -= 1
                loadSnapshot()
                render()
            })
            addView(text(selectedDateTitle(), theme.textPrimary, 23f, true).apply {
                gravity = Gravity.CENTER
                includeFontPadding = false
                setOnClickListener { showMonthPickerDialog() }
            }, LinearLayout.LayoutParams(0, dp(32), 1f))
            addView(chip("Today") {
                weekOffset = 0
                selectedDate = LocalDate.now()
                loadSnapshot()
                render()
            }, LinearLayout.LayoutParams(dp(64), dp(28)).apply { setMargins(dp(5), 0, dp(5), 0) })
            addView(iconChip(">") {
                weekOffset += 1
                loadSnapshot()
                render()
            })
        }

    private fun calendarWeekStrip(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), 0, dp(10), dp(4))
            val days = calendar().optJSONArray("days")
            val stripDates = mutableListOf<LocalDate>()
            if (days != null && days.length() > 0) {
                for (index in 0 until min(8, days.length())) {
                    runCatching { LocalDate.parse(days.optJSONObject(index)?.optString("date")) }
                        .getOrNull()
                        ?.let(stripDates::add)
                }
            }
            if (stripDates.isEmpty()) {
                for (offset in 0 until 8) stripDates.add(weekStart(selectedDate).plusDays(offset.toLong()))
            }
            stripDates.forEachIndexed { offset, date ->
                val today = date == LocalDate.now()
                val visible = offset < phoneCalendarDayCount()
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    if (visible) {
                        background = roundedHorizontalSegment(
                            calendarRangeFill(),
                            leadingRounded = date == selectedDate,
                            trailingRounded = offset == phoneCalendarDayCount() - 1
                        )
                    }
                    addView(text(date.dayOfWeek.getDisplayName(TextStyle.NARROW, Locale.getDefault()).uppercase(Locale.getDefault()), if (today || visible) theme.textPrimary else theme.textMuted, 10f, true).apply {
                        gravity = Gravity.CENTER
                    }, LinearLayout.LayoutParams(-1, dp(16)))
                    addView(text(date.dayOfMonth.toString(), if (today) theme.accent else theme.textPrimary, 17f, false).apply {
                        gravity = Gravity.CENTER
                    }, LinearLayout.LayoutParams(dp(34), dp(34)))
                    setOnClickListener {
                        selectedDate = date
                        weekOffset = 0
                        loadSnapshot()
                        render()
                    }
                }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                    setMargins(if (visible && date != selectedDate) 0 else dp(1), dp(3), if (visible && offset == 0) 0 else dp(1), dp(3))
                })
            }
        }

    private fun phoneCalendarDayCount(): Int =
        if (resources.configuration.screenWidthDp >= 600) 3 else 2

    private fun dayColumn(day: JSONObject): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = rounded(if (theme.isDark) adjust(theme.bgModal, 0.42f) else theme.bgModal, dp(6), theme.dividerSoft)
        }
        column.addView(text(MobileDateFormatting.fullDay(day.optString("date")), if (day.optString("date") == LocalDate.now().toString()) theme.textToday else theme.textDim, 12f, true), spaced())
        val occurrences = day.optJSONArray("occurrences")
        if (occurrences == null || occurrences.length() == 0) {
            column.addView(text("None", theme.textMuted, 12f, false).apply {
                gravity = Gravity.CENTER
                background = rounded(theme.rowAlt, dp(4))
                setPadding(dp(8), dp(12), dp(8), dp(12))
            })
        } else {
            occurrences.forEachObject { occurrence -> column.addView(eventBlock(occurrence), spaced()) }
        }
        return column
    }

    private fun dayList(day: JSONObject): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(text(MobileDateFormatting.fullDay(day.optString("date")), if (day.optString("date") == LocalDate.now().toString()) theme.textToday else theme.textDim, 12f, true))
            val occurrences = day.optJSONArray("occurrences")
            if (occurrences == null || occurrences.length() == 0) {
                addView(text("No calendar items", theme.textMuted, 13f, false).apply { setPadding(0, dp(6), 0, dp(6)) })
            } else {
                occurrences.forEachObject { occurrence -> addView(eventBlock(occurrence), spaced()) }
            }
        }
    }

    private fun eventBlock(occurrence: JSONObject): View {
        val isReminder = occurrence.optString("kind") == "reminder"
        val isAssignment = occurrence.optString("kind") == "assignment"
        val isPill = isReminder || isAssignment
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(if (isPill) 8 else 6), if (isReminder) dp(6) else dp(3), dp(if (isPill) 8 else 6), dp(4))
            val time = MobileDateFormatting.compactOccurrenceLabel(occurrence, timeFormat24())
            if (time.isNotEmpty() && !MobileDateFormatting.isCompactEvent(occurrence)) {
                addView(text(time, calendarTimeColor(occurrence), 9f, false).apply {
                    gravity = Gravity.CENTER
                    typeface = Typeface.MONOSPACE
                    maxLines = 1
                }, LinearLayout.LayoutParams(-1, dp(12)))
            }
            addView(text(occurrence.optString("title").ifEmpty { occurrence.optString("kind").replaceFirstChar(Char::titlecase) }, calendarItemTextColor(occurrence), 11f, true).apply {
                gravity = Gravity.CENTER
                maxLines = 1
            }, LinearLayout.LayoutParams(-1, dp(16)))
        }
        return FrameLayout(this).apply {
            background = if (isPill) rounded(eventBg(), 0) else rounded(eventBg(), dp(3), eventBorder(), strokeWidth = calendarEventBorderWidth())
            alpha = if (occurrence.optBoolean("done")) 0.45f else 1f
            addView(content, FrameLayout.LayoutParams(-1, -2))
            if (isReminder || isAssignment) {
                addView(View(this@MainActivity).apply { setBackgroundColor(eventBorder()) }, FrameLayout.LayoutParams(-1, calendarPillStrokeWidth(), if (isReminder) Gravity.TOP else Gravity.BOTTOM))
            }
            setOnClickListener { showEventEditorDialog(occurrence) }
            setOnLongClickListener {
                openScheme(occurrence.optString("scheme_id"))
                true
            }
        }
    }

    private fun renderSchemeEditor(scheme: JSONObject): LinearLayout {
        val schemeId = scheme.optString("id")
        val readOnly = scheme.optBoolean("is_read_only", false)
        val originalLines = documentLines(scheme)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChip("<") {
                activeEditor()?.let { commitSchemeDocument(schemeId, it, rerender = false) }
                selectedSchemeId = null
                render()
            })
            addView(View(this@MainActivity), LinearLayout.LayoutParams(0, 1, 1f))
            if (!readOnly) {
                addView(iconChip("+") {
                    activeEditor()?.let(::insertTaskLine) ?: showItemDialog(schemeId, null)
                })
            }
            addView(chip("More") { showSchemeActions(scheme) }, LinearLayout.LayoutParams(dp(64), dp(28)).apply { setMargins(dp(6), 0, 0, 0) })
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val editor = SchemeEditText(this).apply {
            setText(renderDocument(originalLines))
            placeCursorAtDocumentEnd(this)
            tag = originalLines
            editorSchemeIds[this] = schemeId
            editorTheme = theme
            accentColor = editorChromeColor()
            lineAdornments = editorLineAdornments(scheme, timeFormat24())
            markerTapHandler = { lineIndex -> toggleEditorLineMarker(this, lineIndex) }
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
                    hidePhoneDockForEditing()
                } else {
                    showPhoneDockAfterEditing()
                    commitSchemeDocument(schemeId, this, rerender = true)
                }
            }
        }
        val editorBody = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, 0)
            addView(schemeTitleBlock(scheme), LinearLayout.LayoutParams(-1, -2).apply {
                setMargins(dp(EDITOR_TEXT_LEFT_PAD_DP), 0, dp(24), dp(1))
            })
            addView(editor, LinearLayout.LayoutParams(-1, -2))
        }
        val editorScroll = scroll(editorBody)
        root.addView(editorScroll, LinearLayout.LayoutParams(-1, 0, 1f))
        editorScroll.post {
            placeCursorAtDocumentEnd(editor)
            editorScroll.fullScroll(View.FOCUS_DOWN)
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

    private fun schemeTitleBlock(scheme: JSONObject): View {
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

    private fun renderDaily(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChip("<") {
                selectedDate = selectedDate.minusDays(1)
                ensureDaily()
            })
            addView(text(MobileDateFormatting.fullDay(selectedDate.toString()), theme.textPrimary, 14f, true).apply {
                gravity = Gravity.CENTER
                setOnClickListener { showDatePicker() }
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(iconChip("+") {
                activeEditor()?.let(::insertTaskLine)
                    ?: dailyScheme()?.let { scheme ->
                        mutate(obj("type" to "add_item", "scheme_id" to scheme.optString("id"), "text" to "", "marker" to "checkbox"))
                    }
            })
            addView(iconChip(">") {
                selectedDate = selectedDate.plusDays(1)
                ensureDaily()
            }, LinearLayout.LayoutParams(dp(32), dp(28)).apply { setMargins(dp(6), 0, 0, 0) })
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val list = MaxWidthLinearLayout(this, dp(760)).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(8), dp(14), dp(14))
            setBackgroundColor(theme.bgApp)
        }
        val days = dailyEntries()
        if (days.isEmpty()) {
            list.addView(emptyState("Daily not ready", "Could not create the daily queue."))
        } else {
            days.forEach { day ->
                list.addView(dailyDayEditor(day), LinearLayout.LayoutParams(-1, -2).apply {
                    setMargins(0, 0, 0, dp(6))
                })
            }
        }
        root.addView(scroll(list), LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(editorFormatBar(), LinearLayout.LayoutParams(-1, dp(38)))
        return root
    }

    private fun dailyDayEditor(day: JSONObject): View {
        val date = day.optString("date")
        val scheme = day.optJSONObject("scheme") ?: return emptyState(MobileDateFormatting.fullDay(date), "Daily not ready")
        val schemeId = scheme.optString("id")
        val selected = date == selectedDate.toString()
        val originalLines = documentLines(scheme)
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(6), 0, dp(6), dp(3))
                addView(View(this@MainActivity).apply {
                    background = rounded(if (selected) dailyAccent() else theme.divider, dp(4))
                }, LinearLayout.LayoutParams(dp(7), dp(7)).apply {
                    setMargins(0, 0, dp(8), 0)
                })
                addView(text(MobileDateFormatting.fullDay(date), if (selected) theme.textPrimary else theme.textDim, 13f, true), LinearLayout.LayoutParams(0, -2, 1f))
                if ((scheme.optJSONArray("items")?.length() ?: 0) == 0) {
                    addView(text("+", theme.textMuted, 13f, true).apply { gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(22), dp(22)))
                }
                setOnClickListener {
                    runCatching { LocalDate.parse(date) }.getOrNull()?.let {
                        selectedDate = it
                        loadSnapshot()
                        render()
                    }
                }
            })
            val editor = SchemeEditText(this@MainActivity).apply {
                setText(renderDocument(originalLines))
                placeCursorAtDocumentEnd(this)
                tag = originalLines
                editorSchemeIds[this] = schemeId
                editorTheme = theme
                accentColor = editorChromeColor()
                lineAdornments = editorLineAdornments(scheme, timeFormat24())
                markerTapHandler = { lineIndex -> toggleEditorLineMarker(this, lineIndex) }
                gravity = Gravity.TOP or Gravity.START
                setTextColor(theme.textPrimary)
                setHintTextColor(theme.textMuted)
                hint = "Start typing"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                setSingleLine(false)
                imeOptions = EditorInfo.IME_ACTION_DONE
                setTextSize(16f)
                setHorizontallyScrolling(false)
                setPadding(dp(EDITOR_TEXT_LEFT_PAD_DP), dp(8), dp(18), dp(12))
                setLineSpacing(0f, 1f)
                minHeight = dailyEditorHeight(scheme)
                isVerticalScrollBarEnabled = false
                overScrollMode = View.OVER_SCROLL_NEVER
                background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(7))
                setOnFocusChangeListener { _, hasFocus ->
                    if (hasFocus) {
                        hidePhoneDockForEditing()
                    } else {
                        showPhoneDockAfterEditing()
                        commitSchemeDocument(schemeId, this, rerender = false)
                    }
                }
            }
            if (selected) {
                editor.post { placeCursorAtDocumentEnd(editor) }
            }
            addView(editor, LinearLayout.LayoutParams(-1, -2))
        }
    }

    private fun dailyEditorHeight(scheme: JSONObject): Int {
        val items = scheme.optJSONArray("items")
        var visualLines = 1
        if (items != null && items.length() > 0) {
            visualLines = 0
            for (index in 0 until items.length()) {
                val textLength = items.optJSONObject(index)?.optString("text")?.length ?: 0
                visualLines += max(1, (max(textLength, 1) + 33) / 34)
            }
        }
        return dp(max(92, visualLines * 24 + 28))
    }

    private fun dailyAccent(): Int = if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)

    private fun renderSearch(): View {
        val root = page()
        val query = edit("").apply {
            hint = "Search KnotQ"
            setSingleLine(true)
            background = rounded(theme.bgModal, dp(7), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
        }
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(query, LinearLayout.LayoutParams(-1, dp(46)).apply { setMargins(0, 0, 0, dp(10)) })
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
                true
            } else {
                false
            }
        }
        query.setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) searchNow() }
        return root
    }

    private fun renderSearchResults(results: LinearLayout, query: String) {
        results.removeAllViews()
        try {
            val hits = bridge.requestArray(obj("type" to "search", "query" to query))
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

    private fun showSyncAccountDialog() {
        if (syncSession != null) {
            val session = syncSession ?: return
            val actions = mutableListOf("Sync now", "Sign out", "Delete account")
            if (session.supportsSync) {
                actions.add(1, "Cancel subscription")
            } else {
                actions.add(1, "Subscribe with Google Play")
                actions.add(2, "Restore purchases")
            }
            AlertDialog.Builder(this)
                .setTitle("Sync account")
                .setMessage("Signed in as ${session.email}\n${session.apiBase}")
                .setItems(actions.toTypedArray()) { _, which ->
                    when (actions[which]) {
                        "Sync now" -> syncOnce()
                        "Subscribe with Google Play" -> startGooglePlaySubscribe()
                        "Restore purchases" -> restoreGooglePlayPurchases()
                        "Cancel subscription" -> confirmCancelSyncSubscription()
                        "Sign out" -> signOutSync()
                        "Delete account" -> confirmDeleteSyncAccount()
                    }
                }
                .setNegativeButton("Close", null)
                .show()
            return
        }

        syncLoginChallenge?.let {
            showLoginCodeDialog(it)
            return
        }

        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
        }
        val api = EditText(this).apply {
            setText(DEFAULT_SYNC_API_BASE)
            hint = "Sync API"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine(true)
        }
        val email = EditText(this).apply {
            hint = "Email"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
            setSingleLine(true)
        }
        val password = EditText(this).apply {
            hint = "Password"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine(true)
        }
        form.addView(api)
        form.addView(email)
        form.addView(password)

        val dialog = AlertDialog.Builder(this)
            .setTitle("Sign in")
            .setView(form)
            .setNegativeButton("Cancel", null)
            .setNeutralButton("Create account", null)
            .setPositiveButton("Sign in", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                dialog.dismiss()
                signInToSync(api.text.toString(), email.text.toString(), password.text.toString())
            }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                dialog.dismiss()
                createSyncAccount(api.text.toString(), email.text.toString(), password.text.toString())
            }
        }
        dialog.show()
    }

    private fun signInToSync(apiBaseRaw: String, emailRaw: String, password: String) {
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

    private fun createSyncAccount(apiBaseRaw: String, emailRaw: String, password: String) {
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

    private fun showLoginCodeDialog(challenge: SyncLoginChallenge) {
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

    private fun verifyLoginCode(codeRaw: String) {
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

    private fun installSyncSession(session: SyncSession) {
        syncSession = session
        saveSyncSession(session)
        startSyncPolling()
        render()
    }

    private fun signOutSync() {
        syncSession = null
        syncLoginChallenge = null
        saveSyncSession(null)
        syncPollHandler.removeCallbacks(syncPollRunnable)
        render()
    }

    private fun confirmCancelSyncSubscription() {
        AlertDialog.Builder(this)
            .setTitle("Cancel sync subscription?")
            .setMessage("Your local workspace stays on this device. Paid sync may remain available until the current billing period ends.")
            .setNegativeButton("Keep sync", null)
            .setPositiveButton("Cancel subscription") { _, _ -> cancelSyncSubscription() }
            .show()
    }

    private fun confirmDeleteSyncAccount() {
        AlertDialog.Builder(this)
            .setTitle("Delete account?")
            .setMessage("Your account and synced data are scheduled for deletion. You have 14 days to undo this by signing back in before everything is permanently erased.")
            .setNegativeButton("Keep account", null)
            .setPositiveButton("Delete account") { _, _ -> deleteSyncAccount() }
            .show()
    }

    private fun cancelSyncSubscription() {
        val session = syncSession ?: return
        if (syncAccountActionInProgress) return
        syncAccountActionInProgress = true
        Thread {
            val result = runCatching {
                val active = refreshSyncSessionIfNeeded(session) ?: throw RuntimeException(accountActionErrorMessage("unauthorized"))
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
                result.onSuccess { updated ->
                    installSyncSession(updated)
                    if (updated.supportsSync) {
                        showError("Subscription cancelled", "Sync remains available until the current billing period ends.")
                    } else {
                        showError("Sync turned off", "Your local workspace stays on this device, and you can sign in again later to re-enable sync.")
                    }
                }.onFailure { error ->
                    showError("Could not update account", error.message)
                }
            }
        }.start()
    }

    // --- Google Play billing ---

    private val purchasesUpdatedListener = PurchasesUpdatedListener { result, purchases ->
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

    private fun ensureBillingClient(onReady: (BillingClient) -> Unit) {
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

    private fun startGooglePlaySubscribe() {
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

    private fun restoreGooglePlayPurchases() {
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
    private fun verifyGooglePlayPurchase(purchase: Purchase) {
        val session = syncSession
        if (session == null) {
            runOnUiThread { purchaseInProgress = false }
            return
        }
        Thread {
            val result = runCatching {
                val active = refreshSyncSessionIfNeeded(session)
                    ?: throw RuntimeException(accountActionErrorMessage("unauthorized"))
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

    private fun deleteSyncAccount() {
        val session = syncSession ?: return
        if (syncAccountActionInProgress) return
        syncAccountActionInProgress = true
        Thread {
            val result = runCatching {
                val active = refreshSyncSessionIfNeeded(session) ?: throw RuntimeException(accountActionErrorMessage("unauthorized"))
                httpJson(
                    "${active.apiBase}/v1/auth/account",
                    "DELETE",
                    JSONObject().put("confirm_email", active.email),
                    bearerToken = active.bearerToken,
                    accountAction = true
                )
            }
            runOnUiThread {
                syncAccountActionInProgress = false
                result.onSuccess {
                    signOutSync()
                    showError("Account deletion scheduled", "Sign in again within 14 days to cancel deletion. After that, synced data is permanently erased.")
                }.onFailure { error ->
                    showError("Could not delete account", error.message)
                }
            }
        }.start()
    }

    private fun startSyncPolling() {
        syncPollHandler.removeCallbacks(syncPollRunnable)
        if (syncSession != null) {
            syncOnce()
            syncPollHandler.postDelayed(syncPollRunnable, 30_000)
        }
    }

    private fun syncOnce() {
        // The in-progress guard also serializes refresh: two concurrent refreshes
        // would replay the same single-use refresh token and trip the server's
        // reuse detection, revoking the session.
        if (syncInProgress) return
        val session = syncSession ?: return
        if (!session.supportsSync) return
        syncInProgress = true
        Thread {
            // Refresh the short-lived access token if near expiry (rotating +
            // persisting the new credentials), or sign out if the refresh token is
            // dead.
            val active = refreshSyncSessionIfNeeded(session)
            if (active == null) {
                runOnUiThread {
                    syncInProgress = false
                    syncSession = null
                    saveSyncSession(null)
                    syncPollHandler.removeCallbacks(syncPollRunnable)
                    showError("Sync session expired", "Please sign in again.")
                    render()
                }
                return@Thread
            }
            if (active !== session) {
                runOnUiThread {
                    syncSession = active
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
                    val changed = response.optBoolean("changed", false)
                    if (changed) {
                        loadSnapshot()
                        rescheduleNotifications()
                        render()
                    }
                    val notice = response.optString("notice", "")
                    if (notice.isNotEmpty()) {
                        showError("Sync snapshot applied", notice)
                    }
                }.onFailure { error ->
                    showError("Sync failed", error.message)
                }
            }
        }.start()
    }

    // Runs on a background thread (blocking HTTP). Returns null if the session is
    // gone (refresh token dead) and the caller should sign out; otherwise the
    // session to use — the original (no refresh needed / transient failure) or a
    // copy carrying the rotated credentials.
    private fun refreshSyncSessionIfNeeded(session: SyncSession): SyncSession? {
        val refreshToken = session.refreshToken
        if (refreshToken.isEmpty()) return null
        if (!tokenNeedsRefresh(session.expiresAt)) return session
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
            if (status == 401) return null
            if (status !in 200..299) return session
            val raw = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(raw)
            return session.copy(
                bearerToken = requiredString(json, "bearer_token"),
                expiresAt = requiredString(json, "expires_at"),
                refreshToken = requiredString(json, "refresh_token"),
                refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null },
                supportsSync = json.optBoolean("supports_sync", true)
            )
        } catch (error: Exception) {
            // Network/parse hiccup: keep the current token, retry next tick.
            return session
        }
    }

    private fun tokenNeedsRefresh(expiresAt: String): Boolean {
        val expiry = runCatching { java.time.Instant.parse(expiresAt) }.getOrNull() ?: return true
        return expiry.isBefore(java.time.Instant.now().plusSeconds(120))
    }

    private fun requestSyncLoginStart(apiBase: String, email: String, password: String): SyncLoginStart {
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

    private fun parseSyncSession(json: JSONObject, apiBase: String): SyncSession =
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

    private fun requiredString(json: JSONObject, key: String): String =
        json.optString(key).takeIf { it.isNotEmpty() }
            ?: throw RuntimeException("Sync API response missing $key.")

    private fun httpJson(
        urlString: String,
        method: String,
        body: JSONObject,
        bearerToken: String? = null,
        accountAction: Boolean = false
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
            throw RuntimeException(if (accountAction) accountActionErrorMessage(code) else syncErrorMessage(code))
        }
        return if (raw.isBlank()) JSONObject() else JSONObject(raw)
    }

    private fun loadSyncSession(): SyncSession? {
        val raw = getSharedPreferences("knotq", MODE_PRIVATE).getString(SYNC_SESSION_PREF, null)
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

    private fun saveSyncSession(session: SyncSession?) {
        val prefs = getSharedPreferences("knotq", MODE_PRIVATE).edit()
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

    private fun normalizeApiBase(raw: String): String =
        raw.trim().trimEnd('/')

    private fun syncErrorMessage(code: String): String = when (code) {
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

    private fun accountActionErrorMessage(code: String): String = when (code) {
        "unauthorized" -> "Your sync session expired. Sign in again, then retry."
        "delete_confirmation_mismatch" -> "Could not confirm the account. Please try again."
        "billing_api_not_configured" -> "Subscription cancellation is not configured yet."
        "cancel_in_app_store" -> "Manage this App Store subscription from your account subscriptions."
        else -> "The request to the sync API failed."
    }

    private fun startGoogleCalendarImport(parentId: String? = null) {
        if (googleAuthInProgress) return
        googleAuthInProgress = true
        Thread {
            val result = runCatching {
                bridge.request(
                    obj(
                        "type" to "google_auth_request",
                        "client_id" to GOOGLE_CLIENT_ID,
                        "redirect_uri" to GOOGLE_REDIRECT_URI
                    )
                )
            }
            runOnUiThread {
                result.onSuccess { request ->
                    pendingGoogleAuthRequest = request
                    pendingGoogleParentId = parentId
                    savePendingGoogleAuth(request, parentId)
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(request.getString("auth_url"))))
                    } catch (error: ActivityNotFoundException) {
                        googleAuthInProgress = false
                        clearPendingGoogleAuth()
                        showError("Google Calendar", error.message)
                    }
                }.onFailure { error ->
                    googleAuthInProgress = false
                    showError("Google Calendar", error.message)
                }
            }
        }.start()
    }

    private fun handleGoogleCallback(uri: Uri?) {
        if (uri == null || uri.scheme != GOOGLE_REDIRECT_SCHEME) return
        val request = pendingGoogleAuthRequest ?: loadPendingGoogleAuthRequest()
        val parentId = pendingGoogleParentId ?: loadPendingGoogleParentId()
        if (request == null) {
            googleAuthInProgress = false
            showError("Google Calendar", "Google OAuth callback arrived without a pending request.")
            return
        }
        completeGoogleCalendarImport(request, uri.toString(), parentId)
    }

    private fun completeGoogleCalendarImport(request: JSONObject, callbackUrl: String, parentId: String?) {
        googleAuthInProgress = true
        Thread {
            val result = runCatching {
                bridge.request(
                    obj(
                        "type" to "complete_google_calendar_import",
                        "client_id" to request.getString("client_id"),
                        "client_secret" to googleClientSecret(),
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

    private fun syncGoogleCalendars(silent: Boolean = false) {
        if (googleSyncInProgress) return
        if ((snapshot.optJSONObject("settings")?.optInt("google_account_count", 0) ?: 0) <= 0) return
        googleSyncInProgress = true
        Thread {
            val result = runCatching {
                bridge.request(
                    obj(
                        "type" to "sync_google_calendars",
                        "client_id" to GOOGLE_CLIENT_ID,
                        "client_secret" to googleClientSecret()
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

    private fun configureGoogleSyncPolling() {
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

    private fun savePendingGoogleAuth(request: JSONObject, parentId: String?) {
        getSharedPreferences("knotq", MODE_PRIVATE).edit()
            .putString("knotq.googleAuthRequest", request.toString())
            .putString("knotq.googleAuthParentId", parentId)
            .apply()
    }

    private fun loadPendingGoogleAuthRequest(): JSONObject? {
        val raw = getSharedPreferences("knotq", MODE_PRIVATE).getString("knotq.googleAuthRequest", null)
            ?: return null
        return runCatching { JSONObject(raw) }.getOrNull()
    }

    private fun loadPendingGoogleParentId(): String? =
        getSharedPreferences("knotq", MODE_PRIVATE).getString("knotq.googleAuthParentId", null)

    private fun clearPendingGoogleAuth() {
        pendingGoogleAuthRequest = null
        pendingGoogleParentId = null
        getSharedPreferences("knotq", MODE_PRIVATE).edit()
            .remove("knotq.googleAuthRequest")
            .remove("knotq.googleAuthParentId")
            .apply()
    }

    private fun googleClientSecret(): String? = null

    private fun renderSettings(): LinearLayout {
        val root = page()
        root.addView(sectionHeader("Settings"))
        root.addView(text("KnotQ Mobile", theme.textSoft, 11f, false), spaced())
        val settings = snapshot.optJSONObject("settings")
        val themeMode = settings?.optString("theme_mode", "dark") ?: "dark"
        val timeFormat = settings?.optString("time_format", "twelve_hour") ?: "twelve_hour"
        val eventOffset = settings?.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
            ?: DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS
        val assignmentOffset = settings?.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
            ?: DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
        val googleAccountCount = settings?.optInt("google_account_count", 0) ?: 0

        root.addView(settingsSection("Appearance"))
        root.addView(choiceRow("System", themeMode == "system") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "system")) })
        root.addView(choiceRow("Dark", themeMode == "dark") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "dark")) })
        root.addView(choiceRow("Light", themeMode == "light") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "light")) })

        root.addView(settingsSection("Time"))
        root.addView(choiceRow("12-hour", timeFormat == "twelve_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twelve_hour")) })
        root.addView(choiceRow("24-hour", timeFormat == "twenty_four_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twenty_four_hour")) })

        root.addView(settingsSection("Notifications"))
        root.addView(choiceRow("Events: ${notificationLeadTimeLabel(eventOffset, eventDefault = true)}", false) {
            showNotificationDefaultDialog("Event reminders", eventOffset, eventDefaultNotificationOptions) { next ->
                mutate(
                    obj(
                        "type" to "set_notification_defaults",
                        "event_offset_secs" to next,
                        "assignment_offset_secs" to assignmentOffset
                    )
                )
            }
        })
        root.addView(choiceRow("Assignments: ${notificationLeadTimeLabel(assignmentOffset, eventDefault = false)}", false) {
            showNotificationDefaultDialog("Assignment reminders", assignmentOffset, assignmentDefaultNotificationOptions) { next ->
                mutate(
                    obj(
                        "type" to "set_notification_defaults",
                        "event_offset_secs" to eventOffset,
                        "assignment_offset_secs" to next
                    )
                )
            }
        })

        root.addView(settingsSection("Google Calendar"))
        if (googleAccountCount > 0) {
            root.addView(choiceRow("Connected accounts: $googleAccountCount", true) {
                syncGoogleCalendars()
            })
            googleCalendarStatus?.takeIf { it.isNotBlank() }?.let { status ->
                root.addView(text(status, theme.textMuted, 12f, false).apply {
                    setPadding(dp(8), dp(3), dp(8), dp(6))
                })
            }
            root.addView(choiceRow(if (googleSyncInProgress) "Syncing Google Calendars" else "Sync Google Calendars", false) {
                syncGoogleCalendars()
            })
            root.addView(choiceRow(if (googleAuthInProgress) "Connecting Google Calendar" else "Connect another Google Calendar", false) {
                startGoogleCalendarImport()
            })
        } else {
            root.addView(choiceRow(if (googleAuthInProgress) "Connecting Google Calendar" else "Connect Google Calendar", false) {
                startGoogleCalendarImport()
            })
        }

        root.addView(settingsSection("Archive"))
        val schemes = archivedSchemes()
        root.addView(choiceRow("Archived schemes ${schemes.length()}", false) {
            showArchiveSettingsDialog()
        })

        root.addView(settingsSection("Sync"))
        val session = syncSession
        val syncLabel = when {
            session == null -> "Sign in to Sync"
            session.supportsSync -> "Signed in: ${session.email}"
            else -> "Signed in: ${session.email} (sync off)"
        }
        root.addView(choiceRow(syncLabel, session != null) {
            showSyncAccountDialog()
        })
        return root
    }

    private fun showNotificationDefaultDialog(
        title: String,
        current: Int,
        options: List<NotificationLeadTimeOption>,
        onSelect: (Int) -> Unit
    ) {
        val labels = options.map { option ->
            if (option.offsetSecs == current) "${option.label} ✓" else option.label
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(labels) { _, which -> onSelect(options[which].offsetSecs) }
            .show()
    }

    private fun addNode(parent: LinearLayout, node: JSONObject, depth: Int, spacious: Boolean = false) {
        val kind = node.optString("kind")
        if (kind == "folder") {
            parent.addView(folderRow(node, depth, spacious), if (spacious) LinearLayout.LayoutParams(-1, dp(30)) else rowParams())
            node.optJSONArray("children")?.forEachObject { addNode(parent, it, depth + 1, spacious) }
            return
        }
        val selected = selectedSchemeId == node.optString("id")
        val rowHeight = if (spacious) dp(30) else dp(22)
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 8 else 6) + depth * if (spacious) 10 else 8), 0, dp(7), 0)
            background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(4))
            val squareSize = 9
            addView(colorSquare(schemeColor(node.optInt("color_index")), squareSize), LinearLayout.LayoutParams(dp(squareSize), dp(squareSize)))
            addView(text(node.optString("name"), if (selected) theme.textPrimary else theme.textDim, if (spacious) 13f else 12f, false).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(7), 0, dp(4), 0)
            })
            setOnClickListener { openScheme(node.optString("id")) }
            setOnLongClickListener {
                showSchemeActions(node)
                true
            }
        }
        parent.addView(row, LinearLayout.LayoutParams(-1, rowHeight))
    }

    private fun folderRow(node: JSONObject, depth: Int, spacious: Boolean = false): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 8 else 6) + depth * if (spacious) 10 else 8), 0, dp(7), 0)
            addView(text(if (spacious) "⌄" else "▾", theme.textMuted, if (spacious) 13f else 12f, true).apply {
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(dp(if (spacious) 14 else 12), -1))
            addView(text(node.optString("name"), theme.textPrimary, if (spacious) 13f else 12f, false).apply {
                maxLines = 1
            }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (spacious) 7 else 6), 0, 0, 0)
            })
            setOnLongClickListener {
                showFolderActions(node)
                true
            }
        }
    }

    private fun itemRow(schemeId: String, item: JSONObject, index: Int, count: Int): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(dp(8 + item.optInt("indent") * 18), dp(7), dp(8), dp(7))
            background = rounded(if (index % 2 == 1) theme.rowAlt else Color.TRANSPARENT, dp(3))
            addView(iconChip(if (item.optBoolean("done")) "x" else markerLabel(item.optString("marker"))) {
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

    private fun editorFormatBar(schemeId: String? = null, editor: EditText? = null): View {
        fun targetEditor(): EditText? = editor ?: activeEditor()
        fun targetSchemeId(): String? = schemeId ?: targetEditor()?.let { editorSchemeIds[it] }
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(theme.bgToolbar)
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
                addView(formatButton("B") { targetEditor()?.let { toggleWrappedMarkdown(it, "*") } })
                addView(formatButton("I") { targetEditor()?.let { toggleWrappedMarkdown(it, "_") } })
                addView(formatButton("H") { targetEditor()?.let { toggleHeading(it) } })
                addView(formatDivider())
                addView(formatButton("T") { targetEditor()?.let { setCurrentLineMarker(it, "blank") } })
                addView(formatButton("✓") { targetEditor()?.let { setCurrentLineMarker(it, "checkbox") } })
                addView(formatButton("•") { targetEditor()?.let { setCurrentLineMarker(it, "bullet") } })
                addView(formatButton("1.") { targetEditor()?.let { setCurrentLineMarker(it, "numbered") } })
                addView(formatDivider())
                addView(formatButton("⇤") { targetEditor()?.let { shiftCurrentLineIndent(it, -1) } })
                addView(formatButton("⇥") { targetEditor()?.let { shiftCurrentLineIndent(it, 1) } })
                addView(formatDivider())
                addView(formatButton("◷") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) openDateForEditorLine(targetId, target)
                })
                addView(formatButton("+") { targetEditor()?.let(::insertTaskLine) })
                addView(formatDivider())
                addView(formatButton("⌄") {
                    val target = targetEditor()
                    val targetId = targetSchemeId()
                    if (target != null && targetId != null) commitSchemeDocument(targetId, target, rerender = true)
                    target?.clearFocus()
                })
            })
        }
    }

    private fun activeEditor(): EditText? = currentFocus as? EditText

    private fun formatButton(label: String, action: () -> Unit): TextView =
        text(label, theme.textPrimary, 12f, true).apply {
            gravity = Gravity.CENTER
            background = rounded(theme.buttonBg, dp(5))
            setOnClickListener { action() }
            layoutParams = LinearLayout.LayoutParams(dp(29), dp(27)).apply {
                setMargins(0, 0, dp(5), 0)
            }
        }

    private fun formatDivider(): View = View(this).apply {
        setBackgroundColor(theme.dividerSoft)
        layoutParams = LinearLayout.LayoutParams(dp(1), dp(18)).apply {
            setMargins(dp(1), 0, dp(6), 0)
        }
    }

    private fun setCurrentLineMarker(editor: EditText, marker: String) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            val nextDone = marker == "checkbox" && line.marker == "checkbox" && !line.done
            renderEditorLine(line.copy(marker = marker, done = nextDone), 1)
        }
    }

    private fun toggleEditorLineMarker(editor: EditText, lineIndex: Int) {
        editLine(editor, lineIndex) { raw ->
            val line = parseEditorLine(raw)
            if (line.marker == "checkbox") {
                renderEditorLine(line.copy(done = !line.done), 1)
            } else {
                renderEditorLine(line.copy(marker = "checkbox", done = false), 1)
            }
        }
    }

    private fun toggleWrappedMarkdown(editor: EditText, delimiter: String) {
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

    private fun toggleHeading(editor: EditText) {
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

    private fun shiftCurrentLineIndent(editor: EditText, delta: Int) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            renderEditorLine(line.copy(indent = (line.indent + delta).coerceIn(0, 8)), 1)
        }
    }

    private fun insertTaskLine(editor: EditText) {
        val start = editor.logicalSelectionStart()
        val end = max(start, editor.selectionEnd)
        val prefix = if (start == 0 || editor.text.isEmpty()) "" else "\n"
        editor.text.replace(start, end, "${prefix}[ ] ")
        ensureTerminalNewline(editor.text, editor.selectionStart)
    }

    private fun editCurrentLine(editor: EditText, transform: (String) -> String) {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        val start = value.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newline = value.indexOf('\n', cursor)
        val end = if (newline < 0) value.length else newline
        val replacement = transform(value.substring(start, end))
        editor.text.replace(start, end, replacement)
        editor.setSelection((start + replacement.length).coerceAtMost(editor.text.length))
    }

    private fun editLine(editor: EditText, lineIndex: Int, transform: (String) -> String) {
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

    private fun openDateForEditorLine(schemeId: String, editor: EditText) {
        commitSchemeDocument(schemeId, editor, rerender = false)
        val line = currentLineIndex(editor)
        val item = findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(line) ?: return
        showDateKindDialog(schemeId, item.optString("id"))
    }

    private fun currentLineIndex(editor: EditText): Int {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        return value.substring(0, cursor).count { it == '\n' }
    }

    private fun EditText.logicalSelectionStart(): Int {
        val value = text?.toString().orEmpty()
        val raw = max(0, selectionStart).coerceAtMost(value.length)
        return if (raw == value.length && value.endsWith("\n")) max(0, raw - 1) else raw
    }

    private fun ensureTerminalNewline(editable: Editable, preferredSelection: Int? = null) {
        if (editable.isNotEmpty() && editable.last() == '\n') return
        val selection = (preferredSelection ?: editable.length).coerceIn(0, editable.length)
        editable.append("\n")
        activeEditor()?.setSelection(selection.coerceAtMost(editable.length))
    }

    private fun placeCursorAtDocumentEnd(editor: EditText) {
        val value = editor.text?.toString().orEmpty()
        val location = if (value.endsWith("\n")) max(0, value.length - 1) else value.length
        editor.setSelection(location.coerceIn(0, editor.text?.length ?: 0))
    }

    private fun commitSchemeDocument(schemeId: String, editor: EditText, rerender: Boolean) {
        ensureTerminalNewline(editor.text, editor.selectionStart)
        val oldLines = (editor.tag as? List<*>)?.filterIsInstance<SchemeEditorLine>().orEmpty()
        val nextLines = reconcileEditorLines(oldLines, parseEditorDocument(editor.text.toString(), preserveBlankDocument = oldLines.isNotEmpty()))
        val array = JSONArray()
        nextLines.forEach { line ->
            val existing = line.id?.let { findItem(schemeId, it) }
            array.put(obj(
                "id" to line.id,
                "text" to line.text,
                "marker" to line.marker,
                "indent" to line.indent,
                "done" to line.done,
                "start" to existing?.optionalString("start"),
                "end" to existing?.optionalString("end"),
                "notification_offset_secs" to existing?.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs"),
                "repeat_rule" to existing?.optionalString("repeat_rule"),
                "media" to (existing?.optJSONArray("media") ?: JSONArray())
            ))
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
        } catch (error: RuntimeException) {
            toast(error.message)
        }
    }

    private fun occurrenceRow(occurrence: JSONObject, striped: Boolean): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(if (striped) theme.rowAlt else Color.TRANSPARENT, dp(3))
            alpha = if (occurrence.optBoolean("done")) 0.45f else 1f
            addView(View(this@MainActivity).apply { setBackgroundColor(schemeColor(occurrence.optInt("color_index"))) }, LinearLayout.LayoutParams(dp(2), -1).apply {
                setMargins(dp(4), dp(8), dp(6), dp(8))
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(7), dp(8), dp(7))
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(text(occurrence.optString("scheme_name"), schemeColor(occurrence.optInt("color_index")), 11f, true), LinearLayout.LayoutParams(0, -2, 1f))
                    addView(text(MobileDateFormatting.occurrenceLabel(occurrence, timeFormat24()), theme.textSoft, 10f, true))
                })
                addView(text(occurrence.optString("title").ifEmpty { occurrence.optString("kind").replaceFirstChar(Char::titlecase) }, theme.textPrimary, 13f, false))
            }, LinearLayout.LayoutParams(0, -2, 1f))
            setOnClickListener { showEventEditorDialog(occurrence) }
            setOnLongClickListener {
                AlertDialog.Builder(this@MainActivity)
                    .setTitle(occurrence.optString("title").ifEmpty { occurrence.optString("kind").replaceFirstChar(Char::titlecase) })
                    .setItems(arrayOf("Toggle Done", "Open Scheme")) { _, which ->
                        when (which) {
                            0 -> mutate(obj(
                                "type" to "toggle_occurrence",
                                "scheme_id" to occurrence.optString("scheme_id"),
                                "item_id" to occurrence.optString("item_id"),
                                "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}")
                            ))
                            1 -> openScheme(occurrence.optString("scheme_id"))
                        }
                    }
                    .show()
                true
            }
        }
    }

    private fun showNewMenu() {
        AlertDialog.Builder(this)
            .setTitle("New")
            .setItems(arrayOf("Calendar Item", "Item", "Scheme", "Folder")) { _, which ->
                when (which) {
                    0 -> showCalendarItemDialog()
                    1 -> {
                        val schemeId = if (selectedTab == TAB_DAILY) dailyScheme()?.optString("id") else selectedSchemeId
                        if (schemeId != null) showItemDialog(schemeId, null) else toast("Pick a scheme first")
                    }
                    2 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
                        mutate(obj("type" to "create_scheme", "name" to name, "position" to 0))
                    }
                    3 -> showNameDialog("New Folder", "", { validateFolderName(it) }) { name -> mutate(obj("type" to "create_folder", "name" to name)) }
                }
            }
            .show()
    }

    private fun showItemDialog(schemeId: String, item: JSONObject?) {
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

    private fun showCalendarItemDialog() {
        showEventEditorDialog(null)
    }

    private fun showEventEditorDialog(occurrence: JSONObject?) {
        val editing = occurrence != null
        val readOnly = occurrence?.optBoolean("is_read_only", false) == true
        val initialKind = occurrence?.optString("kind")?.takeIf { it.isNotEmpty() } ?: "task"
        val startDateTime = MobileDateFormatting.localDateTime(occurrence?.optionalString("start"))
        val endDateTime = MobileDateFormatting.localDateTime(occurrence?.optionalString("end"))
        val anchor = startDateTime ?: endDateTime ?: selectedDate.atStartOfDay(ZoneId.systemDefault())
        val titleInput = edit(occurrence?.optString("title") ?: "").apply {
            hint = "Title"
            isEnabled = !readOnly
        }
        val kindValues = arrayOf("event", "reminder", "assignment", "task")
        val kind = spinner(kindValues).apply {
            setSelection(kindValues.indexOf(initialKind).coerceAtLeast(0))
            isEnabled = !readOnly
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
        val date = DatePicker(this).apply {
            val local = anchor.toLocalDate()
            updateDate(local.year, local.monthValue - 1, local.dayOfMonth)
            isEnabled = !readOnly
        }
        val start = TimePicker(this).apply {
            setIs24HourView(timeFormat24())
            val local = startDateTime?.toLocalTime() ?: anchor.toLocalTime().takeIf { it != LocalTime.MIDNIGHT } ?: LocalTime.now().withSecond(0).withNano(0)
            hour = local.hour
            minute = local.minute
            isEnabled = !readOnly
        }
        val end = TimePicker(this).apply {
            setIs24HourView(timeFormat24())
            val local = endDateTime?.toLocalTime() ?: startDateTime?.toLocalTime()?.plusHours(1) ?: LocalTime.now().plusHours(1).withSecond(0).withNano(0)
            hour = local.hour
            minute = local.minute
            isEnabled = !readOnly
        }
        val repeatValues = arrayOf("none", "daily", "weekly", "monthly", "yearly")
        val repeat = spinner(repeatValues).apply {
            setSelection(repeatValues.indexOf(MobileRecurrence.repeatChoiceFromRrule(occurrence?.optionalString("repeat_rule"))).coerceAtLeast(0))
            isEnabled = !readOnly
        }
        val defaultOffset = defaultNotificationOffset(initialKind)
        val currentOffset = occurrence?.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs") ?: defaultOffset
        val notificationOptions = occurrenceNotificationOptionsIncluding(currentOffset)
        val notification = spinner(notificationOptions.map { it.label }.toTypedArray()).apply {
            setSelection(notificationOptions.indexOfFirst { it.offsetSecs == currentOffset }.coerceAtLeast(0))
            isEnabled = !readOnly
        }
        val completed = CheckBox(this).apply {
            text = "Completed"
            setTextColor(theme.textPrimary)
            isChecked = occurrence?.optBoolean("done", false) == true
            isEnabled = !readOnly
        }

        val form = page(compact = true).apply {
            setPadding(dp(18), dp(8), dp(18), 0)
            addView(titleInput, spaced())
            if (!editing) {
                addView(text("Scheme", theme.textMuted, 12f, true))
                addView(scheme, spaced())
            }
            addView(text("Type", theme.textMuted, 12f, true))
            addView(kind, spaced())
            addView(text("Date", theme.textMuted, 12f, true))
            addView(date, spaced())
            addView(text("Start / At", theme.textMuted, 12f, true))
            addView(start, spaced())
            addView(text("End / Due", theme.textMuted, 12f, true))
            addView(end, spaced())
            addView(text("Notification", theme.textMuted, 12f, true))
            addView(notification, spaced())
            addView(text("Repeat", theme.textMuted, 12f, true))
            addView(repeat, spaced())
            if (editing) addView(completed, spaced())
            if (readOnly) {
                addView(text("Imported calendar items are read-only.", theme.textMuted, 12f, false), spaced())
            }
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle(if (readOnly) "Task details" else if (editing) "Edit" else "New")
            .setView(scroll(form))
            .setNegativeButton(if (readOnly) "Done" else "Cancel", null)
            .setPositiveButton(if (readOnly) "Open Scheme" else "Save", null)
            .also { builder ->
                if (editing && !readOnly) {
                    builder.setNeutralButton("Delete", null)
                }
            }
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (readOnly) {
                    occurrence?.optString("scheme_id")?.let(::openScheme)
                    dialog.dismiss()
                    return@setOnClickListener
                }
                val selectedKind = kind.selectedItem.toString()
                val localDate = LocalDate.of(date.year, date.month + 1, date.dayOfMonth)
                val startValue = when (selectedKind) {
                    "event", "reminder" -> MobileDateFormatting.iso(localDate, start.hour, start.minute)
                    else -> null
                }
                val endValue = when (selectedKind) {
                    "event", "assignment" -> MobileDateFormatting.iso(localDate, end.hour, end.minute)
                    else -> null
                }
                val rrule = if (selectedKind == "task") null else MobileRecurrence.rruleForRepeat(repeat.selectedItem.toString(), localDate)
                val notificationOffset = if (selectedKind == "task") null else notificationOptions[notification.selectedItemPosition].offsetSecs
                if (occurrence != null) {
                    val commit = { scope: String ->
                        commitEventEdit(
                            occurrence = occurrence,
                            title = titleInput.text.toString().trim(),
                            start = startValue,
                            end = endValue,
                            rrule = rrule,
                            notificationOffsetSecs = notificationOffset,
                            notificationDirty = selectedKind != "task",
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
                        kind = selectedKind,
                        text = titleInput.text.toString().trim(),
                        date = localDate,
                        start = startValue,
                        end = endValue,
                        schemeId = schemeId
                    )
                    val resolvedScheme = schemeId ?: todayDailySchemeId()
                    if (newId != null && resolvedScheme != null) {
                        if (rrule != null) {
                            bridge.request(obj("type" to "set_item_recurrence", "scheme_id" to resolvedScheme, "item_id" to newId, "rrule" to rrule))
                        }
                        if (selectedKind != "task") {
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
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.setOnClickListener {
                if (occurrence == null) return@setOnClickListener
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
        }
        dialog.show()
    }

    private fun commitEventEdit(
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

    private fun deleteEventOccurrence(occurrence: JSONObject, scope: String) {
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

    private fun showOccurrenceScopeDialog(
        title: String,
        occurrence: JSONObject,
        forDelete: Boolean,
        onScope: (String) -> Unit
    ) {
        val choices = mutableListOf("This task" to "this_event")
        if (occurrence.optBoolean("can_delete_future", false)) {
            choices.add("This and future tasks" to "all_future")
        }
        choices.add("All tasks" to "all_events")
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(if (forDelete) "Which tasks should be deleted?" else "Which tasks should these changes apply to?")
            .setItems(choices.map { it.first }.toTypedArray()) { _, which ->
                onScope(choices[which].second)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun createCalendarItemReturningID(
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
        return schemeItemIds(targetId).firstOrNull { !before.contains(it) }
    }

    private fun schemeItemIds(schemeId: String): Set<String> {
        val ids = mutableSetOf<String>()
        findScheme(schemeId)?.optJSONArray("items")?.forEachObject { item ->
            ids.add(item.optString("id"))
        }
        return ids
    }

    private fun todayDailySchemeId(): String? {
        val today = LocalDate.now().toString()
        val daily = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until daily.length()) {
            val entry = daily.optJSONObject(index) ?: continue
            if (entry.optString("date") == today) return entry.optJSONObject("scheme")?.optString("id")
        }
        return null
    }

    private fun defaultNotificationOffset(kind: String): Int {
        val settings = snapshot.optJSONObject("settings")
        return when (kind) {
            "event" -> settings?.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS
            "assignment" -> settings?.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
            else -> 0
        }
    }

    private fun showMarkerDialog(schemeId: String, itemId: String) {
        val markers = arrayOf("checkbox", "blank", "bullet", "numbered")
        AlertDialog.Builder(this)
            .setTitle("Marker")
            .setItems(markers) { _, which ->
                mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to itemId, "marker" to markers[which]))
            }
            .show()
    }

    private fun showDateKindDialog(schemeId: String, itemId: String) {
        val kinds = arrayOf("Set Start", "Set End", "Clear Start", "Clear End", "Clear Both")
        AlertDialog.Builder(this)
            .setTitle("Date")
            .setItems(kinds) { _, which ->
                when (which) {
                    0 -> showItemDateDialog(schemeId, itemId, "start")
                    1 -> showItemDateDialog(schemeId, itemId, "end")
                    2 -> mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to "start", "date" to null))
                    3 -> mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to "end", "date" to null))
                    4 -> {
                        mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to "start", "date" to null))
                        mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to "end", "date" to null))
                    }
                }
            }
            .show()
    }

    private fun showItemDateDialog(schemeId: String, itemId: String, kind: String) {
        val form = page(compact = true)
        val initial = MobileDateFormatting.localDateTime(findItem(schemeId, itemId)?.optionalString(kind))
        val date = DatePicker(this).apply {
            val local = initial?.toLocalDate() ?: selectedDate
            updateDate(local.year, local.monthValue - 1, local.dayOfMonth)
        }
        val time = TimePicker(this).apply {
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

    private fun showItemActions(schemeId: String, item: JSONObject, index: Int, count: Int) {
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

    private fun showSchemeActions(nodeOrScheme: JSONObject) {
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
            .setItems(arrayOf("Rename", "Color", "Move Up", "Move Down", "Move To Folder", "Archive")) { _, which ->
                when (which) {
                    0 -> showNameDialog(
                        "Rename Scheme",
                        nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")),
                        { validateSchemeName(it, folderId = parentFolderIdForScheme(id), excludingId = id, checkDuplicates = !isDaily) }
                    ) { name -> mutate(obj("type" to "rename_scheme", "scheme_id" to id, "name" to name)) }
                    1 -> showColorDialog(id)
                    2 -> moveNavigatorNode("scheme", id, -1)
                    3 -> moveNavigatorNode("scheme", id, 1)
                    4 -> showMoveToFolderDialog("scheme", id)
                    5 -> if (!isDaily) mutate(obj("type" to "delete_scheme", "scheme_id" to id))
                }
            }
            .show()
    }

    private fun showColorDialog(schemeId: String) {
        val labels = arrayOf("Red", "Orange", "Green", "Blue", "Purple", "Yellow")
        AlertDialog.Builder(this)
            .setTitle("Color")
            .setItems(labels) { _, which ->
                mutate(obj("type" to "set_scheme_color", "scheme_id" to schemeId, "color_index" to which))
            }
            .show()
    }

    private fun showFolderActions(node: JSONObject) {
        AlertDialog.Builder(this)
            .setTitle(node.optString("name"))
            .setItems(arrayOf("New Scheme", "New Folder", "Rename", "Move Up", "Move Down", "Move To Folder", "Archive")) { _, which ->
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
                    3 -> moveNavigatorNode("folder", node.optString("id"), -1)
                    4 -> moveNavigatorNode("folder", node.optString("id"), 1)
                    5 -> showMoveToFolderDialog("folder", node.optString("id"), excludedFolderId = node.optString("id"))
                    6 -> mutate(obj("type" to "delete_folder", "folder_id" to node.optString("id")))
                }
            }
            .show()
    }

    private fun showArchiveActions() {
        AlertDialog.Builder(this)
            .setTitle("Archive")
            .setItems(arrayOf("Empty Archive")) { _, which ->
                if (which == 0) mutate(obj("type" to "empty_archive"))
            }
            .show()
    }

    private fun showArchiveSettingsDialog() {
        val schemes = archivedSchemes()
        if (schemes.length() == 0) {
            AlertDialog.Builder(this)
                .setTitle("Archive")
                .setMessage("No archived schemes")
                .setPositiveButton("OK", null)
                .show()
            return
        }
        val labels = mutableListOf<String>()
        schemes.forEachObject { scheme -> labels.add(scheme.optString("display_name")) }
        labels.add("Empty Archive")
        AlertDialog.Builder(this)
            .setTitle("Archive")
            .setItems(labels.toTypedArray()) { _, which ->
                if (which < schemes.length()) {
                    showArchivedSchemeActions(schemes.getJSONObject(which))
                } else {
                    mutate(obj("type" to "empty_archive"))
                }
            }
            .show()
    }

    private fun showArchivedSchemeActions(scheme: JSONObject) {
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

    private fun showNameDialog(title: String, initial: String, validator: (String) -> String?, callback: (String) -> Unit) {
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

    private fun showDatePicker() {
        DatePickerDialog(this, { _, year, month, day ->
            selectedDate = LocalDate.of(year, month + 1, day)
            ensureDaily()
        }, selectedDate.year, selectedDate.monthValue - 1, selectedDate.dayOfMonth).show()
    }

    private fun showMonthPickerDialog() {
        var displayMonth = selectedDate.withDayOfMonth(1)
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(12))
            setBackgroundColor(theme.bgApp)
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
            addView(iconChip("<") {
                displayMonth = displayMonth.minusMonths(1)
                renderMonth()
            })
            addView(title, LinearLayout.LayoutParams(0, dp(38), 1f))
            addView(iconChip(">") {
                displayMonth = displayMonth.plusMonths(1)
                renderMonth()
            })
        }, LinearLayout.LayoutParams(-1, dp(42)).apply {
            setMargins(0, 0, 0, dp(8))
        })
        container.addView(grid)

        dialog = AlertDialog.Builder(this)
            .setView(container)
            .setNegativeButton("Close", null)
            .create()
        renderMonth()
        dialog.show()
    }

    private fun monthWeekdayRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            listOf("S", "M", "T", "W", "T", "F", "S").forEach { label ->
                addView(text(label, theme.textMuted, 11f, true).apply {
                    gravity = Gravity.CENTER
                }, LinearLayout.LayoutParams(0, -1, 1f))
            }
        }

    private fun monthDayCell(date: LocalDate, displayMonth: LocalDate, occurrences: JSONArray, onSelect: () -> Unit): View {
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

    private fun monthOccurrenceDots(occurrences: JSONArray): View =
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

    private fun monthDayTextColor(inMonth: Boolean, highlighted: Boolean): Int =
        when {
            highlighted -> Color.WHITE
            inMonth -> theme.textPrimary
            else -> theme.textMuted
        }

    private fun monthDayOccurrences(month: LocalDate): Map<String, JSONArray> {
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

    private fun openScheme(id: String) {
        selectedTab = TAB_SCHEMES
        selectedSchemeId = id
        render()
    }

    private fun addDailyItemFromHome() {
        ensureDaily()
        dailyScheme()?.let { scheme ->
            showItemDialog(scheme.optString("id"), null)
        } ?: toast("Daily not ready")
    }

    private fun ensureDaily() {
        mutate(obj("type" to "ensure_daily_queue", "date" to selectedDate.toString()))
    }

    private fun ensureTodayDailyQueue() {
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

    private fun mutate(body: JSONObject) {
        try {
            bridge.request(body)
            loadSnapshot()
            rescheduleNotifications()
            render()
        } catch (error: RuntimeException) {
            showError("Could not save", error.message)
        }
    }

    private fun loadSnapshot() {
        snapshot = bridge.request(obj("type" to "snapshot", "today" to selectedDate.toString(), "week_offset" to weekOffset))
        configureGoogleSyncPolling()
    }

    private fun rescheduleNotifications() {
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

    private fun applyTheme() {
        val mode = snapshot.optJSONObject("settings")?.optString("theme_mode", "dark") ?: "dark"
        val darkSystem = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        theme = when (mode) {
            "light" -> UiTheme.light
            "system" -> if (darkSystem) UiTheme.dark else UiTheme.light
            else -> UiTheme.dark
        }
        applySystemBarColors()
    }

    @Suppress("DEPRECATION")
    private fun applySystemBarColors() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            window.statusBarColor = theme.bgToolbar
            window.navigationBarColor = theme.bgSidebar
        }
    }

    private fun calendar(): JSONObject = snapshot.optJSONObject("calendar") ?: JSONObject()

    private fun dailyScheme(): JSONObject? {
        val days = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until days.length()) {
            val day = days.optJSONObject(index)
            if (day != null && selectedDate.toString() == day.optString("date")) {
                return day.optJSONObject("scheme")
            }
        }
        return null
    }

    private fun dailyEntries(): List<JSONObject> {
        val days = snapshot.optJSONArray("daily") ?: return emptyList()
        val entries = ArrayList<JSONObject>(days.length())
        for (index in 0 until days.length()) {
            days.optJSONObject(index)?.let(entries::add)
        }
        entries.sortBy { it.optString("date") }
        return entries
    }

    private fun dailyEntryForHome(): JSONObject? {
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

    private fun archivedSchemes(): JSONArray = snapshot.optJSONArray("archived_schemes") ?: JSONArray()

    private fun findScheme(id: String): JSONObject? {
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

    private fun findItem(schemeId: String, itemId: String): JSONObject? {
        val items = findScheme(schemeId)?.optJSONArray("items") ?: return null
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index)
            if (item != null && itemId == item.optString("id")) return item
        }
        return null
    }

    private fun rootFolderId(): String? = snapshot.optJSONObject("root")?.optString("id")

    private fun parentFolderIdForScheme(schemeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForScheme(schemeId, root)
    }

    private fun parentFolderIdForScheme(schemeId: String, node: JSONObject): String? {
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

    private fun parentFolderIdForNode(nodeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForNode(nodeId, root)
    }

    private fun parentFolderIdForNode(nodeId: String, node: JSONObject): String? {
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

    private fun moveNavigatorNode(kind: String, nodeId: String, delta: Int) {
        val parentId = parentFolderIdForNode(nodeId) ?: return toast("Cannot move this item")
        val parent = nodeById(parentId, snapshot.optJSONObject("root")) ?: return toast("Cannot find parent")
        val children = parent.optJSONArray("children") ?: return toast("Cannot move this item")
        var index = -1
        for (i in 0 until children.length()) {
            if (children.optJSONObject(i)?.optString("id") == nodeId) {
                index = i
                break
            }
        }
        if (index < 0) return toast("Cannot move this item")
        val position = if (delta < 0) index - 1 else index + 2
        if (position < 0 || position > children.length()) return toast("Already there")
        mutate(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to parentId, "position" to position))
    }

    private fun showMoveToFolderDialog(kind: String, nodeId: String, excludedFolderId: String? = null) {
        val root = snapshot.optJSONObject("root") ?: return toast("Cannot move this item")
        val currentParentId = parentFolderIdForNode(nodeId) ?: return toast("Cannot move this item")
        val destinations = mutableListOf(FolderDestination(root.optString("id"), "Home", 0))
        collectFolderDestinations(root.optJSONArray("children"), 1, excludedFolderId, destinations)
        AlertDialog.Builder(this)
            .setTitle("Move To Folder")
            .setItems(destinations.map { destination ->
                "${"  ".repeat(destination.depth)}${destination.name}${if (destination.id == currentParentId) " ✓" else ""}"
            }.toTypedArray()) { _, which ->
                val destination = destinations[which]
                if (destination.id == currentParentId) return@setItems toast("Already there")
                val target = nodeById(destination.id, root) ?: return@setItems toast("Cannot find folder")
                val position = target.optJSONArray("children")?.length() ?: 0
                mutate(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to destination.id, "position" to position))
            }
            .show()
    }

    private fun collectFolderDestinations(nodes: JSONArray?, depth: Int, excludedFolderId: String?, destinations: MutableList<FolderDestination>) {
        nodes?.forEachObject { node ->
            if (node.optString("kind") == "folder" && node.optString("id") != excludedFolderId) {
                destinations.add(FolderDestination(node.optString("id"), node.optString("name"), depth))
                collectFolderDestinations(node.optJSONArray("children"), depth + 1, excludedFolderId, destinations)
            }
        }
    }

    private fun validateSchemeName(name: String, folderId: String? = null, excludingId: String? = null, checkDuplicates: Boolean = true): String? {
        return null
    }

    private fun validateFolderName(name: String, excludingId: String? = null): String? {
        return null
    }

    private fun nodeById(id: String?, node: JSONObject?): JSONObject? {
        if (id == null || node == null) return null
        if (node.optString("id") == id) return node
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            nodeById(id, children.optJSONObject(index))?.let { return it }
        }
        return null
    }

    private fun todayOccurrences(): JSONArray {
        val out = JSONArray()
        calendar().optJSONArray("days")?.forEachObject { day ->
            if (day.optString("date") == LocalDate.now().toString()) {
                day.optJSONArray("occurrences")?.forEachObject { out.put(it) }
            }
        }
        return out
    }

    private fun dayForDate(date: LocalDate): JSONObject? {
        val days = calendar().optJSONArray("days") ?: return null
        for (index in 0 until days.length()) {
            val day = days.optJSONObject(index) ?: continue
            if (day.optString("date") == date.toString()) return day
        }
        return null
    }

    private fun weekStart(date: LocalDate): LocalDate =
        date.minusDays((date.dayOfWeek.value % 7).toLong())

    private fun selectedDateTitle(): String =
        calendar().let { calendar ->
            val start = calendar.optString("start_date")
            val end = calendar.optString("end_date")
            if (start.isNotEmpty() && end.isNotEmpty()) {
                "${MobileDateFormatting.shortDay(start)} - ${MobileDateFormatting.shortDay(end)}"
            } else {
                "${selectedDate.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${selectedDate.dayOfMonth}, ${selectedDate.year}"
            }
        }

    private fun monthTitle(date: LocalDate): String =
        "${date.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${date.year}"

    private fun addOccurrenceSection(root: LinearLayout, title: String, empty: String, occurrences: JSONArray?) {
        root.addView(sectionLabel(title))
        if (occurrences == null || occurrences.length() == 0) {
            root.addView(text(empty, theme.textMuted, 13f, false).apply {
                gravity = Gravity.CENTER
                setPadding(0, dp(4), 0, dp(6))
            })
            return
        }
        occurrences.forEachIndexedObject { idx, occurrence -> root.addView(occurrenceRow(occurrence, idx % 2 == 1), rowParams()) }
    }

    private fun titleText(): String {
        return if (selectedTab == TAB_SCHEMES && selectedSchemeId != null) {
            findScheme(selectedSchemeId!!)?.optString("display_name") ?: "Scheme"
        } else {
            when (selectedTab) {
                TAB_HOME -> "Home"
                TAB_CALENDAR -> "Calendar"
                TAB_SCHEMES -> "Schemes"
                TAB_DAILY -> "Daily"
                TAB_SEARCH -> "Search"
                TAB_SETTINGS -> "Settings"
                else -> "KnotQ"
            }
        }
    }

    private fun titleColor(): Int {
        if (selectedTab == TAB_SCHEMES && selectedSchemeId != null) {
            return findScheme(selectedSchemeId!!)?.optInt("color_index")?.let(::schemeColor) ?: theme.textDim
        }
        return when (selectedTab) {
            TAB_HOME -> theme.accent
            TAB_CALENDAR -> theme.textPrimary
            TAB_DAILY -> if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)
            else -> theme.textDim
        }
    }

    private fun page(compact: Boolean = false): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(if (compact) 0 else dp(14), if (compact) 0 else dp(14), if (compact) 0 else dp(14), if (compact) 0 else dp(20))
        setBackgroundColor(theme.bgApp)
    }

    private fun scroll(view: View): ScrollView = ScrollView(this).apply {
        isFillViewport = true
        setBackgroundColor(theme.bgApp)
        addView(view)
    }

    private fun sectionHeader(value: String): TextView = text(value, theme.textPrimary, 18f, true).apply {
        setPadding(0, dp(4), 0, dp(8))
    }

    private fun sectionLabel(value: String): TextView = text(value, theme.textDim, 12f, true).apply {
        setPadding(dp(4), dp(8), dp(4), dp(4))
    }

    private fun settingsSection(value: String): TextView = text(value, theme.textSoft, 12f, true).apply {
        setPadding(0, dp(16), 0, dp(5))
    }

    private fun choiceRow(value: String, selected: Boolean, action: () -> Unit): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(5))
            addView(text(value, theme.textPrimary, 14f, false), LinearLayout.LayoutParams(0, dp(36), 1f))
            if (selected) addView(colorSquare(theme.accent, 11), LinearLayout.LayoutParams(dp(11), dp(11)))
            setOnClickListener { action() }
        }
    }

    private fun emptyState(title: String, detail: String): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(80), dp(16), dp(80))
            addView(text(title, theme.textDim, 15f, true).apply { gravity = Gravity.CENTER })
            addView(text(detail, theme.textMuted, 13f, false).apply { gravity = Gravity.CENTER })
        }
    }

    private fun text(value: String, color: Int, sp: Float, bold: Boolean): TextView = TextView(this).apply {
        text = value
        setTextColor(color)
        textSize = sp
        includeFontPadding = false
        gravity = Gravity.CENTER_VERTICAL
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun navSpecial(value: String, color: Int, selected: Boolean, listener: () -> Unit): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6), 0, dp(6), 0)
            background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(4))
            addView(colorSquare(color, 9), LinearLayout.LayoutParams(dp(9), dp(9)))
            addView(text(value, theme.textPrimary, 12f, false), LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(7), 0, 0, 0)
            })
            setOnClickListener { listener() }
        }.also { it.layoutParams = LinearLayout.LayoutParams(-1, dp(22)) }
    }

    private fun chip(value: String, listener: () -> Unit): TextView = text(value, theme.textPrimary, 12f, true).apply {
        gravity = Gravity.CENTER
        setPadding(dp(10), 0, dp(10), 0)
        background = rounded(theme.buttonBg, dp(5))
        setOnClickListener { listener() }
    }

    private fun iconChip(value: String, listener: () -> Unit): TextView = chip(value, listener).apply {
        textSize = 13f
    }.also {
        it.layoutParams = LinearLayout.LayoutParams(dp(32), dp(28))
    }

    private fun smallAction(value: String, listener: () -> Unit): TextView = text(value, theme.textDim, 11f, true).apply {
        setPadding(0, dp(5), dp(12), dp(2))
        setOnClickListener { listener() }
    }

    private fun edit(value: String): EditText = EditText(this).apply {
        setText(value)
        setTextColor(theme.textPrimary)
        setHintTextColor(theme.textMuted)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        setSingleLine(false)
        imeOptions = EditorInfo.IME_ACTION_DONE
        textSize = 14f
    }

    private fun spinner(values: Array<String>): Spinner {
        val adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, values)
        return Spinner(this).apply { this.adapter = adapter }
    }

    private fun colorSquare(color: Int, size: Int): View = View(this).apply {
        background = rounded(color, dp(3))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    }

    private fun brandMark(size: Int): ImageView = ImageView(this).apply {
        setImageResource(applicationInfo.icon)
        scaleType = ImageView.ScaleType.CENTER_CROP
        background = rounded(theme.rowSelected, dp(6), theme.borderOverlay)
        clipToOutline = Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP
        setPadding(dp(2), dp(2), dp(2), dp(2))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    }

    private fun colorSwatch(index: Int, active: Int): View = View(this).apply {
        background = rounded(schemeColor(index), dp(3), if (index == active) theme.accent else Color.TRANSPARENT, dp(1))
        setOnClickListener {
            selectedSchemeId?.let { mutate(obj("type" to "set_scheme_color", "scheme_id" to it, "color_index" to index)) }
        }
    }

    private fun divider(): View = View(this).apply { setBackgroundColor(theme.divider) }

    private fun spaced(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(-1, -2).apply {
        setMargins(0, 0, 0, dp(8))
    }

    private fun rowParams(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(-1, -2).apply {
        setMargins(0, 0, 0, dp(1))
    }

    private fun marginRight(right: Int, width: Int, height: Int): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(width, height).apply { setMargins(0, 0, right, 0) }

    private fun markerLabel(marker: String): String = when (marker) {
        "bullet" -> "*"
        "numbered" -> "#"
        "blank" -> "T"
        else -> " "
    }

    private fun calendarTimeColor(occurrence: JSONObject): Int {
        val default = if (theme.isDark) adjustAlpha(rgb(0xe8edf2), 0.90f) else adjustAlpha(rgb(0x2e291f), 0.90f)
        if (occurrence.optBoolean("done")) return default
        val start = MobileDateFormatting.parseInstant(occurrence.optionalString("start") ?: occurrence.optionalString("end")) ?: return default
        val now = Instant.now()
        val end = MobileDateFormatting.parseInstant(occurrence.optionalString("end"))
        if (end != null && !start.isAfter(now) && end.isAfter(now)) return todayTimeColor()
        if (start.isBefore(now)) return if (theme.isDark) rgb(0xff5a53) else rgb(0xd20f39)
        val startDay = start.atZone(ZoneId.systemDefault()).toLocalDate()
        val dayDiff = java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), startDay)
        return when {
            dayDiff <= 0 -> todayTimeColor()
            dayDiff <= 1 -> if (theme.isDark) rgb(0xe5e5ff) else rgb(0x4f5f8f)
            else -> default
        }
    }

    private fun todayTimeColor(): Int =
        if (theme.isDark) rgb(0xbfbfff) else rgb(0x2f67cf)

    private fun calendarItemTextColor(occurrence: JSONObject): Int {
        val color = schemeColor(occurrence.optInt("color_index"))
        val hsv = FloatArray(3)
        Color.colorToHSV(color, hsv)
        val done = occurrence.optBoolean("done")
        hsv[1] *= if (done) {
            if (theme.isDark) 0.35f else 0.45f
        } else {
            if (theme.isDark) 0.70f else 0.90f
        }
        val alpha = if (done) (255 * 0.78f).roundToInt() else 255
        return Color.HSVToColor(alpha, hsv)
    }

    private fun timeFormat24(): Boolean =
        snapshot.optJSONObject("settings")?.optString("time_format") == "twenty_four_hour"

    private fun schemeColor(index: Int): Int {
        val darkPalette = intArrayOf(rgb(0xff453a), rgb(0xff9f0a), rgb(0x30d158), rgb(0x0a84ff), rgb(0xbf5af2), rgb(0xffd60a))
        val lightPalette = intArrayOf(rgb(0xd4271c), rgb(0xc47400), rgb(0x1e9e40), rgb(0x0064d2), rgb(0x8a3db5), rgb(0xe0a800))
        val palette = if (theme.isDark) darkPalette else lightPalette
        return palette[index.floorMod(palette.size)]
    }

    private fun editorChromeColor(): Int =
        if (theme.isDark) rgb(0xb8c9e8) else rgb(0x536a8f)

    private fun eventBg(): Int =
        if (theme.isDark) adjustAlpha(rgb(0x333333), 0.62f) else adjustAlpha(rgb(0xe6e8ec), 0.62f)

    private fun eventBorder(): Int =
        if (theme.isDark) adjustAlpha(Color.WHITE, 0.84f) else adjustAlpha(rgb(0x24272d), 0.80f)

    private fun calendarPillStrokeWidth(): Int =
        max(1, (1.5f * resources.displayMetrics.density).roundToInt())

    private fun calendarEventBorderWidth(): Int =
        max(1, (1.8f * resources.displayMetrics.density).roundToInt())

    private fun calendarDayStrokeWidth(visible: Boolean): Int {
        val width = if (visible) 1.8f else 1.4f
        return max(1, (width * resources.displayMetrics.density).roundToInt())
    }

    private fun calendarRangeFill(): Int =
        if (theme.isDark) adjustAlpha(Color.WHITE, 0.09f) else adjustAlpha(rgb(0x3f6fd5), 0.08f)

    private fun rounded(color: Int, radius: Int, strokeColor: Int = Color.TRANSPARENT, strokeWidth: Int = dp(1)): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
            if (strokeColor != Color.TRANSPARENT) setStroke(strokeWidth, strokeColor)
        }

    private fun roundedHorizontalSegment(color: Int, leadingRounded: Boolean, trailingRounded: Boolean): GradientDrawable =
        GradientDrawable().apply {
            val radius = dp(8).toFloat()
            setColor(color)
            cornerRadii = floatArrayOf(
                if (leadingRounded) radius else 0f,
                if (leadingRounded) radius else 0f,
                if (trailingRounded) radius else 0f,
                if (trailingRounded) radius else 0f,
                if (trailingRounded) radius else 0f,
                if (trailingRounded) radius else 0f,
                if (leadingRounded) radius else 0f,
                if (leadingRounded) radius else 0f,
            )
        }

    private fun underline(color: Int): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            setStroke(dp(1), theme.dividerSoft)
        }

    private fun adjust(color: Int, alpha: Float): Int = adjustAlpha(color, alpha)

    private fun rgb(hex: Int): Int = rgbColor(hex)

    private fun Int.floorMod(mod: Int): Int = ((this % mod) + mod) % mod

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private fun toast(value: String?) {
        Toast.makeText(this, value ?: "Error", Toast.LENGTH_LONG).show()
    }

    private fun showError(title: String, message: String?) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message ?: "Unknown error")
            .setPositiveButton("OK", null)
            .show()
    }

    private fun showFatal(message: String?) {
        setContentView(text(message ?: "KnotQ failed to start", theme.textPrimary, 16f, true).apply {
            gravity = Gravity.CENTER
            setBackgroundColor(theme.bgApp)
        })
    }

}
