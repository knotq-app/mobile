package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.Spannable
import android.text.TextWatcher
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LineBackgroundSpan
import android.text.style.LineHeightSpan
import android.text.style.LeadingMarginSpan
import android.text.style.ReplacementSpan
import android.text.style.StyleSpan
import android.text.style.StrikethroughSpan
import android.view.MotionEvent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.TimePicker
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val EDITOR_TEXT_LEFT_PAD_DP = 35
private const val EDITOR_MARKER_SLOT_DP = 21
private const val EDITOR_INDENT_WIDTH_DP = 15
private const val EDITOR_CHECKBOX_SIZE_DP = 14
private const val EDITOR_ANNOTATION_HEIGHT_DP = 14
private const val EDITOR_ANNOTATION_BAR_GAP_DP = 8
private const val EDITOR_ANNOTATION_TEXT_GAP_DP = 7
private const val EDITOR_INDENT_GUIDE_X_SHIFT_DP = 2
private const val EDITOR_IMAGE_TOP_GAP_DP = 8
private const val EDITOR_IMAGE_STACK_GAP_DP = 7
private const val EDITOR_IMAGE_MAX_HEIGHT_DP = 300
private const val EDITOR_IMAGE_FALLBACK_WIDTH_DP = 320
private const val EDITOR_IMAGE_FALLBACK_HEIGHT_DP = 180
private const val SYNC_SESSION_PREF = "knotq.localSyncSession"
private const val DEFAULT_SYNC_API_BASE = "http://10.0.2.2:8787"
private const val GOOGLE_CLIENT_ID = "419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld.apps.googleusercontent.com"
private const val GOOGLE_REDIRECT_SCHEME = "com.googleusercontent.apps.419826075228-gn6gj1l20nltil67odvf00u3i7n8a2ld"
private const val GOOGLE_REDIRECT_URI = "$GOOGLE_REDIRECT_SCHEME:/oauth2redirect"
private const val GOOGLE_SYNC_INTERVAL_MS = 120_000L

