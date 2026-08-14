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

    internal fun MainActivity.renderSchemeEditor(scheme: JSONObject): LinearLayout {
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
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@renderSchemeEditor, "common.back"), iconSize = 20) {
                activeEditor()?.let { commitSchemeDocument(schemeId, it, rerender = false) }
                exitSchemeEditor()
            })
            addView(View(this@renderSchemeEditor), LinearLayout.LayoutParams(0, 1, 1f))
            // Insert-table lives on the format toolbar; no separate header chip.
            addView(FrameLayout(this@renderSchemeEditor).apply {
                contentDescription = L10n.t(this@renderSchemeEditor, "mobile.scheme.color_swatch_label")
                background = rounded(theme.buttonBg, dp(7))
                addView(View(this@renderSchemeEditor).apply {
                    background = rounded(schemeColor(scheme.optInt("color_index")), dp(4), theme.borderOverlay)
                }, FrameLayout.LayoutParams(dp(16), dp(16), Gravity.CENTER))
                setOnClickListener { showColorDialog(schemeId) }
            }, LinearLayout.LayoutParams(dp(32), dp(28)))
            if (!scheme.optBoolean("is_daily_queue", false)) {
                addView(iconChipImage(R.drawable.ic_knotq_archive_24, L10n.t(this@renderSchemeEditor, "sidebar.context.archive"), iconSize = 17) {
                    AlertDialog.Builder(this@renderSchemeEditor)
                        .setTitle(L10n.t(this@renderSchemeEditor, "mobile.scheme.archive_confirm_title", mapOf("name" to scheme.optString("display_name", scheme.optString("name")))))
                        .setNegativeButton(L10n.t(this@renderSchemeEditor, "common.cancel"), null)
                        .setPositiveButton(L10n.t(this@renderSchemeEditor, "sidebar.context.archive")) { _, _ ->
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
                // Push-on-type: each edit re-arms a debounce that quietly commits the
                // document to the core (which then syncs over the socket), so phone
                // edits propagate live like desktop instead of only on blur.
                onUserEdit = { scheduleEditorFlush(schemeId, this) }
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
            root.addView(text(L10n.t(this, "mobile.scheme.read_only_notice"), theme.textMuted, 12f, false).apply {
                gravity = Gravity.CENTER
                setBackgroundColor(theme.bgToolbar)
            }, LinearLayout.LayoutParams(-1, dp(38)))
        } else if (!screenshotFixtureRequested()) {
            // The format bar is iOS's keyboard accessory; hide it for clean
            // store screenshots so the scheme reads as a document.
            root.addView(editorFormatBar(schemeId, editor), LinearLayout.LayoutParams(-1, dp(38)))
        }
        return root
    }

    internal fun MainActivity.schemeTitleBlock(scheme: JSONObject): View {
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
        if (pendingTitleFocusSchemeId == schemeId && !scheme.optBoolean("is_read_only", false)) {
            pendingTitleFocusSchemeId = null
            input.post {
                input.requestFocus()
                input.selectAll()
                input.post {
                    (getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
                        ?.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
                }
            }
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(input, LinearLayout.LayoutParams(-1, dp(34)))
            addView(error, LinearLayout.LayoutParams(-1, dp(13)))
        }
    }

    internal fun MainActivity.renderDaily(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        // iOS daily chrome: a floating back chip, no bar or divider.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@renderDaily, "common.back"), iconSize = 20) {
                currentFocus?.clearFocus()
                selectedTab = TAB_HOME
                selectedSchemeId = null
                render()
            })
            addView(View(this@renderDaily), LinearLayout.LayoutParams(0, 1, 1f))
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
            list.addView(emptyState(L10n.t(this, "mobile.daily.not_ready_title"), L10n.t(this, "mobile.daily.not_ready_detail")))
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
        // Position the scroll BEFORE the first frame is painted (a one-shot
        // pre-draw pass) rather than in post{} which runs after a draw at
        // scrollY=0 — that post-draw correction is what made history loads visibly
        // jump. Views are already laid out by pre-draw, so child tops are valid.
        val anchorDate = pendingDailyAnchorDate
        pendingDailyAnchorDate = null
        scrollView.viewTreeObserver.addOnPreDrawListener(
            object : android.view.ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    scrollView.viewTreeObserver.removeOnPreDrawListener(this)
                    when {
                        // After a history load, keep the previously-oldest day in
                        // place instead of yanking back to the selected day.
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
                    return true
                }
            }
        )
        root.addView(scrollView, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(editorFormatBar(), LinearLayout.LayoutParams(-1, dp(38)))
        return root
    }

    /// iOS `isEffectivelyEmpty`: a day whose items carry no text, scheduling,
    /// metadata, or media doesn't earn a row in the feed.
    internal fun MainActivity.isDailyEntryEmpty(day: JSONObject): Boolean {
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
    internal fun MainActivity.dailyDayEditor(day: JSONObject): View {
        val date = day.optString("date")
        val scheme = day.optJSONObject("scheme") ?: return emptyState(MobileDateFormatting.fullDay(date), L10n.t(this, "mobile.daily.not_ready_title"))
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
            val editor = SchemeEditText(this@dailyDayEditor).apply {
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
                // Push-on-type for the Daily editor too (the scheme editor wires this
                // in renderSchemeEditor; the Daily day editor is a separate instance).
                onUserEdit = { scheduleEditorFlush(schemeId, this) }
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
                // The editor is WRAP_CONTENT, so it already sizes to its rendered
                // text; a generous estimated floor (dailyEditorHeight) only padded
                // short days with dead space between sections. Keep a one-line
                // tappable floor and let content drive the height, like iOS which
                // measures each day to its exact content height.
                minHeight = dp(44)
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
            val editorHost = FrameLayout(this@dailyDayEditor).apply {
                addView(editor, FrameLayout.LayoutParams(-1, -2))
            }
            editorHosts[editor] = editorHost
            addView(editorHost, LinearLayout.LayoutParams(-1, -2))
        }
    }

    internal fun MainActivity.dailyAccent(): Int = if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)

    internal fun MainActivity.renderSearch(): View {
        val root = page()
        val query = edit("").apply {
            hint = L10n.t(this@renderSearch, "search.placeholder")
            setSingleLine(true)
            background = rounded(theme.bgModal, dp(7), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
        }
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // The search field and its way out share one row. The exit is not
        // conditional on layout: a wide layout used to have no explicit way back
        // at all, leaving system back as the only exit, and it matches the "x"
        // beside the iPhone's search field.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(query, LinearLayout.LayoutParams(0, dp(46), 1f))
            addView(FrameLayout(this@renderSearch).apply {
                background = rounded(theme.buttonBg, dp(20), theme.borderOverlay)
                addView(
                    iconImage(R.drawable.ic_knotq_close_24, theme.textPrimary, L10n.t(this@renderSearch, "mobile.home.clear_search")),
                    FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER)
                )
                setOnClickListener { exitSearch() }
            }, LinearLayout.LayoutParams(dp(40), dp(40)).apply { setMargins(dp(10), 0, 0, 0) })
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

    internal fun MainActivity.renderSearchResults(results: LinearLayout, query: String) {
        results.removeAllViews()
        if (query.isBlank()) {
            // Same prompt as iOS shows the moment its field takes focus.
            results.addView(emptyState(L10n.t(this, "mobile.search.screen_title"), L10n.t(this, "mobile.search.empty_subtitle")))
            return
        }
        try {
            val hits = bridge.requestArray(obj("type" to "search", "query" to query))
            if (hits.length() == 0) {
                results.addView(emptyState(L10n.t(this, "search.no_results"), L10n.t(this, "mobile.search.no_results_detail", mapOf("query" to query))))
                return
            }
            hits.forEachIndexedObject { idx, hit ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    background = rounded(if (idx % 2 == 1) theme.rowAlt else Color.TRANSPARENT, dp(3))
                    addView(View(this@renderSearchResults).apply { setBackgroundColor(schemeColor(hit.optInt("color_index"))) }, LinearLayout.LayoutParams(dp(2), -1).apply {
                        setMargins(dp(4), dp(8), dp(6), dp(8))
                    })
                    addView(LinearLayout(this@renderSearchResults).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(0, dp(7), dp(8), dp(7))
                        addView(LinearLayout(this@renderSearchResults).apply {
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
            showError(L10n.t(this, "mobile.editor.could_not_save_edits"), error.message)
        }
    }

    internal fun MainActivity.renderSettings(): LinearLayout {
        if (settingsShowingArchive) return renderArchivePage()
        if (settingsShowingTiming) return renderTimingSettingsPage()
        val root = page()
        root.addView(sectionHeader(L10n.t(this, "settings.header.title")))
        root.addView(syncSettingsCard(), spaced())
        val settings = snapshot.optJSONObject("settings")
        val themeMode = settings?.optString("theme_mode", "system") ?: "system"
        val googleAccountCount = settings?.optInt("google_account_count", 0) ?: 0

        root.addView(settingsSection(L10n.t(this, "settings.appearance.section")))
        val themeOptions = arrayOf("system", "dark", "light", "rose_pine_moon", "catppuccin_mocha", "tokyo_night", "parchment", "rose_pine_dawn", "catppuccin_latte")
        val themeLabels = arrayOf(
            L10n.t(this, "settings.appearance.theme_system"),
            L10n.t(this, "settings.appearance.theme_dark"),
            L10n.t(this, "settings.appearance.theme_light"),
            "Moonlit", "Espresso", "Blue Hour", "Parchment", "Dawn", "Cream"
        )
        val themeSpinner = spinner(themeLabels).apply {
            val selected = themeOptions.indexOf(themeMode).coerceAtLeast(0)
            setSelection(selected, false)
            var first = true
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    if (first) { first = false; return }
                    mutate(obj("type" to "set_theme_mode", "theme_mode" to themeOptions[position]))
                }
            }
        }
        styleDialogSpinner(themeSpinner)
        val activity = this
        val themeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(4), 0)
            addView(activity.text(L10n.t(activity, "settings.appearance.theme_label"), theme.textPrimary, 14f, false), LinearLayout.LayoutParams(0, activity.dp(52), 1f))
            addView(themeSpinner, LinearLayout.LayoutParams(dp(190), dp(44)))
        }
        root.addView(settingsGroup(themeRow))

        root.addView(settingsSection(L10n.t(this, "settings.timing.section")))
        root.addView(settingsGroup(
            settingsLinkRow(L10n.t(this, "settings.timing.title")) {
                settingsShowingTiming = true
                render()
            }
        ))

        root.addView(settingsSection(L10n.t(this, "settings.google_calendar.section")))
        if (googleAccountCount > 0) {
            root.addView(settingsGroup(
                settingsLinkRow(
                    if (googleSyncInProgress) L10n.t(this, "mobile.settings.google_syncing") else L10n.t(this, "mobile.settings.sync_google_calendars"),
                    L10n.t(this, "mobile.settings.google_accounts_connected", mapOf("count" to googleAccountCount.toString()))
                ) { syncGoogleCalendars() },
                settingsLinkRow(if (googleAuthInProgress) L10n.t(this, "mobile.settings.google_connecting") else L10n.t(this, "mobile.settings.connect_another_google_account")) { startGoogleCalendarImport() }
            ))
            googleCalendarStatus?.takeIf { it.isNotBlank() }?.let { status ->
                root.addView(text(status, theme.textMuted, 12f, false).apply {
                    setPadding(dp(8), dp(5), dp(8), dp(2))
                })
            }
        } else {
            root.addView(settingsGroup(
                settingsLinkRow(if (googleAuthInProgress) L10n.t(this, "mobile.settings.google_connecting") else L10n.t(this, "mobile.settings.connect_google_calendar")) { startGoogleCalendarImport() }
            ))
        }

        root.addView(settingsSection(L10n.t(this, "sidebar.context.archive")))
        val schemes = archivedSchemes()
        root.addView(settingsGroup(
            settingsLinkRow(L10n.t(this, "mobile.settings.archived_items"), schemes.length().toString()) {
                settingsShowingArchive = true
                render()
            }
        ))
        return root
    }

    internal fun MainActivity.renderTimingSettingsPage(): LinearLayout {
        val settings = snapshot.optJSONObject("settings") ?: JSONObject()
        val timeFormat = settings.optString("time_format", "twelve_hour")
        val eventDays = settings.optInt("event_lookahead_days", 14)
        val reminderDays = settings.optInt("reminder_lookahead_days", 14)
        val assignmentDays = settings.optInt("assignment_lookahead_days", 14)
        val maximumItems = settings.optInt("maximum_upcoming_items", 14)
        val showOverdue = settings.optBoolean("show_overdue", true)
        val showCompleted = settings.optBoolean("show_completed", true)
        val eventOffset = settings.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
        val assignmentOffset = settings.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
        val lookaheadOptions = listOf(1, 2, 3, 7, 14, 30, 90, 180, 365)
        val itemLimitOptions = listOf(5, 10, 14, 20, 30, 50, 100)

        fun updateUpcoming(
            event: Int = eventDays,
            reminder: Int = reminderDays,
            assignment: Int = assignmentDays,
            maximum: Int = maximumItems,
            overdue: Boolean = showOverdue,
            completed: Boolean = showCompleted,
            renderAfter: Boolean = true,
            onSuccess: ((JSONObject) -> Unit)? = null
        ) {
            mutate(
                obj(
                    "type" to "set_upcoming_display_settings",
                    "event_lookahead_days" to event,
                    "reminder_lookahead_days" to reminder,
                    "assignment_lookahead_days" to assignment,
                    "maximum_items" to maximum,
                    "show_overdue" to overdue,
                    "show_completed" to completed
                ),
                renderAfter = renderAfter,
                onSuccess = onSuccess
            )
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@renderTimingSettingsPage, "common.back"), iconSize = 20) {
                settingsShowingTiming = false
                render()
            })
            addView(text(L10n.t(this@renderTimingSettingsPage, "settings.timing.title"), theme.textPrimary, 16f, true).apply {
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(View(this@renderTimingSettingsPage), LinearLayout.LayoutParams(dp(32), dp(28)))
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val body = page()
        body.addView(settingsSection(L10n.t(this, "settings.time.section")))
        body.addView(settingsGroup(
            choiceRow(L10n.t(this, "settings.time.clock_12h"), selected = timeFormat == "twelve_hour") {
                mutate(obj("type" to "set_time_format", "time_format" to "twelve_hour"))
            },
            choiceRow(L10n.t(this, "settings.time.clock_24h"), selected = timeFormat == "twenty_four_hour") {
                mutate(obj("type" to "set_time_format", "time_format" to "twenty_four_hour"))
            }
        ))

        fun lookaheadRow(label: String, current: Int, update: (Int) -> Unit): View =
            settingsLinkRow(label, lookaheadLabel(current)) {
                showSettingsOptionDialog(label, current, lookaheadOptions.map { it to lookaheadLabel(it) }, update)
            }

        body.addView(settingsSection(L10n.t(this, "settings.display.upcoming_section")))
        body.addView(settingsGroup(
            lookaheadRow(L10n.t(this, "settings.notifications.events_label"), eventDays) { updateUpcoming(event = it) },
            lookaheadRow(L10n.t(this, "upcoming.section.reminders"), reminderDays) { updateUpcoming(reminder = it) },
            lookaheadRow(L10n.t(this, "upcoming.section.assignments"), assignmentDays) { updateUpcoming(assignment = it) }
        ))
        body.addView(text(L10n.t(this, "settings.display.lookahead_footer"), theme.textMuted, 12f, false).apply {
            setPadding(dp(6), dp(6), dp(6), 0)
        })

        body.addView(settingsSection(L10n.t(this, "settings.display.visibility_section")))
        body.addView(settingsGroup(
            settingsToggleRow(L10n.t(this, "settings.display.show_overdue"), showOverdue) { updateUpcoming(overdue = it) },
            settingsToggleRow(L10n.t(this, "settings.display.show_completed"), showCompleted) { updateUpcoming(completed = it) },
            settingsLinkRow(L10n.t(this, "settings.display.maximum_items"), maximumItems.toString()) {
                showSettingsOptionDialog(
                    L10n.t(this, "settings.display.maximum_items"),
                    maximumItems,
                    itemLimitOptions.map { it to it.toString() }
                ) { updateUpcoming(maximum = it) }
            }
        ))

        body.addView(settingsSection(L10n.t(this, "settings.notifications.section")))
        body.addView(settingsGroup(
            settingsLinkRow(L10n.t(this, "settings.notifications.events_label"), notificationLeadTimeLabel(eventOffset, eventDefault = true)) {
                showNotificationDefaultDialog(L10n.t(this, "mobile.settings.event_reminders_title"), eventOffset, eventDefaultNotificationOptions) { next ->
                    mutate(obj("type" to "set_notification_defaults", "event_offset_secs" to next, "assignment_offset_secs" to assignmentOffset))
                }
            },
            settingsLinkRow(L10n.t(this, "settings.notifications.assignments_label"), notificationLeadTimeLabel(assignmentOffset, eventDefault = false)) {
                showNotificationDefaultDialog(L10n.t(this, "mobile.settings.assignment_reminders_title"), assignmentOffset, assignmentDefaultNotificationOptions) { next ->
                    mutate(obj("type" to "set_notification_defaults", "event_offset_secs" to eventOffset, "assignment_offset_secs" to next))
                }
            }
        ))

        val usingDefaults = timeFormat == "twelve_hour" && eventDays == 14 && reminderDays == 14 &&
            assignmentDays == 14 && maximumItems == 14 && showOverdue && showCompleted &&
            eventOffset == DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS &&
            assignmentOffset == DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
        body.addView(View(this), LinearLayout.LayoutParams(-1, dp(16)))
        body.addView(settingsGroup(settingsActionRow(L10n.t(this, "settings.display.restore_defaults"), enabled = !usingDefaults) {
            updateUpcoming(
                event = 14,
                reminder = 14,
                assignment = 14,
                maximum = 14,
                overdue = true,
                completed = true,
                renderAfter = false,
                onSuccess = {
                mutate(
                    obj(
                        "type" to "set_notification_defaults",
                        "event_offset_secs" to DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS,
                        "assignment_offset_secs" to DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
                    ),
                    renderAfter = false,
                    onSuccess = {
                        mutate(obj("type" to "set_time_format", "time_format" to "twelve_hour"))
                    }
                )
            })
        }))

        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    private fun MainActivity.lookaheadLabel(days: Int): String = when (days) {
        7 -> L10n.plural(this, "sync.disclosure.period_weeks", 1)
        14 -> L10n.plural(this, "sync.disclosure.period_weeks", 2)
        30 -> L10n.plural(this, "sync.disclosure.period_months", 1)
        90 -> L10n.plural(this, "sync.disclosure.period_months", 3)
        180 -> L10n.plural(this, "sync.disclosure.period_months", 6)
        365 -> L10n.plural(this, "sync.disclosure.period_years", 1)
        else -> L10n.plural(this, "sync.disclosure.period_days", days)
    }

    private fun MainActivity.showSettingsOptionDialog(
        title: String,
        current: Int,
        options: List<Pair<Int, String>>,
        onSelect: (Int) -> Unit
    ) {
        val labels = options.map { (value, label) ->
            if (value == current) "$label $GLYPH_TICK" else label
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(labels) { _, which -> onSelect(options[which].first) }
            .show()
    }

    internal fun MainActivity.syncSettingsCard(): View {
        // Accounts/sync are compiled out of release builds. Keep the card slot but
        // render a "coming soon" message instead of any sign-in/sync/subscribe UI.
        if (!BuildConfig.ACCOUNTS_ENABLED) {
            return LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), dp(12), dp(12), dp(12))
                background = rounded(
                    if (theme.isDark) adjustAlpha(rgb(0x3b82f6), 0.086f) else rgb(0xeaf2ff),
                    dp(8),
                    if (theme.isDark) adjustAlpha(rgb(0x7aa0ff), 0.27f) else adjustAlpha(rgb(0x2f67cf), 0.22f)
                )
                elevation = dp(if (theme.isDark) 5 else 2).toFloat()
                addView(LinearLayout(this@syncSettingsCard).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.TOP
                    addView(brandMark(34), LinearLayout.LayoutParams(dp(34), dp(34)).apply {
                        setMargins(0, dp(2), dp(9), 0)
                    })
                    addView(LinearLayout(this@syncSettingsCard).apply {
                        orientation = LinearLayout.VERTICAL
                        addView(text(L10n.t(this@syncSettingsCard, "settings.sync.title"), theme.textPrimary, 15f, true), LinearLayout.LayoutParams(-1, dp(18)))
                        addView(text("Cross-device sync and accounts are coming soon.", theme.textSoft, 11f, false).apply {
                            maxLines = 3
                        }, LinearLayout.LayoutParams(-1, -2))
                    }, LinearLayout.LayoutParams(0, -2, 1f))
                })
            }
        }
        val session = syncSession
        // Cancelled (won't renew) but still entitling: amber "Cancelled" badge, like
        // the not-yet-subscribed state, with a re-enable action below.
        val cancelled = session?.supportsSync == true && syncSubscriptionCancelled
        // Signed in, not subscribed, and the email is confirmed unverified: subscribing
        // is blocked until they verify, so the card prompts for that instead.
        val needsVerification = session != null && session.supportsSync != true && syncEmailVerified == false
        val badge = when {
            session != null && syncOffline -> L10n.t(this, "sync.status.offline")
            cancelled -> L10n.t(this, "settings.sync.badge_cancelled")
            session?.supportsSync == true -> L10n.t(this, "mobile.sync.badge_enabled")
            needsVerification -> L10n.t(this, "mobile.sync.badge_verify_email")
            session != null -> L10n.t(this, "mobile.sync.badge_upgrade")
            else -> L10n.t(this, "settings.sync.badge_available")
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
            session != null && syncOffline -> L10n.t(this, "mobile.sync.detail_offline")
            cancelled -> L10n.t(this, "mobile.sync.detail_cancelled")
            needsVerification -> L10n.t(this, "mobile.sync.detail_needs_verification")
            session != null -> session.email
            else -> L10n.t(this, "settings.sync.detail_available")
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
            addView(LinearLayout(this@syncSettingsCard).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.TOP
                // iOS card header: brand logo beside the title.
                addView(brandMark(34), LinearLayout.LayoutParams(dp(34), dp(34)).apply {
                    setMargins(0, dp(2), dp(9), 0)
                })
                addView(LinearLayout(this@syncSettingsCard).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(text(L10n.t(this@syncSettingsCard, "settings.sync.title"), theme.textPrimary, 15f, true), LinearLayout.LayoutParams(-1, dp(18)))
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
            addView(LinearLayout(this@syncSettingsCard).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                if (session == null) {
                    addView(syncCardButton(L10n.t(this@syncSettingsCard, "sync.sign_in"), primary = true) { showSyncAccountDialog() }, LinearLayout.LayoutParams(0, dp(32), 1f))
                } else {
                    // iOS layout: a primary action on the left (Resync when enabled,
                    // Re-enable/Subscribe otherwise) and account housekeeping behind a
                    // single "Manage" menu so destructive options don't dominate.
                    val leftLabel: String
                    val leftPrimary: Boolean
                    val leftAction: () -> Unit
                    when {
                        cancelled -> {
                            leftLabel = L10n.t(this@syncSettingsCard, "account.reenable.label"); leftPrimary = true; leftAction = { reEnableSyncSubscription() }
                        }
                        needsVerification -> {
                            leftLabel = when {
                                resendVerificationInProgress -> L10n.t(this@syncSettingsCard, "account.verify.sending")
                                resendVerificationCooldown > 0 -> L10n.t(this@syncSettingsCard, "mobile.sync.resend_in_seconds", mapOf("seconds" to resendVerificationCooldown.toString()))
                                else -> L10n.t(this@syncSettingsCard, "mobile.sync.resend_verification")
                            }
                            leftPrimary = true
                            leftAction = { resendVerificationEmail() }
                        }
                        !session.supportsSync -> {
                            // Primary action is to start the Google Play billing flow
                            // (iOS parity). Restoring an existing purchase stays in the
                            // "Manage" menu for the new-device / reinstall case.
                            leftLabel = if (purchaseInProgress) L10n.t(this@syncSettingsCard, "mobile.sync.subscribing") else L10n.t(this@syncSettingsCard, "account.subscribe.label")
                            leftPrimary = true
                            leftAction = { startGooglePlaySubscribe() }
                        }
                        else -> {
                            leftLabel = if (syncInProgress) L10n.t(this@syncSettingsCard, "sync.action.resyncing") else L10n.t(this@syncSettingsCard, "sync.action.resync"); leftPrimary = false; leftAction = { syncOnce() }
                        }
                    }
                    addView(syncCardButton(leftLabel, primary = leftPrimary, listener = leftAction),
                        LinearLayout.LayoutParams(0, dp(32), 1f).apply { setMargins(0, 0, dp(8), 0) })
                    addView(syncCardButton(L10n.t(this@syncSettingsCard, "account.manage.label")) { showSyncAccountDialog() }, LinearLayout.LayoutParams(-2, dp(32)))
                }
            }, LinearLayout.LayoutParams(-1, dp(32)).apply {
                setMargins(0, dp(8), 0, 0)
            })
        }
    }

    internal fun MainActivity.showNotificationDefaultDialog(
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

    internal fun MainActivity.addNode(parent: LinearLayout, node: JSONObject, depth: Int, spacious: Boolean = false) {
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
            addView(FrameLayout(this@addNode).apply {
                addView(View(this@addNode).apply {
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

    internal fun MainActivity.folderRow(node: JSONObject, depth: Int, spacious: Boolean = false): View {
        val slot = if (spacious) 18 else 16
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp((if (spacious) 8 else 6) + depth * if (spacious) 10 else 8), 0, dp(7), 0)
            addView(FrameLayout(this@folderRow).apply {
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

    internal fun MainActivity.itemRow(schemeId: String, item: JSONObject, index: Int, count: Int): View {
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
            addView(LinearLayout(this@itemRow).apply {
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
                addView(LinearLayout(this@itemRow).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(smallAction(L10n.t(this@itemRow, "mobile.scheme.item_action_marker")) { showMarkerDialog(schemeId, item.optString("id")) })
                    addView(smallAction(L10n.t(this@itemRow, "mobile.scheme.item_action_outdent")) {
                        mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to max(item.optInt("indent") - 1, 0)))
                    })
                    addView(smallAction(L10n.t(this@itemRow, "mobile.scheme.item_action_indent")) {
                        mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to min(item.optInt("indent") + 1, 8)))
                    })
                    addView(smallAction(L10n.t(this@itemRow, "mobile.scheme.item_action_date")) { showDateKindDialog(schemeId, item.optString("id")) })
                    addView(text(item.optString("kind").replaceFirstChar(Char::titlecase), theme.textMuted, 11f, true))
                })
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(8), 0, 0, 0) })
            setOnLongClickListener {
                showItemActions(schemeId, item, index, count)
                true
            }
        }
    }
