package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
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
import android.os.Bundle
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
import android.widget.ArrayAdapter
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
    private val editorSchemeIds = WeakHashMap<EditText, String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            bridge = RustBridge(this)
            loadSnapshot()
            applyTheme()
            buildShell()
            render()
        } catch (error: Throwable) {
            theme = UiTheme.dark
            showFatal(error.message)
        }
    }

    override fun onDestroy() {
        if (::bridge.isInitialized) {
            bridge.close()
        }
        super.onDestroy()
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
        dock.visibility = if (wide) View.GONE else View.VISIBLE
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
        titleBar.addView(chip("+") { showNewMenu() }, LinearLayout.LayoutParams(dp(32), dp(28)))
    }

    private fun renderDock() {
        dock.removeAllViews()
        listOf("Calendar", "Schemes", "Daily", "Search", "Settings").forEachIndexed { index, label ->
            val tab = text(label, if (selectedTab == index) theme.textPrimary else theme.textMuted, 11f, true).apply {
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
        if (resources.configuration.screenWidthDp < 760 && ::dock.isInitialized) {
            dock.visibility = View.GONE
        }
    }

    private fun showPhoneDockAfterEditing() {
        if (resources.configuration.screenWidthDp < 760 && ::dock.isInitialized) {
            dock.visibility = View.VISIBLE
        }
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
        panel.addView(archiveNavigatorSection(compact = true), LinearLayout.LayoutParams(-1, -2).apply {
            setMargins(0, dp(4), 0, dp(5))
        })

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
        val root = page()
        root.addView(sectionHeader("Schemes"))
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject {
            addNode(list, it, 0, spacious = true)
        }
        root.addView(list)
        root.addView(archiveNavigatorSection(compact = false), LinearLayout.LayoutParams(-1, -2).apply {
            setMargins(0, dp(12), 0, 0)
        })
        return root
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
            days?.forEachObject { day -> body.addView(dayList(day), spaced()) }
            root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        }
        return root
    }

    private fun calendarToolbar(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            addView(iconChip("<") {
                weekOffset--
                loadSnapshot()
                render()
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_VERTICAL
                val range = "${formatDay(calendar().optString("start_date"))} - ${formatDay(calendar().optString("end_date"))}"
                addView(text(range, theme.textPrimary, 13f, true))
                addView(text("Today", theme.textDim, 11f, true).apply {
                    setOnClickListener {
                        weekOffset = 0
                        selectedDate = LocalDate.now()
                        loadSnapshot()
                        render()
                    }
                })
            }, LinearLayout.LayoutParams(0, -1, 1f).apply { setMargins(dp(8), 0, dp(8), 0) })
            addView(iconChip("+") { showCalendarItemDialog() })
            addView(iconChip(">") {
                weekOffset++
                loadSnapshot()
                render()
            }, LinearLayout.LayoutParams(dp(32), dp(28)).apply { setMargins(dp(6), 0, 0, 0) })
        }.apply {
            background = underline(theme.bgApp)
        }.also {
            it.layoutParams = LinearLayout.LayoutParams(-1, dp(48))
        }
    }

    private fun dayColumn(day: JSONObject): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = rounded(adjust(theme.bgModal, if (theme.isDark) 0.42f else 0.88f), dp(6), theme.dividerSoft)
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
                occurrences.forEachObject { occurrence -> addView(occurrenceRow(occurrence, false), spaced()) }
            }
        }
    }

    private fun eventBlock(occurrence: JSONObject): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(9), dp(7), dp(8), dp(7))
            background = rounded(if (theme.isDark) rgb(0x333333) else rgb(0xd3d2ce), dp(4), schemeColor(occurrence.optInt("color_index")))
            alpha = if (occurrence.optBoolean("done")) 0.45f else 1f
            addView(text(occurrence.optString("title").ifEmpty { occurrence.optString("kind").replaceFirstChar(Char::titlecase) }, theme.textPrimary, 12f, true))
            addView(text(timeLabel(occurrence), theme.textSoft, 10f, true))
            addView(text(occurrence.optString("scheme_name"), schemeColor(occurrence.optInt("color_index")), 10f, true))
            setOnClickListener { openScheme(occurrence.optString("scheme_id")) }
        }
    }

    private fun renderSchemeEditor(scheme: JSONObject): LinearLayout {
        val schemeId = scheme.optString("id")
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
            addView(iconChip("+") {
                activeEditor()?.let(::insertTaskLine) ?: showItemDialog(schemeId, null)
            })
            addView(chip("More") { showSchemeActions(scheme) }, LinearLayout.LayoutParams(dp(64), dp(28)).apply { setMargins(dp(6), 0, 0, 0) })
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val editor = SchemeEditText(this).apply {
            setText(renderDocument(originalLines))
            tag = originalLines
            editorSchemeIds[this] = schemeId
            editorTheme = theme
            accentColor = editorChromeColor()
            lineAdornments = editorLineAdornments(scheme)
            markerTapHandler = { lineIndex -> toggleEditorLineMarker(this, lineIndex) }
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
        root.addView(scroll(editorBody), LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(editorFormatBar(schemeId, editor), LinearLayout.LayoutParams(-1, dp(38)))
        return root
    }

    private fun schemeTitleBlock(scheme: JSONObject): View {
        val schemeId = scheme.optString("id")
        val committed = scheme.optString("display_name", scheme.optString("name"))
        val input = edit(committed).apply {
            setSingleLine(true)
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
            setPadding(dp(14), dp(12), dp(14), dp(20))
            setBackgroundColor(theme.bgApp)
        }
        val days = dailyEntries()
        if (days.isEmpty()) {
            list.addView(emptyState("Daily not ready", "Could not create the daily queue."))
        } else {
            days.forEach { day ->
                list.addView(dailyDayEditor(day), LinearLayout.LayoutParams(-1, -2).apply {
                    setMargins(0, 0, 0, dp(14))
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
                setPadding(dp(6), 0, dp(6), dp(7))
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
        return dp(max(104, visualLines * 25 + 34))
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

    private fun renderSettings(): LinearLayout {
        val root = page()
        root.addView(sectionHeader("Settings"))
        root.addView(text("KnotQ Mobile", theme.textSoft, 11f, false), spaced())
        val settings = snapshot.optJSONObject("settings")
        val themeMode = settings?.optString("theme_mode", "dark") ?: "dark"
        val timeFormat = settings?.optString("time_format", "twelve_hour") ?: "twelve_hour"

        root.addView(settingsSection("Appearance"))
        root.addView(choiceRow("System", themeMode == "system") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "system")) })
        root.addView(choiceRow("Dark", themeMode == "dark") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "dark")) })
        root.addView(choiceRow("Light", themeMode == "light") { mutate(obj("type" to "set_theme_mode", "theme_mode" to "light")) })

        root.addView(settingsSection("Time"))
        root.addView(choiceRow("12-hour", timeFormat == "twelve_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twelve_hour")) })
        root.addView(choiceRow("24-hour", timeFormat == "twenty_four_hour") { mutate(obj("type" to "set_time_format", "time_format" to "twenty_four_hour")) })

        root.addView(settingsSection("Storage"))
        root.addView(text(snapshot.optString("workspace_path"), theme.textSoft, 11f, false).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
        }, spaced())
        root.addView(text("Reset Workspace", theme.danger, 13f, true).apply {
            setPadding(dp(8), dp(10), dp(8), dp(10))
            setOnClickListener {
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("Reset Workspace")
                    .setPositiveButton("Reset") { _, _ -> mutate(obj("type" to "reset_workspace")) }
                    .setNegativeButton("Cancel", null)
                    .show()
            }
        })
        return root
    }

    private fun addNode(parent: LinearLayout, node: JSONObject, depth: Int, spacious: Boolean = false) {
        val kind = node.optString("kind")
        if (kind == "folder") {
            parent.addView(folderRow(node, depth, spacious), if (spacious) LinearLayout.LayoutParams(-1, dp(42)) else rowParams())
            node.optJSONArray("children")?.forEachObject { addNode(parent, it, depth + 1, spacious) }
            return
        }
        val selected = selectedSchemeId == node.optString("id")
        val rowHeight = if (spacious) dp(44) else dp(22)
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 11 else 6) + depth * if (spacious) 14 else 8), 0, dp(7), 0)
            background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, if (spacious) dp(7) else dp(4))
            val squareSize = if (spacious) 12 else 9
            addView(colorSquare(schemeColor(node.optInt("color_index")), squareSize), LinearLayout.LayoutParams(dp(squareSize), dp(squareSize)))
            addView(text(node.optString("name"), theme.textPrimary, if (spacious) 15f else 12f, false).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (spacious) 10 else 7), 0, dp(4), 0)
            })
            if (spacious) {
                addView(text(">", theme.textMuted, 15f, true).apply { gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(18), -1))
            }
            setOnClickListener { openScheme(node.optString("id")) }
            setOnLongClickListener {
                showSchemeActions(node)
                true
            }
        }
        parent.addView(row, LinearLayout.LayoutParams(-1, rowHeight))
    }

    private fun folderRow(node: JSONObject, depth: Int, spacious: Boolean = false): View {
        val label = if (spacious) "⌄  ${node.optString("name")}" else "▾ ${node.optString("name")}"
        return text(label, theme.textPrimary, if (spacious) 15f else 12f, false).apply {
            setPadding(dp((if (spacious) 11 else 6) + depth * if (spacious) 14 else 8), 0, dp(7), 0)
            gravity = Gravity.CENTER_VERTICAL
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
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(7), dp(5), dp(7), dp(5))
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

    private fun commitSchemeDocument(schemeId: String, editor: EditText, rerender: Boolean) {
        ensureTerminalNewline(editor.text, editor.selectionStart)
        val oldLines = (editor.tag as? List<*>)?.filterIsInstance<SchemeEditorLine>().orEmpty()
        val nextLines = reconcileEditorLines(oldLines, parseEditorDocument(editor.text.toString(), preserveBlankDocument = oldLines.isNotEmpty()))
        val array = JSONArray()
        nextLines.forEach { line ->
            array.put(obj(
                "id" to line.id,
                "text" to line.text,
                "marker" to line.marker,
                "indent" to line.indent,
                "done" to line.done
            ))
        }
        try {
            bridge.request(obj("type" to "replace_scheme_items", "scheme_id" to schemeId, "items" to array))
            loadSnapshot()
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
            setOnClickListener { openScheme(occurrence.optString("scheme_id")) }
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
                    2 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name -> mutate(obj("type" to "create_scheme", "name" to name)) }
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
        val form = page(compact = true)
        val title = edit("").apply { hint = "Title" }
        val kind = spinner(arrayOf("event", "reminder", "assignment", "task"))
        val date = DatePicker(this)
        val start = TimePicker(this).apply { setIs24HourView(timeFormat24()) }
        val end = TimePicker(this).apply { setIs24HourView(timeFormat24()) }
        form.addView(title, spaced())
        form.addView(kind, spaced())
        form.addView(date, spaced())
        form.addView(text("Start", theme.textMuted, 12f, true))
        form.addView(start, spaced())
        form.addView(text("End / Due", theme.textMuted, 12f, true))
        form.addView(end)
        AlertDialog.Builder(this)
            .setTitle("New Calendar Item")
            .setView(form)
            .setPositiveButton("Add") { _, _ ->
                val localDate = LocalDate.of(date.year, date.month + 1, date.dayOfMonth)
                val selectedKind = kind.selectedItem.toString()
                val startValue: Any? = if (selectedKind == "event" || selectedKind == "reminder") iso(localDate, start.hour, start.minute) else null
                val endValue: Any? = if (selectedKind == "event" || selectedKind == "assignment") iso(localDate, end.hour, end.minute) else null
                mutate(obj("type" to "add_calendar_item", "kind" to selectedKind, "text" to title.text.toString().trim(), "date" to localDate.toString(), "start" to startValue, "end" to endValue))
            }
            .setNegativeButton("Cancel", null)
            .show()
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
        AlertDialog.Builder(this)
            .setTitle(nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")))
            .setItems(arrayOf("Rename", "Color", "Delete")) { _, which ->
                when (which) {
                    0 -> showNameDialog(
                        "Rename Scheme",
                        nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")),
                        { validateSchemeName(it, folderId = parentFolderIdForScheme(id), excludingId = id, checkDuplicates = !isDaily) }
                    ) { name -> mutate(obj("type" to "rename_scheme", "scheme_id" to id, "name" to name)) }
                    1 -> showColorDialog(id)
                    2 -> if (!isDaily) mutate(obj("type" to "delete_scheme", "scheme_id" to id))
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
            .setItems(arrayOf("New Scheme", "Rename", "Delete")) { _, which ->
                when (which) {
                    0 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = node.optString("id")) }) { name ->
                        mutate(obj("type" to "create_scheme", "folder_id" to node.optString("id"), "name" to name))
                    }
                    1 -> showNameDialog("Rename Folder", node.optString("name"), { validateFolderName(it, excludingId = node.optString("id")) }) { name ->
                        mutate(obj("type" to "rename_folder", "folder_id" to node.optString("id"), "name" to name))
                    }
                    2 -> mutate(obj("type" to "delete_folder", "folder_id" to node.optString("id")))
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
            render()
        } catch (error: RuntimeException) {
            showError("Could not save", error.message)
        }
    }

    private fun loadSnapshot() {
        snapshot = bridge.request(obj("type" to "snapshot", "today" to selectedDate.toString(), "week_offset" to weekOffset))
    }

    private fun applyTheme() {
        val mode = snapshot.optJSONObject("settings")?.optString("theme_mode", "dark") ?: "dark"
        val darkSystem = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        theme = when (mode) {
            "light" -> UiTheme.light
            "system" -> if (darkSystem) UiTheme.dark else UiTheme.light
            else -> UiTheme.dark
        }
        window.statusBarColor = theme.bgToolbar
        window.navigationBarColor = theme.bgSidebar
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

    private fun validateSchemeName(name: String, folderId: String? = null, excludingId: String? = null, checkDuplicates: Boolean = true): String? {
        validateNodeName(name, "Scheme", disallowKnotqExtension = true)?.let { return it }
        if (!checkDuplicates) return null
        val parent = nodeById(folderId ?: rootFolderId(), snapshot.optJSONObject("root")) ?: return null
        if (siblingExists(parent, name, "scheme", excludingId)) {
            return "A scheme named \"$name\" already exists here."
        }
        return null
    }

    private fun validateFolderName(name: String, excludingId: String? = null): String? {
        validateNodeName(name, "Folder", disallowKnotqExtension = false)?.let { return it }
        val parent = snapshot.optJSONObject("root") ?: return null
        if (siblingExists(parent, name, "folder", excludingId)) {
            return "A folder named \"$name\" already exists here."
        }
        return null
    }

    private fun validateNodeName(name: String, label: String, disallowKnotqExtension: Boolean): String? {
        if (name.isEmpty()) return "$label name cannot be empty."
        if (name.trim() != name) return "File or directory name contains leading or trailing whitespace."
        if (name == "." || name == "..") return "File or directory name cannot be . or ..."
        if (name.endsWith(".")) return "File or directory name cannot end with a period."
        if (name.contains("/") || name.contains("\\")) return "File or directory name cannot contain path separators."
        val reservedCharacters = setOf(':', '*', '?', '"', '<', '>', '|')
        name.firstOrNull { it in reservedCharacters }?.let { return "File or directory name cannot contain \"$it\"." }
        if (name.any { it.code < 32 || it.code == 127 }) return "File or directory name cannot contain control characters."
        val reservedNames = setOf("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")
        if (name.startsWith(".") || name.uppercase(Locale.US) in reservedNames) return "\"$name\" is reserved by the operating system."
        if (disallowKnotqExtension && name.lowercase(Locale.US).endsWith(".knotq")) return "Scheme names cannot end in .knotq."
        return null
    }

    private fun siblingExists(parent: JSONObject, name: String, kind: String, excludingId: String?): Boolean {
        val normalized = name.lowercase(Locale.US)
        val children = parent.optJSONArray("children") ?: return false
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            if (child.optString("kind") == kind &&
                child.optString("id") != excludingId &&
                child.optString("name").lowercase(Locale.US) == normalized
            ) {
                return true
            }
        }
        return false
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
        return when {
            start.isNotEmpty() && end.isNotEmpty() -> "$start - $end"
            start.isNotEmpty() -> start
            end.isNotEmpty() -> "Due $end"
            else -> occurrence.optString("kind").replaceFirstChar(Char::titlecase)
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
        val lightPalette = intArrayOf(rgb(0xd4271c), rgb(0xc47400), rgb(0x1e9e40), rgb(0x0064d2), rgb(0x8a3db5), rgb(0xb89400))
        val palette = if (theme.isDark) darkPalette else lightPalette
        return palette[index.floorMod(palette.size)]
    }

    private fun editorChromeColor(): Int =
        if (theme.isDark) rgb(0xb8c9e8) else rgb(0x536a8f)

    private fun rounded(color: Int, radius: Int, strokeColor: Int = Color.TRANSPARENT, strokeWidth: Int = dp(1)): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
            if (strokeColor != Color.TRANSPARENT) setStroke(strokeWidth, strokeColor)
        }

    private fun underline(color: Int): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            setStroke(dp(1), theme.dividerSoft)
        }

    private fun adjust(color: Int, alpha: Float): Int =
        Color.argb((255 * alpha).roundToInt(), Color.red(color), Color.green(color), Color.blue(color))

    private fun rgb(hex: Int): Int = Color.rgb((hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

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

        var marker = "blank"
        var done = false
        when {
            rest.startsWith("[x] ", ignoreCase = true) -> {
                marker = "checkbox"
                done = true
                rest = rest.drop(4)
            }
            rest.startsWith("[ ] ") -> {
                marker = "checkbox"
                rest = rest.drop(4)
            }
            rest.startsWith("- ") || rest.startsWith("* ") -> {
                marker = "bullet"
                rest = rest.drop(2)
            }
            numberedPrefix.find(rest) != null -> {
                marker = "numbered"
                rest = rest.replaceFirst(numberedPrefix, "")
            }
        }

        return SchemeEditorLine(id = null, text = rest, marker = marker, indent = indent, done = done)
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

    private fun adjustColor(color: Int, alpha: Float): Int =
        Color.argb((255 * alpha).roundToInt(), Color.red(color), Color.green(color), Color.blue(color))

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
        private fun rgb(hex: Int): Int = Color.rgb((hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)
        private fun rgba(hex: Int, alpha: Int): Int = Color.argb(alpha, (hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

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