private data class SyncSession(
    val apiBase: String,
    val userId: String,
    val email: String,
    val supportsSync: Boolean,
    // Short-lived access token; `expiresAt` is its expiry.
    val bearerToken: String,
    val expiresAt: String,
    // Long-lived, rotated-on-refresh credential and its (sliding) expiry. Nullable
    // so a session persisted before refresh tokens existed still loads; a missing
    // refresh token just forces a one-time re-login.
    val refreshToken: String? = null,
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
    private var selectedTab = 0
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
        titleBar.addView(colorSquare(titleColor(), 18), LinearLayout.LayoutParams(dp(18), dp(18)))
        titleBar.addView(text(titleText(), theme.textPrimary, 14f, true).apply {
            gravity = Gravity.CENTER
            maxLines = 1
        }, LinearLayout.LayoutParams(0, -1, 1f))

        titleBar.addView(chip("Search") {
            selectedTab = 3
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
        listOf(0 to "Calendar", 1 to "Schemes", 3 to "Search", 4 to "Settings").forEach { (index, label) ->
            val tab = text(label, if (selectedTab == index || selectedTab == 2 && index == 1) theme.textPrimary else theme.textMuted, 11f, true).apply {
                gravity = Gravity.CENTER
                setOnClickListener {
                    selectedTab = index
                    if (index != 1) selectedSchemeId = null
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
        if (selectedTab == 0 || selectedTab == 1 || selectedTab == 2) renderMain() else scroll(renderMain())

    private fun renderMain(): View {
        return when (selectedTab) {
            0 -> renderCalendar()
            1 -> selectedSchemeId?.let(::findScheme)?.let(::renderSchemeEditor) ?: renderListsPage()
            2 -> renderDaily()
            3 -> renderSearch()
            4 -> renderSettings()
            else -> renderCalendar()
        }
    }

    private fun renderNavigator(): View {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(10), dp(8), dp(8))
            background = rounded(theme.bgSidebar, dp(10), theme.borderOverlay)
        }
        panel.addView(navSpecial("Calendar", theme.textPrimary, selectedTab == 0) {
            selectedTab = 0
            selectedSchemeId = null
            render()
        })
        panel.addView(navSpecial("Daily", if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad), selectedTab == 2) {
            selectedTab = 2
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
                selectedTab = 4
                selectedSchemeId = null
                render()
            }, LinearLayout.LayoutParams(dp(33), dp(30)).apply { setMargins(dp(6), 0, 0, 0) })
        })
        return panel
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
                selectedTab = 2
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
        column.addView(text(formatFullDay(day.optString("date")), if (day.optString("date") == LocalDate.now().toString()) theme.textToday else theme.textDim, 12f, true), spaced())
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
            addView(text(formatFullDay(day.optString("date")), if (day.optString("date") == LocalDate.now().toString()) theme.textToday else theme.textDim, 12f, true))
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
            val time = eventTimeLabel(occurrence)
            if (time.isNotEmpty() && !hideEventTime(occurrence)) {
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
            lineAdornments = editorLineAdornments(scheme)
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
            addView(text(formatFullDay(selectedDate.toString()), theme.textPrimary, 14f, true).apply {
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
        val scheme = day.optJSONObject("scheme") ?: return emptyState(formatFullDay(date), "Daily not ready")
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
                addView(text(formatFullDay(date), if (selected) theme.textPrimary else theme.textDim, 13f, true), LinearLayout.LayoutParams(0, -2, 1f))
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
                lineAdornments = editorLineAdornments(scheme)
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
            }
            AlertDialog.Builder(this)
                .setTitle("Sync account")
                .setMessage("Signed in as ${session.email}\n${session.apiBase}")
                .setItems(actions.toTypedArray()) { _, which ->
                    when (actions[which]) {
                        "Sync now" -> syncOnce()
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
        val apiBase = migrateSyncApiBase(apiBaseRaw)
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
        val apiBase = migrateSyncApiBase(apiBaseRaw)
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
            .setMessage("Sync stops on all your devices. Your local workspace stays on this device, and you can sign in again later to re-enable sync.")
            .setNegativeButton("Keep sync", null)
            .setPositiveButton("Turn off sync") { _, _ -> cancelSyncSubscription() }
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
                    showError("Sync turned off", "Your local workspace stays on this device, and you can sign in again later to re-enable sync.")
                }.onFailure { error ->
                    showError("Could not update account", error.message)
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
        if (refreshToken.isNullOrEmpty()) return session
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
                bearerToken = json.optString("bearer_token"),
                expiresAt = json.optString("expires_at"),
                refreshToken = json.optString("refresh_token").ifEmpty { refreshToken },
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
            userId = json.optString("user_id"),
            email = json.optString("email"),
            supportsSync = json.optBoolean("supports_sync", true),
            bearerToken = json.optString("bearer_token"),
            expiresAt = json.optString("expires_at"),
            refreshToken = json.optString("refresh_token").ifEmpty { null },
            refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
        )

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
            val rawApiBase = json.optString("api_base")
            val session = SyncSession(
                apiBase = migrateSyncApiBase(rawApiBase),
                userId = json.optString("user_id"),
                email = json.optString("email"),
                supportsSync = json.optBoolean("supports_sync", true),
                bearerToken = json.optString("bearer_token"),
                expiresAt = json.optString("expires_at"),
                refreshToken = json.optString("refresh_token").ifEmpty { null },
                refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
            )
            if (session.apiBase != rawApiBase) {
                saveSyncSession(session)
            }
            session
        }.getOrNull()
    }

    private fun migrateSyncApiBase(apiBase: String): String {
        return when (val normalized = normalizeApiBase(apiBase)) {
            "http://10.0.2.2:7878" -> DEFAULT_SYNC_API_BASE
            "http://127.0.0.1:7878" -> "http://127.0.0.1:8787"
            "http://localhost:7878" -> "http://localhost:8787"
            else -> normalized
        }
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
                    .put("refresh_token", session.refreshToken ?: JSONObject.NULL)
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
        else -> "The request to the sync backend failed."
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
        val eventOffset = settings?.optInt("event_notification_offset_secs", 10 * 60) ?: 10 * 60
        val assignmentOffset = settings?.optInt("assignment_notification_offset_secs", 2 * 60 * 60) ?: 2 * 60 * 60
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
            showNotificationDefaultDialog("Event reminders", eventOffset, eventNotificationOptions()) { next ->
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
            showNotificationDefaultDialog("Assignment reminders", assignmentOffset, assignmentNotificationOptions()) { next ->
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
        options: List<Pair<String, Int>>,
        onSelect: (Int) -> Unit
    ) {
        val labels = options.map { (label, value) ->
            if (value == current) "$label ✓" else label
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(labels) { _, which -> onSelect(options[which].second) }
            .show()
    }

    private fun eventNotificationOptions(): List<Pair<String, Int>> = listOf(
        "At start" to 0,
        "5 minutes before" to 5 * 60,
        "10 minutes before" to 10 * 60,
        "15 minutes before" to 15 * 60,
        "30 minutes before" to 30 * 60,
        "1 hour before" to 60 * 60,
    )

    private fun assignmentNotificationOptions(): List<Pair<String, Int>> = listOf(
        "At due time" to 0,
        "1 hour before" to 60 * 60,
        "2 hours before" to 2 * 60 * 60,
        "6 hours before" to 6 * 60 * 60,
        "1 day before" to 24 * 60 * 60,
        "2 days before" to 2 * 24 * 60 * 60,
    )

    private fun occurrenceNotificationOptions(current: Int): List<Pair<String, Int>> {
        val base = listOf(
            "At time" to 0,
            "5 minutes before" to 5 * 60,
            "10 minutes before" to 10 * 60,
            "30 minutes before" to 30 * 60,
            "1 hour before" to 60 * 60,
            "1 day before" to 24 * 60 * 60,
        )
        return if (base.any { it.second == current }) base else (base + (notificationLeadTimeLabel(current, true) to current)).sortedBy { it.second }
    }

    private fun notificationLeadTimeLabel(offsetSecs: Int, eventDefault: Boolean): String {
        if (offsetSecs == 0) return if (eventDefault) "At start" else "At due time"
        val all = listOf(
            "At time" to 0,
            "5 minutes before" to 5 * 60,
            "10 minutes before" to 10 * 60,
            "30 minutes before" to 30 * 60,
            "1 hour before" to 60 * 60,
            "1 day before" to 24 * 60 * 60,
        ) +
            eventNotificationOptions() +
            assignmentNotificationOptions()
        all.firstOrNull { it.second == offsetSecs }?.let { return it.first }
        return "${offsetSecs / 60} minutes before"
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
                editor.lineAdornments = editorLineAdornments(refreshed)
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
                    addView(text(timeLabel(occurrence), theme.textSoft, 10f, true))
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
                        val schemeId = if (selectedTab == 2) dailyScheme()?.optString("id") else selectedSchemeId
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
        val startDateTime = occurrence?.optionalString("start")?.let(::localDateTime)
        val endDateTime = occurrence?.optionalString("end")?.let(::localDateTime)
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
            setSelection(repeatValues.indexOf(repeatChoiceFromRrule(occurrence?.optionalString("repeat_rule"))).coerceAtLeast(0))
            isEnabled = !readOnly
        }
        val defaultOffset = defaultNotificationOffset(initialKind)
        val currentOffset = occurrence?.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs") ?: defaultOffset
        val notificationOptions = occurrenceNotificationOptions(currentOffset)
        val notification = spinner(notificationOptions.map { it.first }.toTypedArray()).apply {
            setSelection(notificationOptions.indexOfFirst { it.second == currentOffset }.coerceAtLeast(0))
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
                    "event", "reminder" -> iso(localDate, start.hour, start.minute)
                    else -> null
                }
                val endValue = when (selectedKind) {
                    "event", "assignment" -> iso(localDate, end.hour, end.minute)
                    else -> null
                }
                val rrule = if (selectedKind == "task") null else rruleForRepeat(repeat.selectedItem.toString(), localDate)
                val notificationOffset = if (selectedKind == "task") null else notificationOptions[notification.selectedItemPosition].second
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
            "event" -> settings?.optInt("event_notification_offset_secs", 10 * 60) ?: 10 * 60
            "assignment" -> settings?.optInt("assignment_notification_offset_secs", 2 * 60 * 60) ?: 2 * 60 * 60
            else -> 0
        }
    }

    private fun repeatChoiceFromRrule(rrule: String?): String {
        val upper = rrule?.uppercase(Locale.US) ?: return "none"
        return when {
            upper.contains("FREQ=DAILY") -> "daily"
            upper.contains("FREQ=WEEKLY") -> "weekly"
            upper.contains("FREQ=MONTHLY") -> "monthly"
            upper.contains("FREQ=YEARLY") -> "yearly"
            else -> "none"
        }
    }

    private fun rruleForRepeat(choice: String, date: LocalDate): String? = when (choice) {
        "daily" -> "FREQ=DAILY;INTERVAL=1"
        "weekly" -> "FREQ=WEEKLY;INTERVAL=1;BYDAY=${weekdayCode(date)}"
        "monthly" -> "FREQ=MONTHLY;INTERVAL=1"
        "yearly" -> "FREQ=YEARLY;INTERVAL=1"
        else -> null
    }

    private fun weekdayCode(date: LocalDate): String = when (date.dayOfWeek.value) {
        1 -> "MO"
        2 -> "TU"
        3 -> "WE"
        4 -> "TH"
        5 -> "FR"
        6 -> "SA"
        else -> "SU"
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
        val initial = findItem(schemeId, itemId)?.optionalString(kind)?.let(::localDateTime)
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
                mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to kind, "date" to iso(localDate, time.hour, time.minute)))
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

    private fun openScheme(id: String) {
        selectedTab = 1
        selectedSchemeId = id
        render()
    }

    private fun ensureDaily() {
        mutate(obj("type" to "ensure_daily_queue", "date" to selectedDate.toString()))
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

    private fun localDateTime(raw: String): ZonedDateTime? =
        try {
            Instant.parse(raw).atZone(ZoneId.systemDefault())
        } catch (_: RuntimeException) {
            null
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
                "${formatDay(start)} - ${formatDay(end)}"
            } else {
                "${selectedDate.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${selectedDate.dayOfMonth}, ${selectedDate.year}"
            }
        }

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
        return if (selectedTab == 1 && selectedSchemeId != null) {
            findScheme(selectedSchemeId!!)?.optString("display_name") ?: "Scheme"
        } else {
            listOf("Calendar", "Schemes", "Daily", "Search", "Settings").getOrElse(selectedTab) { "KnotQ" }
        }
    }

    private fun titleColor(): Int {
        if (selectedTab == 1 && selectedSchemeId != null) {
            return findScheme(selectedSchemeId!!)?.optInt("color_index")?.let(::schemeColor) ?: theme.textDim
        }
        return when (selectedTab) {
            0 -> theme.textPrimary
            2 -> if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)
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

    private fun timeLabel(occurrence: JSONObject): String {
        val start = time(occurrence.optionalString("start"))
        val end = time(occurrence.optionalString("end"))
        if (occurrence.optString("kind") == "reminder" && start.isNotEmpty()) return "At $start"
        if (occurrence.optString("kind") == "assignment" && end.isNotEmpty()) return "Due $end"
        return when {
            start.isNotEmpty() && end.isNotEmpty() -> "$start - $end"
            start.isNotEmpty() -> start
            end.isNotEmpty() -> "Due $end"
            else -> occurrence.optString("kind").replaceFirstChar(Char::titlecase)
        }
    }

    private fun eventTimeLabel(occurrence: JSONObject): String {
        if (occurrence.optString("kind") == "reminder") {
            val start = time(occurrence.optionalString("start"))
            return if (start.isNotEmpty()) "At $start" else ""
        }
        if (occurrence.optString("kind") == "assignment") {
            val end = time(occurrence.optionalString("end"))
            return if (end.isNotEmpty()) "Due $end" else ""
        }
        val start = eventTime(occurrence.optionalString("start"), includePeriod = false)
        val end = eventTime(occurrence.optionalString("end"), includePeriod = true)
        return when {
            start.isNotEmpty() && end.isNotEmpty() -> "$start to $end"
            start.isNotEmpty() -> start
            end.isNotEmpty() -> end
            else -> ""
        }
    }

    private fun hideEventTime(occurrence: JSONObject): Boolean {
        if (occurrence.optString("kind") != "event") return false
        val start = instant(occurrence.optionalString("start")) ?: return false
        val end = instant(occurrence.optionalString("end")) ?: return false
        return end.epochSecond - start.epochSecond <= 30 * 60
    }

    private fun calendarTimeColor(occurrence: JSONObject): Int {
        val default = if (theme.isDark) adjustAlpha(rgb(0xe8edf2), 0.90f) else adjustAlpha(rgb(0x2e291f), 0.90f)
        if (occurrence.optBoolean("done")) return default
        val start = instant(occurrence.optionalString("start") ?: occurrence.optionalString("end")) ?: return default
        val now = Instant.now()
        val end = instant(occurrence.optionalString("end"))
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

    private fun instant(raw: String?): Instant? {
        if (raw.isNullOrEmpty() || raw == "null") return null
        return try {
            Instant.parse(raw)
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun eventTime(raw: String?, includePeriod: Boolean): String {
        if (raw.isNullOrEmpty() || raw == "null") return ""
        return try {
            val pattern = if (timeFormat24()) "HH:mm" else if (includePeriod) "h:mm a" else "h:mm"
            DateTimeFormatter.ofPattern(pattern).format(Instant.parse(raw).atZone(ZoneId.systemDefault()))
        } catch (_: RuntimeException) {
            raw
        }
    }

    private fun time(raw: String?): String {
        if (raw.isNullOrEmpty() || raw == "null") return ""
        return try {
            val pattern = if (timeFormat24()) "HH:mm" else "h:mm a"
            DateTimeFormatter.ofPattern(pattern).format(Instant.parse(raw).atZone(ZoneId.systemDefault()))
        } catch (_: RuntimeException) {
            raw
        }
    }

    private fun formatDay(raw: String): String = try {
        val date = LocalDate.parse(raw)
        "${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}"
    } catch (_: RuntimeException) {
        raw
    }

    private fun monthLabel(raw: String): String = try {
        val date = LocalDate.parse(raw)
        "${date.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${date.year}"
    } catch (_: RuntimeException) {
        "Week"
    }

    private fun formatFullDay(raw: String): String = try {
        val date = LocalDate.parse(raw)
        "${date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())}, ${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}"
    } catch (_: RuntimeException) {
        raw
    }

    private fun iso(date: LocalDate, hour: Int, minute: Int): String =
        ZonedDateTime.of(date, LocalTime.of(hour, minute), ZoneId.systemDefault())
            .withZoneSameInstant(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_INSTANT)

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

    private fun obj(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().apply {
        pairs.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) }
    }

    private fun JSONArray.forEachObject(callback: (JSONObject) -> Unit) {
        for (index in 0 until length()) {
            optJSONObject(index)?.let(callback)
        }
    }

    private fun JSONArray.forEachIndexedObject(callback: (Int, JSONObject) -> Unit) {
        for (index in 0 until length()) {
            optJSONObject(index)?.let { callback(index, it) }
        }
    }

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

    private fun documentLines(scheme: JSONObject): List<SchemeEditorLine> {
        val items = scheme.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<SchemeEditorLine>(items.length())
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            out.add(
                SchemeEditorLine(
                    id = item.optString("id").takeIf { it.isNotEmpty() },
                    text = item.optString("text"),
                    marker = item.optString("marker", "blank"),
                    indent = item.optInt("indent", 0).coerceIn(0, 8),
                    done = item.optBoolean("done", false)
                )
            )
        }
        return out
    }

    private fun editorLineAdornments(scheme: JSONObject): List<EditorLineAdornment> {
        val items = scheme.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<EditorLineAdornment>(items.length())
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val start = item.optString("start").takeIf { it.isNotEmpty() && it != "null" }
            val end = item.optString("end").takeIf { it.isNotEmpty() && it != "null" }
            val annotation = when {
                start != null && end != null -> "${time(start)} -> ${time(end)}"
                start != null -> "At ${time(start)}"
                end != null -> "Due ${time(end)}"
                else -> null
            }
            val media = ArrayList<EditorLineMedia>()
            item.optJSONArray("media")?.forEachObject { rawMedia ->
                media.add(
                    EditorLineMedia(
                        kind = rawMedia.optString("kind"),
                        path = rawMedia.optionalString("path"),
                        width = rawMedia.takeUnless { it.isNull("width") }?.optInt("width"),
                        height = rawMedia.takeUnless { it.isNull("height") }?.optInt("height")
                    )
                )
            }
            out.add(
                EditorLineAdornment(
                    marker = item.optString("marker", "blank"),
                    done = item.optBoolean("done", false),
                    annotation = annotation,
                    media = media
                )
            )
        }
        return out
    }

    private fun parseEditorDocument(text: String, preserveBlankDocument: Boolean): List<SchemeEditorLine> {
        val body = if (text.endsWith("\n")) text.dropLast(1) else text
        if (body.isEmpty()) {
            return if (preserveBlankDocument) listOf(parseEditorLine("")) else emptyList()
        }
        return body.split("\n", ignoreCase = false, limit = 0).map(::parseEditorLine)
    }

    private fun parseEditorLine(raw: String): SchemeEditorLine {
        val parsed = parseChromeLine(raw)
        val text = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
        return SchemeEditorLine(id = null, text = text, marker = parsed.marker, indent = parsed.indent, done = parsed.done)
    }

    private fun renderDocument(lines: List<SchemeEditorLine>): String {
        var number = 1
        val body = lines.joinToString("\n") { line ->
            val out = renderEditorLine(line, number)
            if (line.marker == "numbered") number++ else number = 1
            out
        }
        return "$body\n"
    }

    private fun renderEditorLine(line: SchemeEditorLine, ordinal: Int): String {
        val indent = "    ".repeat(line.indent.coerceIn(0, 8))
        val prefix = when (line.marker) {
            "checkbox" -> if (line.done) "[x] " else "[ ] "
            "bullet" -> "- "
            "numbered" -> "$ordinal. "
            else -> ""
        }
        return "$indent$prefix${line.text}"
    }

    private fun reconcileEditorLines(old: List<SchemeEditorLine>, parsed: List<SchemeEditorLine>): List<SchemeEditorLine> {
        var prefix = 0
        while (prefix < old.size && prefix < parsed.size && old[prefix].rawKey == parsed[prefix].rawKey) {
            prefix++
        }

        var suffix = 0
        while (suffix + prefix < old.size && suffix + prefix < parsed.size) {
            val oldIndex = old.size - suffix - 1
            val newIndex = parsed.size - suffix - 1
            if (old[oldIndex].rawKey != parsed[newIndex].rawKey) break
            suffix++
        }

        val result = ArrayList<SchemeEditorLine>()
        result.addAll(old.take(prefix))

        val oldMiddle = old.subList(prefix, old.size - suffix)
        val newMiddle = parsed.subList(prefix, parsed.size - suffix)
        val matched = min(oldMiddle.size, newMiddle.size)
        for (index in 0 until matched) {
            result.add(newMiddle[index].copy(id = oldMiddle[index].id))
        }
        if (newMiddle.size > matched) {
            result.addAll(newMiddle.drop(matched))
        }
        if (suffix > 0) {
            result.addAll(old.takeLast(suffix))
        }
        return result
    }
}

private fun JSONObject.optionalString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() && it != "null" }

private class MaxWidthLinearLayout(context: android.content.Context, private val maxWidthPx: Int) : LinearLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = View.MeasureSpec.getSize(widthMeasureSpec)
        val mode = View.MeasureSpec.getMode(widthMeasureSpec)
        val constrainedWidth = if (width > 0) min(width, maxWidthPx) else maxWidthPx
        super.onMeasure(View.MeasureSpec.makeMeasureSpec(constrainedWidth, mode), heightMeasureSpec)
    }
}

