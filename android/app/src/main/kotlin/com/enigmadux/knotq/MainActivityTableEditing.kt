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

    internal fun MainActivity.completeImageAttach(uri: Uri) {
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

    internal fun MainActivity.canReplaceLineWithBlock(item: JSONObject): Boolean =
        item.optString("text").isEmpty() &&
            item.optString("marker", "blank") == "blank" &&
            item.optInt("indent", 0) >= 0 &&
            !item.optBoolean("done", false) &&
            item.optionalString("start") == null &&
            item.optionalString("end") == null &&
            item.optionalString("repeat_rule") == null &&
            item.isNull("notification_offset_secs") &&
            !item.hasBlockContent()

    internal fun MainActivity.blockItemEdit(itemId: String?, indent: Int, media: JSONArray, content: JSONArray): JSONObject =
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

    internal fun MainActivity.itemEditObject(item: JSONObject, line: SchemeEditorLine? = null): JSONObject {
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

    internal fun MainActivity.currentLineIndex(editor: EditText): Int {
        val value = editor.text.toString()
        val cursor = editor.logicalSelectionStart().coerceIn(0, value.length)
        return value.substring(0, cursor).count { it == '\n' }
    }

    internal fun EditText.logicalSelectionStart(): Int {
        val value = text?.toString().orEmpty()
        val raw = max(0, selectionStart).coerceAtMost(value.length)
        return if (raw == value.length && value.endsWith("\n")) max(0, raw - 1) else raw
    }

    internal fun MainActivity.ensureTerminalNewline(editable: Editable, preferredSelection: Int? = null) {
        if (editable.isNotEmpty() && editable.last() == '\n') return
        val selection = (preferredSelection ?: editable.length).coerceIn(0, editable.length)
        editable.append("\n")
        activeEditor()?.setSelection(selection.coerceAtMost(editable.length))
    }

    internal fun MainActivity.placeCursorAtDocumentEnd(editor: EditText) {
        val value = editor.text?.toString().orEmpty()
        val location = if (value.endsWith("\n")) max(0, value.length - 1) else value.length
        editor.setSelection(location.coerceIn(0, editor.text?.length ?: 0))
    }

    internal fun MainActivity.commitSchemeDocument(schemeId: String, editor: EditText, rerender: Boolean) {
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
    internal fun MainActivity.itemIdForLine(schemeId: String, lineIndex: Int): String? =
        findScheme(schemeId)?.optJSONArray("items")?.optJSONObject(lineIndex)?.optString("id")?.takeIf { it.isNotEmpty() }

    /// Returns the live cell texts (one entry per line) for diffing on commit.
    internal fun MainActivity.cellLines(schemeId: String, itemId: String, tableIndex: Int, row: Int, column: Int): List<String> {
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

    internal fun MainActivity.tableFromItem(item: JSONObject, tableIndex: Int): JSONObject? {
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
    internal fun MainActivity.beginInlineCellEdit(schemeId: String, editor: SchemeEditText, hit: TableCellHit) {
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
        (getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
        keyboardActive = true
    }

    internal fun MainActivity.tableOverlayRect(host: FrameLayout, editor: SchemeEditText, rect: RectF): RectF {
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

    internal fun MainActivity.showTableStructureDialog(rowActions: Boolean) {
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

    internal fun MainActivity.performTableStructureAction(action: TableStructureAction) {
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

    internal fun MainActivity.tableStructureFocusTarget(hit: TableCellHit, action: TableStructureAction): Pair<Int, Int> =
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
    internal fun MainActivity.moveInlineCellEdit(editor: SchemeEditText, forward: Boolean) {
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
    internal fun MainActivity.moveInlineCellEditVertical(editor: SchemeEditText) {
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

    internal fun MainActivity.tableDimensions(table: JSONObject): Pair<Int, Int> {
        val rows = table.optJSONArray("rows")?.length() ?: 0
        val columns = max(
            table.optJSONArray("columns")?.length() ?: 0,
            table.optJSONArray("rows")?.optJSONObject(0)?.optJSONArray("cells")?.length() ?: 0
        )
        return rows to columns
    }

    /// Re-opens the inline editor on a target cell once the editor has redrawn
    /// (its cell rects are recomputed on the next draw pass).
    internal fun MainActivity.openCellAfterLayout(schemeId: String, editor: SchemeEditText, hit: TableCellHit, row: Int, col: Int) {
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
    internal fun MainActivity.commitActiveCellEdit(rerender: Boolean) {
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

    internal fun MainActivity.editorForScheme(schemeId: String): SchemeEditText? =
        editorSchemeIds.entries.firstOrNull { it.value == schemeId }?.key as? SchemeEditText

    internal fun MainActivity.dismissInlineCellEditor() {
        commitActiveCellEdit(rerender = true)
    }

    internal fun MainActivity.occurrenceRow(occurrence: JSONObject, striped: Boolean): View {
        val accent = occurrenceSchemeColor(occurrence)
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(if (striped) theme.rowAlt else Color.TRANSPARENT, dp(3))
            alpha = if (occurrence.optBoolean("done")) 0.45f else 1f
            addView(View(this@occurrenceRow).apply { setBackgroundColor(accent) }, LinearLayout.LayoutParams(dp(2), -1).apply {
                setMargins(dp(4), dp(8), dp(6), dp(8))
            })
            addView(LinearLayout(this@occurrenceRow).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(7), dp(8), dp(7))
                addView(LinearLayout(this@occurrenceRow).apply {
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
    internal fun MainActivity.occurrenceSchemeColor(occurrence: JSONObject): Int =
        if (occurrence.optString("scheme_name") == "Daily") dailyAccent()
        else schemeColor(occurrence.optInt("color_index"))

    /// iOS `occurrenceStatusTimeColor`: urgency-tinted time labels (red when
    /// overdue, blue when current/today, lavender for tomorrow).
    internal fun MainActivity.occurrenceStatusTimeColor(occurrence: JSONObject): Int {
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
