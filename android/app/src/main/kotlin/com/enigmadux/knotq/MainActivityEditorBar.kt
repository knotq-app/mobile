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

    internal fun MainActivity.editorFormatBar(schemeId: String? = null, editor: EditText? = null): View {
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
            addView(LinearLayout(this@editorFormatBar).apply {
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
    internal fun MainActivity.showCellEditFormatBar(hit: TableCellHit) {
        val host = formatBarHost ?: return
        formatBarCellContent?.let { host.removeView(it) }
        val bar = cellEditFormatBar(hit)
        host.addView(bar, FrameLayout.LayoutParams(-1, -1))
        formatBarCellContent = bar
        formatBarNormalContent?.visibility = View.GONE
    }

    internal fun MainActivity.hideCellEditFormatBar() {
        val host = formatBarHost ?: return
        formatBarCellContent?.let { host.removeView(it) }
        formatBarCellContent = null
        formatBarNormalContent?.visibility = View.VISIBLE
    }

    internal fun MainActivity.cellEditFormatBar(hit: TableCellHit): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(theme.bgToolbar)
            addView(LinearLayout(this@cellEditFormatBar).apply {
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

    internal fun MainActivity.cellBarButton(label: String, enabled: Boolean, action: () -> Unit): TextView =
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

    internal fun MainActivity.activeMarkerForEditor(editor: EditText): String {
        val value = editor.text?.toString().orEmpty()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        val start = value.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newline = value.indexOf('\n', cursor)
        val end = if (newline < 0) value.length else newline
        if (start > end) return "blank"
        return parseEditorLine(value.substring(start, end)).marker
    }

    internal fun MainActivity.activeEditor(): EditText? {
        val focused = currentFocus as? EditText
        if (focused != null && editorSchemeIds.containsKey(focused)) return focused
        return lastActiveEditor?.takeIf { editorSchemeIds.containsKey(it) && it.isAttachedToWindow }
    }

    internal fun MainActivity.focusEditorForTyping(editor: EditText) {
        if (!editor.isAttachedToWindow) return
        editor.isFocusable = true
        editor.isFocusableInTouchMode = true
        editor.requestFocus()
        lastActiveEditor = editor
        keyboardActive = true
        updateChromeVisibility()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
    }

    internal fun MainActivity.formatButton(label: String, action: () -> Unit): TextView =
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

    internal fun MainActivity.formatIconButton(iconRes: Int, description: String, action: () -> Unit): View =
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

    internal fun MainActivity.formatDivider(): View = View(this).apply {
        setBackgroundColor(theme.dividerSoft)
        layoutParams = LinearLayout.LayoutParams(dp(1), dp(18)).apply {
            setMargins(dp(1), 0, dp(6), 0)
        }
    }

    internal fun MainActivity.setCurrentLineMarker(editor: EditText, marker: String) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            val nextDone = marker == "checkbox" && line.marker == "checkbox" && !line.done
            renderEditorLine(line.copy(marker = marker, done = nextDone), 1)
        }
    }

    internal fun MainActivity.toggleEditorLineMarker(editor: EditText, lineIndex: Int) {
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

    internal fun MainActivity.toggleWrappedMarkdown(editor: EditText, delimiter: String) {
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

    internal fun MainActivity.toggleHeading(editor: EditText) {
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

    internal fun MainActivity.shiftCurrentLineIndent(editor: EditText, delta: Int) {
        editCurrentLine(editor) { raw ->
            val line = parseEditorLine(raw)
            renderEditorLine(line.copy(indent = (line.indent + delta).coerceIn(0, 8)), 1)
        }
    }

    internal fun MainActivity.insertTaskLine(editor: EditText) {
        val start = editor.logicalSelectionStart()
        val end = max(start, editor.selectionEnd)
        val prefix = if (start == 0 || editor.text.isEmpty()) "" else "\n"
        editor.text.replace(start, end, "${prefix}[ ] ")
        ensureTerminalNewline(editor.text, editor.selectionStart)
    }

    internal fun MainActivity.editCurrentLine(editor: EditText, transform: (String) -> String) {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        val start = value.lastIndexOf('\n', (cursor - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newline = value.indexOf('\n', cursor)
        val end = if (newline < 0) value.length else newline
        val replacement = transform(value.substring(start, end))
        editor.text.replace(start, end, replacement)
        editor.setSelection((start + replacement.length).coerceAtMost(editor.text.length))
    }

    internal fun MainActivity.editLine(editor: EditText, lineIndex: Int, transform: (String) -> String) {
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

    internal fun MainActivity.openDateForEditorLine(schemeId: String, editor: EditText) {
        commitSchemeDocument(schemeId, editor, rerender = false)
        val line = currentLineIndex(editor)
        val item = findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(line) ?: return
        showDateKindDialog(schemeId, item.optString("id"))
    }

    internal fun MainActivity.insertTableFromEditor(schemeId: String, editor: EditText) {
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

    internal fun MainActivity.freshTableJson(rows: Int = 2, columns: Int = 2): JSONObject {
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

    internal fun MainActivity.freshTableCellJson(): JSONObject =
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

    internal fun MainActivity.focusInsertedTableCell(schemeId: String, itemId: String, lineIndexHint: Int) {
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
    internal fun MainActivity.startImageAttach(schemeId: String, editor: EditText) {
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