private class SchemeEditText(context: android.content.Context) : EditText(context) {
    private val chromePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val imageCache = HashMap<String, Bitmap?>()

    var editorTheme: UiTheme = UiTheme.dark
        set(value) {
            field = value
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
            invalidate()
        }
    var accentColor: Int = Color.BLUE
        set(value) {
            field = value
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
            invalidate()
        }
    private var chromeAdornments: List<EditorLineAdornment>? = emptyList()
    var lineAdornments: List<EditorLineAdornment>
        get() = chromeAdornments.orEmpty()
        set(value) {
            chromeAdornments = value
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
        }
    var markerTapHandler: ((Int) -> Unit)? = null

    private var styling = false
    private var pendingEditStart = -1
    private var pendingEditEnd = -1

    init {
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                if (styling) return
                pendingEditStart = start
                pendingEditEnd = start + count
            }
            override fun afterTextChanged(s: Editable?) {
                if (!styling && s != null && BaseInputConnection.getComposingSpanStart(s) < 0) {
                    enforceTerminalNewline(s)
                    handleEnterContinuation(s)
                    applyPrefixSpans(s, fullDocument = true)
                }
                invalidate()
            }
        })
    }

    override fun setText(text: CharSequence?, type: BufferType?) {
        val value = text?.toString().orEmpty().let { if (it.endsWith("\n")) it else "$it\n" }
        super.setText(value, type)
        editableText?.let { applyPrefixSpans(it, fullDocument = true) }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w != oldw) editableText?.let { applyPrefixSpans(it, fullDocument = true) }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        drawEditorChrome(canvas)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            markerLineAt(event.x, event.y)?.let { line ->
                markerTapHandler?.invoke(line)
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun markerLineAt(x: Float, y: Float): Int? {
        val layout = layout ?: return null
        val value = text?.toString().orEmpty()
        for (visualLine in 0 until layout.lineCount) {
            val lineStart = layout.getLineStart(visualLine)
            if (lineStart > 0 && value.getOrNull(lineStart - 1) != '\n') continue
            val logicalLine = value.substring(0, lineStart).count { it == '\n' }
            val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
            val parsed = parseChromeLine(value.substring(lineStart, lineEnd))
            val prefixWidth = prefixVisualWidth(parsed, parsed.marker)
            val extraHeight = extraHeightFor(lineAdornments.getOrNull(logicalLine), prefixWidth)
            val rect = markerRect(
                parsed.indent,
                totalPaddingTop + layout.getLineTop(visualLine) - scrollY,
                totalPaddingTop + layout.getLineBottom(visualLine) - scrollY - extraHeight
            )
            rect.left = 0f
            rect.right = (totalPaddingLeft + dp(EDITOR_MARKER_SLOT_DP + 12)).toFloat()
            rect.inset(-dp(10).toFloat(), -dp(10).toFloat())
            if (rect.contains(x, y)) return logicalLine
        }
        return null
    }

    private fun applyPrefixSpans(editable: Editable, fullDocument: Boolean) {
        styling = true
        val value = editable.toString()
        val rangeStart: Int
        val rangeEnd: Int
        val lineIndexAtStart: Int
        if (fullDocument || pendingEditStart < 0) {
            rangeStart = 0
            rangeEnd = value.length
            lineIndexAtStart = 0
        } else {
            val editStart = pendingEditStart.coerceIn(0, value.length)
            val editEnd = pendingEditEnd.coerceIn(editStart, value.length)
            rangeStart = value.lastIndexOf('\n', (editStart - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
            rangeEnd = value.indexOf('\n', editEnd).let { if (it < 0) value.length else it }
            lineIndexAtStart = if (rangeStart == 0) 0 else value.substring(0, rangeStart).count { it == '\n' }
        }
        pendingEditStart = -1
        pendingEditEnd = -1

        removeSpansInRange(editable, rangeStart, rangeEnd, HiddenPrefixSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, DoneTextSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, DoneTextColorSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorChromeSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorHangingIndentSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorMarkdownSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorTextSizeSpan::class.java)

        var start = rangeStart
        var lineIndex = lineIndexAtStart
        while (start <= rangeEnd) {
            if (start == value.length && value.endsWith("\n")) break
            val end = value.indexOf('\n', start).let { if (it < 0 || it > rangeEnd) rangeEnd else it }
            val raw = value.substring(start, end)
            val prefix = chromePrefixLength(raw)
            val parsed = parseChromeLine(raw)
            val adornment = lineAdornments.getOrNull(lineIndex)
            val marker = parsed.marker
            val prefixWidth = prefixVisualWidth(parsed, marker)
            val bodyStart = (start + prefix).coerceAtMost(end)
            val body = raw.drop(prefix.coerceAtMost(raw.length))
            val heading = isMarkdownHeading(body)
            val spanEnd = when {
                end > start -> end
                end < value.length -> end + 1
                else -> end
            }
            if (spanEnd > start) {
                editable.setSpan(
                    EditorChromeSpan(
                        lineTextEnd = end,
                        heading = heading,
                        extraHeight = extraHeightFor(adornment, prefixWidth),
                        density = resources.displayMetrics.density
                    ),
                    start,
                    spanEnd,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            if (prefix > 0) {
                editable.setSpan(
                    HiddenPrefixSpan(prefixWidth),
                    start,
                    (start + prefix).coerceAtMost(editable.length),
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            if (prefixWidth > 0 && spanEnd > start) {
                editable.setSpan(
                    EditorHangingIndentSpan(parsed.indent.coerceIn(0, 8) * dp(EDITOR_INDENT_WIDTH_DP)),
                    start,
                    spanEnd,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            if (bodyStart < end) {
                if (heading) {
                    editable.setSpan(EditorTextSizeSpan(24), bodyStart, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                    editable.setSpan(EditorMarkdownSpan(Typeface.BOLD), bodyStart, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                } else {
                    applyMarkdownSpans(editable, body, bodyStart, end)
                }
            }
            if (parsed.done && start + prefix < end) {
                editable.setSpan(DoneTextSpan(), start + prefix, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                editable.setSpan(DoneTextColorSpan(editorTheme.textMuted), start + prefix, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            lineIndex++
            if (end >= rangeEnd) break
            start = end + 1
        }
        styling = false
    }

    private fun handleEnterContinuation(editable: Editable) {
        val insertStart = pendingEditStart
        val insertEnd = pendingEditEnd
        if (insertStart < 0 || insertEnd - insertStart != 1) return
        if (insertStart >= editable.length) return
        if (editable[insertStart] != '\n') return
        val value = editable.toString()
        val lineStart = value.lastIndexOf('\n', (insertStart - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val lineText = value.substring(lineStart, insertStart)
        val parsed = parseChromeLine(lineText)
        val prefixLen = chromePrefixLength(lineText)
        val body = lineText.drop(prefixLen.coerceAtMost(lineText.length))
        if (parsed.marker == "blank" && parsed.indent == 0) return
        val indentStr = "    ".repeat(parsed.indent.coerceIn(0, 8))
        if (body.isEmpty() && parsed.marker != "blank") {
            // Escape the list: drop the prefix on the now-empty source line
            // and the newline that was just inserted.
            styling = true
            editable.replace(lineStart, insertStart + 1, "")
            setSelection(lineStart.coerceAtMost(editable.length))
            styling = false
            pendingEditStart = -1
            pendingEditEnd = -1
            return
        }
        if (body.isEmpty() && parsed.indent > 0) {
            // Plain indented blank line + Enter: outdent by collapsing the indent.
            styling = true
            editable.replace(lineStart, insertStart + 1, "")
            setSelection(lineStart.coerceAtMost(editable.length))
            styling = false
            pendingEditStart = -1
            pendingEditEnd = -1
            return
        }
        val newPrefix = when (parsed.marker) {
            "checkbox" -> "$indentStr[ ] "
            "bullet" -> "$indentStr- "
            "numbered" -> "$indentStr${nextNumberedOrdinal(value, lineStart, parsed.indent)}. "
            else -> if (parsed.indent > 0) indentStr else ""
        }
        if (newPrefix.isEmpty()) return
        val insertPos = insertStart + 1
        styling = true
        editable.insert(insertPos, newPrefix)
        setSelection((insertPos + newPrefix.length).coerceAtMost(editable.length))
        styling = false
        pendingEditStart = -1
        pendingEditEnd = -1
    }

    private fun nextNumberedOrdinal(value: String, lineStart: Int, indent: Int): Int {
        var ordinal = 1
        var cursor = lineStart
        while (cursor > 0) {
            val prevEnd = cursor - 1 // newline char
            if (prevEnd < 0 || value[prevEnd] != '\n') break
            val prevStart = value.lastIndexOf('\n', (prevEnd - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
            val prevLine = value.substring(prevStart, prevEnd)
            val prevParsed = parseChromeLine(prevLine)
            if (prevParsed.marker != "numbered" || prevParsed.indent != indent) break
            ordinal++
            cursor = prevStart
        }
        return ordinal + 1 // the current line itself is the Nth; next is N+1
    }

    private fun enforceTerminalNewline(editable: Editable) {
        if (editable.isNotEmpty() && editable.last() == '\n') return
        val start = selectionStart.coerceIn(0, editable.length)
        val end = selectionEnd.coerceIn(0, editable.length)
        styling = true
        editable.append("\n")
        styling = false
        setSelection(start.coerceAtMost(editable.length), end.coerceAtMost(editable.length))
    }

    private fun drawEditorChrome(canvas: Canvas) {
        val layout = layout ?: return
        val value = text?.toString().orEmpty()
        val lines = chromeDrawLines(value)
        var ordinal = 1
        lines.forEachIndexed { index, line ->
            if (value.isEmpty()) return@forEachIndexed
            val firstVisual = layout.getLineForOffset(line.start.coerceIn(0, max(0, value.length - 1)))
            val lastOffset = if (line.end > line.start) line.end - 1 else line.start
            val lastVisual = layout.getLineForOffset(lastOffset.coerceIn(0, max(0, value.length - 1)))
            val firstTop = totalPaddingTop + layout.getLineTop(firstVisual) - scrollY
            val firstBottomRaw = totalPaddingTop + layout.getLineBottom(firstVisual) - scrollY
            val rowBottom = totalPaddingTop + layout.getLineBottom(lastVisual) - scrollY
            val firstBottom = if (firstVisual == lastVisual) firstBottomRaw - line.extraHeight else firstBottomRaw
            val contentBottom = rowBottom - line.extraHeight
            val markerRect = markerRect(line.indent, firstTop, firstBottom)
            val previous = lines.getOrNull(index - 1)
            val next = lines.getOrNull(index + 1)

            drawGuides(canvas, markerRect, line.indent, previous?.indent ?: 0, next?.indent ?: 0, firstTop, rowBottom)
            val lineOrdinal = if (line.marker == "numbered") {
                ordinal++
            } else {
                ordinal = 1
                1
            }
            drawMarker(canvas, markerRect, line.marker, line.done, lineOrdinal)
            line.annotation?.let { annotation ->
                drawAnnotationBar(
                    canvas = canvas,
                    markerRect = markerRect,
                    top = firstTop,
                    bottom = rowBottom,
                    connectsToPrevious = previous?.annotation != null,
                    connectsToNext = next?.annotation != null
                )
                drawAnnotation(canvas, annotation, markerRect, contentBottom)
            }
            drawMediaStack(canvas, line.media, line.prefixWidth, contentBottom + if (line.annotation == null) 0 else dp(EDITOR_ANNOTATION_HEIGHT_DP))
        }
    }

    private fun chromeDrawLines(value: String): List<ChromeDrawLine> {
        val out = ArrayList<ChromeDrawLine>()
        var start = 0
        var lineIndex = 0
        while (start <= value.length) {
            if (start == value.length && value.endsWith("\n")) break
            val end = value.indexOf('\n', start).let { if (it < 0) value.length else it }
            val raw = value.substring(start, end)
            val parsed = parseChromeLine(raw)
            val marker = parsed.marker
            val prefixWidth = prefixVisualWidth(parsed, marker)
            val body = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
            val adornment = lineAdornments.getOrNull(lineIndex)
            out.add(
                ChromeDrawLine(
                    start = start,
                    end = end,
                    indent = parsed.indent,
                    marker = marker,
                    done = parsed.done,
                    annotation = adornment?.annotation,
                    media = adornment?.media.orEmpty(),
                    prefixWidth = prefixWidth,
                    heading = isMarkdownHeading(body),
                    extraHeight = extraHeightFor(adornment, prefixWidth)
                )
            )
            lineIndex++
            if (end >= value.length) break
            start = end + 1
        }
        return out
    }

    private fun drawGuides(canvas: Canvas, markerRect: RectF, indent: Int, previousIndent: Int, nextIndent: Int, top: Int, bottom: Int) {
        if (indent <= 0) return
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.dividerSoft
        val guideBottom = bottom.toFloat()
        for (level in 1..indent.coerceIn(0, 8)) {
            val hasPrevious = previousIndent.coerceIn(0, 8) >= level
            val hasNext = nextIndent.coerceIn(0, 8) >= level
            val topMargin = if (hasPrevious) 0f else dp(3f)
            val bottomMargin = if (hasNext) 0f else dp(3f)
            val x = annotationGuideX(markerRect) - (indent - level) * dp(EDITOR_INDENT_WIDTH_DP.toFloat())
            canvas.drawRect(x, top + topMargin, x + 1f, max(top + topMargin + 1f, guideBottom - bottomMargin), chromePaint)
        }
    }

    private fun drawMarker(canvas: Canvas, rect: RectF, marker: String, done: Boolean, ordinal: Int) {
        when (marker) {
            "checkbox" -> {
                chromePaint.style = Paint.Style.FILL
                chromePaint.color = if (done) accentColor else editorTheme.buttonBg
                canvas.drawRoundRect(rect, dp(3f), dp(3f), chromePaint)
                chromePaint.style = Paint.Style.STROKE
                chromePaint.strokeWidth = dp(1f)
                chromePaint.color = accentColor
                canvas.drawRoundRect(rect, dp(3f), dp(3f), chromePaint)
                if (done) {
                    chromePaint.style = Paint.Style.STROKE
                    chromePaint.strokeWidth = dp(2f)
                    chromePaint.strokeCap = Paint.Cap.ROUND
                    chromePaint.strokeJoin = Paint.Join.ROUND
                    chromePaint.color = editorTheme.bgApp
                    val check = Path()
                    check.moveTo(rect.left + dp(3.2f), rect.top + dp(7.2f))
                    check.lineTo(rect.left + dp(5.8f), rect.top + dp(9.7f))
                    check.lineTo(rect.right - dp(3f), rect.top + dp(4.3f))
                    canvas.drawPath(check, chromePaint)
                }
            }
            "bullet" -> {
                chromePaint.style = Paint.Style.FILL
                chromePaint.color = accentColor
                canvas.drawCircle(rect.centerX(), rect.centerY(), dp(2.2f), chromePaint)
            }
            "numbered" -> {
                chromePaint.style = Paint.Style.FILL
                chromePaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                chromePaint.textSize = dp(12f)
                chromePaint.color = accentColor
                chromePaint.textAlign = Paint.Align.RIGHT
                canvas.drawText("$ordinal.", rect.left - dp(5f), rect.bottom - dp(2f), chromePaint)
                chromePaint.textAlign = Paint.Align.LEFT
                chromePaint.typeface = Typeface.DEFAULT
            }
        }
    }

    private fun drawAnnotationBar(canvas: Canvas, markerRect: RectF, top: Int, bottom: Int, connectsToPrevious: Boolean, connectsToNext: Boolean) {
        val x = annotationGuideX(markerRect)
        val y1 = if (connectsToPrevious) top.toFloat() else markerRect.top
        val y2 = bottom.toFloat() - if (connectsToNext) 0f else dp(3f)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = accentColor
        canvas.drawRect(x, y1, x + 1f, max(y1 + 1f, y2), chromePaint)
    }

    private fun drawAnnotation(canvas: Canvas, value: String, markerRect: RectF, contentBottom: Int) {
        chromePaint.style = Paint.Style.FILL
        chromePaint.typeface = Typeface.MONOSPACE
        chromePaint.textSize = dp(10.5f)
        chromePaint.color = accentColor
        chromePaint.textAlign = Paint.Align.LEFT
        canvas.drawText(
            value,
            annotationGuideX(markerRect) + dp(EDITOR_ANNOTATION_TEXT_GAP_DP.toFloat()),
            contentBottom + dp(EDITOR_ANNOTATION_HEIGHT_DP.toFloat()) - dp(3f),
            chromePaint
        )
        chromePaint.typeface = Typeface.DEFAULT
    }

    private fun drawMediaStack(canvas: Canvas, media: List<EditorLineMedia>, prefixWidth: Int, yStart: Int) {
        if (media.isEmpty()) return
        val maxWidth = editorImageMaxWidth(prefixWidth)
        var y = yStart + dp(EDITOR_IMAGE_TOP_GAP_DP)
        var drewImage = false
        media.filter { it.kind == "image" }.forEach { item ->
            val size = mediaDisplaySize(item, maxWidth)
            if (size.first <= 0f || size.second <= 0f) return@forEach
            if (drewImage) y += dp(EDITOR_IMAGE_STACK_GAP_DP)
            val rect = RectF(totalPaddingLeft + prefixWidth.toFloat(), y.toFloat(), totalPaddingLeft + prefixWidth + size.first, y + size.second)
            drawImageMedia(canvas, item, rect)
            y += size.second.roundToInt()
            drewImage = true
        }
    }

    private fun drawImageMedia(canvas: Canvas, media: EditorLineMedia, rect: RectF) {
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.buttonBg
        canvas.drawRoundRect(rect, dp(5f), dp(5f), chromePaint)
        chromePaint.style = Paint.Style.STROKE
        chromePaint.strokeWidth = dp(1f)
        chromePaint.color = editorTheme.divider
        canvas.drawRoundRect(rect, dp(5f), dp(5f), chromePaint)
        val bitmap = media.path?.let(::bitmapForPath)
        if (bitmap != null && bitmap.width > 2 && bitmap.height > 2) {
            canvas.save()
            canvas.clipRect(rect)
            canvas.drawBitmap(
                bitmap,
                null,
                Rect(rect.left.roundToInt(), rect.top.roundToInt(), rect.right.roundToInt(), rect.bottom.roundToInt()),
                chromePaint
            )
            canvas.restore()
        } else {
            drawImageFallback(canvas, rect)
        }
    }

    private fun drawImageFallback(canvas: Canvas, rect: RectF) {
        val inner = RectF(rect.left + 1f, rect.top + 1f, rect.right - 1f, rect.bottom - 1f)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.bgModal
        canvas.drawRect(inner, chromePaint)
        chromePaint.color = adjustColor(editorTheme.accent, 0.16f)
        canvas.drawCircle(inner.right - inner.width() * 0.23f, inner.top + inner.height() * 0.20f, inner.width() * 0.08f, chromePaint)
        chromePaint.color = editorTheme.divider
        canvas.drawRoundRect(RectF(inner.left + inner.width() * 0.07f, inner.top + inner.height() * 0.16f, inner.left + inner.width() * 0.47f, inner.top + inner.height() * 0.23f), dp(4f), dp(4f), chromePaint)
        canvas.drawRoundRect(RectF(inner.left + inner.width() * 0.07f, inner.top + inner.height() * 0.32f, inner.left + inner.width() * 0.69f, inner.top + inner.height() * 0.37f), dp(4f), dp(4f), chromePaint)
        canvas.drawRoundRect(RectF(inner.left + inner.width() * 0.07f, inner.top + inner.height() * 0.45f, inner.left + inner.width() * 0.57f, inner.top + inner.height() * 0.50f), dp(4f), dp(4f), chromePaint)
        canvas.drawRoundRect(RectF(inner.left + inner.width() * 0.07f, inner.bottom - inner.height() * 0.29f, inner.left + inner.width() * 0.77f, inner.bottom - inner.height() * 0.16f), dp(6f), dp(6f), chromePaint)
        chromePaint.color = editorTheme.textPrimary
        chromePaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        chromePaint.textSize = max(dp(11f), inner.height() * 0.07f)
        canvas.drawText("Image", inner.left + inner.width() * 0.10f, inner.bottom - inner.height() * 0.18f, chromePaint)
        chromePaint.typeface = Typeface.DEFAULT
    }

    private fun bitmapForPath(path: String): Bitmap? {
        if (imageCache.containsKey(path)) return imageCache[path]
        val decoded = BitmapFactory.decodeFile(path)
        imageCache[path] = decoded
        return decoded
    }

    private fun extraHeightFor(adornment: EditorLineAdornment?, prefixWidth: Int): Int {
        var extra = if (adornment?.annotation == null) 0 else dp(EDITOR_ANNOTATION_HEIGHT_DP)
        extra += mediaStackHeight(adornment?.media.orEmpty(), editorImageMaxWidth(prefixWidth))
        return extra
    }

    private fun mediaStackHeight(media: List<EditorLineMedia>, maxWidth: Int): Int {
        var height = 0
        var count = 0
        media.filter { it.kind == "image" }.forEach { item ->
            val size = mediaDisplaySize(item, maxWidth)
            if (size.second <= 0f) return@forEach
            height += if (count == 0) dp(EDITOR_IMAGE_TOP_GAP_DP) else dp(EDITOR_IMAGE_STACK_GAP_DP)
            height += size.second.roundToInt()
            count++
        }
        return height
    }

    private fun mediaDisplaySize(media: EditorLineMedia, maxWidth: Int): Pair<Float, Float> {
        val rawWidth = dp((media.width ?: EDITOR_IMAGE_FALLBACK_WIDTH_DP).coerceAtLeast(1)).toFloat()
        val rawHeight = dp((media.height ?: EDITOR_IMAGE_FALLBACK_HEIGHT_DP).coerceAtLeast(1)).toFloat()
        if (rawWidth <= 0f || rawHeight <= 0f || maxWidth <= 0) return 0f to 0f
        val scale = min(1f, min(maxWidth / rawWidth, dp(EDITOR_IMAGE_MAX_HEIGHT_DP) / rawHeight))
        return rawWidth * scale to rawHeight * scale
    }

    private fun editorImageMaxWidth(prefixWidth: Int): Int =
        max(dp(120), (width.takeIf { it > 0 } ?: dp(EDITOR_IMAGE_FALLBACK_WIDTH_DP + 80)) - totalPaddingLeft - prefixWidth - totalPaddingRight - dp(8))

    private fun annotationGuideX(markerRect: RectF): Float =
        markerRect.left - dp((EDITOR_ANNOTATION_BAR_GAP_DP + EDITOR_INDENT_GUIDE_X_SHIFT_DP).toFloat())

    private fun adjustColor(color: Int, alpha: Float): Int = adjustAlpha(color, alpha)

    private fun <T> removeSpansInRange(editable: Editable, start: Int, end: Int, kind: Class<T>) {
        editable.getSpans(start, end, kind).forEach { span ->
            val s = editable.getSpanStart(span)
            val e = editable.getSpanEnd(span)
            if (s >= start && e <= end + 1) {
                editable.removeSpan(span)
            }
        }
    }

    private fun markerRect(indent: Int, top: Int, bottom: Int): RectF {
        val size = dp(EDITOR_CHECKBOX_SIZE_DP).toFloat()
        val left = totalPaddingLeft + indent.coerceIn(0, 8) * dp(EDITOR_INDENT_WIDTH_DP)
        val centerY = (top + bottom) / 2f
        return RectF(left.toFloat(), centerY - size / 2f, left + size, centerY + size / 2f)
    }

    private fun prefixVisualWidth(parsed: ChromeLine, marker: String): Int {
        val markerSlot = if (marker == "blank") 0 else dp(EDITOR_MARKER_SLOT_DP)
        return parsed.indent.coerceIn(0, 8) * dp(EDITOR_INDENT_WIDTH_DP) + markerSlot
    }

    private fun applyMarkdownSpans(editable: Editable, body: String, bodyStart: Int, bodyEnd: Int) {
        var index = 0
        while (index < body.length) {
            val marker = body[index]
            if (marker != '*' && marker != '_') {
                index++
                continue
            }
            val close = body.indexOf(marker, startIndex = index + 1)
            if (close < 0) {
                index++
                continue
            }
            if (close > index + 1) {
                val style = if (marker == '*') Typeface.BOLD else Typeface.ITALIC
                editable.setSpan(
                    EditorMarkdownSpan(style),
                    (bodyStart + index + 1).coerceAtMost(bodyEnd),
                    (bodyStart + close).coerceAtMost(bodyEnd),
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            index = close + 1
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
    private fun dp(value: Float): Float = value * resources.displayMetrics.density
}

private class EditorChromeSpan(
    private val lineTextEnd: Int,
    private val heading: Boolean,
    private val extraHeight: Int,
    private val density: Float,
) : LineBackgroundSpan, LineHeightSpan {

    override fun drawBackground(
        canvas: Canvas,
        paint: Paint,
        left: Int,
        right: Int,
        top: Int,
        baseline: Int,
        bottom: Int,
        text: CharSequence,
        start: Int,
        end: Int,
        lineNumber: Int
    ) = Unit

    override fun chooseHeight(
        text: CharSequence?,
        start: Int,
        end: Int,
        spanstartv: Int,
        lineHeight: Int,
        fm: Paint.FontMetricsInt
    ) {
        if (heading) {
            val target = dp(30f).roundToInt()
            val current = fm.descent - fm.ascent
            if (current < target) {
                val extra = target - current
                fm.descent += extra / 2
                fm.ascent -= extra - extra / 2
                fm.bottom = max(fm.bottom, fm.descent)
                fm.top = min(fm.top, fm.ascent)
            }
        }
        if (extraHeight > 0 && end >= lineTextEnd) {
            fm.descent += extraHeight
            fm.bottom += extraHeight
        }
    }

    private fun dp(value: Float): Float = value * density
}

private class HiddenPrefixSpan(private val width: Int) : ReplacementSpan() {
    override fun getSize(
        paint: Paint,
        text: CharSequence?,
        start: Int,
        end: Int,
        fm: Paint.FontMetricsInt?
    ): Int = width

    override fun draw(
        canvas: Canvas,
        text: CharSequence?,
        start: Int,
        end: Int,
        x: Float,
        top: Int,
        y: Int,
        bottom: Int,
        paint: Paint
    ) = Unit
}

private class EditorHangingIndentSpan(private val width: Int) : LeadingMarginSpan.LeadingMarginSpan2 {
    override fun getLeadingMargin(first: Boolean): Int = if (first) 0 else width
    override fun getLeadingMarginLineCount(): Int = 1

    override fun drawLeadingMargin(
        canvas: Canvas,
        paint: Paint,
        x: Int,
        dir: Int,
        top: Int,
        baseline: Int,
        bottom: Int,
        text: CharSequence,
        start: Int,
        end: Int,
        first: Boolean,
        layout: android.text.Layout?
    ) = Unit
}

private class DoneTextSpan : StrikethroughSpan()

private class DoneTextColorSpan(color: Int) : ForegroundColorSpan(color)

private class EditorMarkdownSpan(style: Int) : StyleSpan(style)

private class EditorTextSizeSpan(sizeSp: Int) : AbsoluteSizeSpan(sizeSp, true)

private data class EditorLineAdornment(
    val marker: String,
    val done: Boolean,
    val annotation: String?,
    val media: List<EditorLineMedia>,
)

private data class EditorLineMedia(
    val kind: String,
    val path: String?,
    val width: Int?,
    val height: Int?,
)

private data class ChromeDrawLine(
    val start: Int,
    val end: Int,
    val indent: Int,
    val marker: String,
    val done: Boolean,
    val annotation: String?,
    val media: List<EditorLineMedia>,
    val prefixWidth: Int,
    val heading: Boolean,
    val extraHeight: Int,
)

private data class ChromeLine(
    val marker: String,
    val indent: Int,
    val done: Boolean,
)

private fun parseChromeLine(raw: String): ChromeLine {
    var rest = raw
    var indent = 0
    while (rest.startsWith("    ") && indent < 8) {
        rest = rest.drop(4)
        indent++
    }
    while (rest.startsWith("\t") && indent < 8) {
        rest = rest.drop(1)
        indent++
    }

    return when {
        rest.startsWith("[x] ", ignoreCase = true) -> ChromeLine("checkbox", indent, true)
        rest.startsWith("[ ] ") -> ChromeLine("checkbox", indent, false)
        rest.startsWith("- ") || rest.startsWith("* ") -> ChromeLine("bullet", indent, false)
        numberedPrefix.find(rest) != null -> ChromeLine("numbered", indent, false)
        else -> ChromeLine("blank", indent, false)
    }
}

private fun chromePrefixLength(raw: String): Int {
    var rest = raw
    var length = 0
    while (rest.startsWith("    ") && length < 32) {
        rest = rest.drop(4)
        length += 4
    }
    while (rest.startsWith("\t") && length < 8) {
        rest = rest.drop(1)
        length += 1
    }
    return when {
        rest.startsWith("[x] ", ignoreCase = true) || rest.startsWith("[ ] ") -> length + 4
        rest.startsWith("- ") || rest.startsWith("* ") -> length + 2
        numberedPrefix.find(rest) != null -> length + (numberedPrefix.find(rest)?.value?.length ?: 0)
        else -> length
    }
}

private fun isMarkdownHeading(line: String): Boolean {
    val trimmed = line.trimStart()
    if (!trimmed.startsWith("#")) return false
    val hashes = trimmed.takeWhile { it == '#' }.length
    return hashes > 0 && (trimmed.length == hashes || trimmed.getOrNull(hashes)?.isWhitespace() == true)
}

private val numberedPrefix = Regex("^\\d+\\.\\s+")

private fun rgbColor(hex: Int): Int =
    Color.rgb((hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

private fun rgbaColor(hex: Int, alpha: Int): Int =
    Color.argb(alpha, (hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

private fun adjustAlpha(color: Int, alpha: Float): Int =
    Color.argb((255 * alpha).roundToInt(), Color.red(color), Color.green(color), Color.blue(color))

private data class SchemeEditorLine(
    val id: String?,
    val text: String,
    val marker: String,
    val indent: Int,
    val done: Boolean,
) {
    val rawKey: String = "$marker|$indent|$done|$text"
}

private data class UiTheme(
    val isDark: Boolean,
    val bgApp: Int,
    val bgSidebar: Int,
    val bgToolbar: Int,
    val bgModal: Int,
    val rowAlt: Int,
    val rowSelected: Int,
    val buttonBg: Int,
    val divider: Int,
    val dividerSoft: Int,
    val dividerTiny: Int,
    val borderOverlay: Int,
    val textPrimary: Int,
    val textDim: Int,
    val textMuted: Int,
    val textSoft: Int,
    val textToday: Int,
    val accent: Int,
    val danger: Int,
) {
    companion object {
        private fun rgb(hex: Int): Int = rgbColor(hex)
        private fun rgba(hex: Int, alpha: Int): Int = rgbaColor(hex, alpha)

        val dark = UiTheme(
            isDark = true,
            bgApp = rgb(0x242627),
            bgSidebar = rgb(0x28292b),
            bgToolbar = rgb(0x363738),
            bgModal = rgb(0x303133),
            rowAlt = rgba(0xffffff, 12),
            rowSelected = rgba(0xffffff, 30),
            buttonBg = rgba(0xffffff, 18),
            divider = rgba(0xffffff, 25),
            dividerSoft = rgba(0xffffff, 18),
            dividerTiny = rgba(0xffffff, 8),
            borderOverlay = rgba(0xffffff, 32),
            textPrimary = rgb(0xdde2e8),
            textDim = rgb(0xb4bcc4),
            textMuted = rgba(0xb4bcc4, 120),
            textSoft = rgba(0xd2dae2, 160),
            textToday = rgb(0xe66d5d),
            accent = rgb(0x7aa0ff),
            danger = rgb(0xff5a53),
        )

        val light = UiTheme(
            isDark = false,
            bgApp = rgb(0xe8e2d8),
            bgSidebar = rgb(0xe0d8cc),
            bgToolbar = rgb(0xe3dcd2),
            bgModal = rgb(0xece6dd),
            rowAlt = rgba(0x5a4635, 14),
            rowSelected = rgba(0xe66f1f, 30),
            buttonBg = rgba(0x5a4635, 22),
            divider = rgba(0x5a4635, 36),
            dividerSoft = rgba(0x5a4635, 24),
            dividerTiny = rgba(0x5a4635, 13),
            borderOverlay = rgba(0x3d2a18, 48),
            textPrimary = rgb(0x2c2420),
            textDim = rgb(0x302520),
            textMuted = rgba(0x5a4a3c, 150),
            textSoft = rgba(0x382c22, 190),
            textToday = rgb(0xd04e1a),
            accent = rgb(0xc04510),
            danger = rgb(0xc72f24),
        )
    }
}
