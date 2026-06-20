package com.enigmadux.knotq

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.os.Build
import android.text.Editable
import android.text.Layout
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.StaticLayout
import android.text.TextWatcher
import android.text.TextPaint
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LineBackgroundSpan
import android.text.style.LineHeightSpan
import android.text.style.LeadingMarginSpan
import android.text.style.ReplacementSpan
import android.text.style.StyleSpan
import android.text.style.StrikethroughSpan
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.widget.EditText
import android.widget.LinearLayout
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal const val EDITOR_TEXT_LEFT_PAD_DP = 35
internal const val EDITOR_MARKER_SLOT_DP = 21
internal const val EDITOR_INDENT_WIDTH_DP = 15
internal const val EDITOR_CHECKBOX_SIZE_DP = 14
internal const val EDITOR_ANNOTATION_HEIGHT_DP = 14
internal const val EDITOR_ANNOTATION_BAR_GAP_DP = 8
internal const val EDITOR_ANNOTATION_TEXT_GAP_DP = 7
internal const val EDITOR_INDENT_GUIDE_X_SHIFT_DP = 2
internal const val EDITOR_IMAGE_TOP_GAP_DP = 8
internal const val EDITOR_IMAGE_STACK_GAP_DP = 7
internal const val EDITOR_IMAGE_MAX_HEIGHT_DP = 300
internal const val EDITOR_IMAGE_FALLBACK_WIDTH_DP = 320
internal const val EDITOR_IMAGE_FALLBACK_HEIGHT_DP = 180
internal const val EDITOR_TABLE_TOP_GAP_DP = 8
// iOS `tableCellHeight` (min body-row height) and `tableHeaderHeight`.
internal const val EDITOR_TABLE_ROW_HEIGHT_DP = 36
internal const val EDITOR_TABLE_HEADER_HEIGHT_DP = 30
internal const val EDITOR_TABLE_CELL_PAD_DP = 8
// How much vertical space a collapsed block-only text line gives back. Roughly
// one text line so the block draws in place rather than below a blank row.
internal const val EDITOR_COLLAPSE_TEXT_HEIGHT_DP = 22
// Object Replacement Character: a block line's body is exactly this one char, so
// the cursor can sit on/around the block and select+delete removes it. Mirrors
// the desktop editor's `TABLE_OBJECT_CHAR` and iOS's `blockObjectChar` (both
// `\u{fffc}`). It is an editor-buffer-only sentinel — the model stores empty
// text for block items and rebuilds the char on render.
internal const val BLOCK_OBJECT_CHAR = '￼'
internal const val BLOCK_OBJECT_STRING = "￼"
// Caret heights matching iOS `caretRect`: a plain text line clamps the caret to
// the text line height, a heading to its taller line, and a block line lets the
// caret span the whole block (so it reads as active/selected).
internal const val EDITOR_TEXT_LINE_HEIGHT_DP = 22
internal const val EDITOR_HEADING_LINE_HEIGHT_DP = 30
internal class FixedHeightCursorDrawable(
    color: Int,
    var maxHeightPx: Int,
    private val widthPx: Int
) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }

    override fun draw(canvas: Canvas) {
        val cursorHeight = min(maxHeightPx, bounds.height())
        val radius = widthPx / 2f
        canvas.drawRoundRect(
            bounds.left.toFloat(),
            bounds.top.toFloat(),
            (bounds.left + widthPx).toFloat(),
            (bounds.top + cursorHeight).toFloat(),
            radius,
            radius,
            paint
        )
    }

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    override fun getIntrinsicWidth(): Int = widthPx
}

internal class MaxWidthLinearLayout(context: android.content.Context, private val maxWidthPx: Int) : LinearLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = View.MeasureSpec.getSize(widthMeasureSpec)
        val mode = View.MeasureSpec.getMode(widthMeasureSpec)
        val constrainedWidth = if (width > 0) min(width, maxWidthPx) else maxWidthPx
        super.onMeasure(View.MeasureSpec.makeMeasureSpec(constrainedWidth, mode), heightMeasureSpec)
    }
}

internal class SchemeEditText(context: android.content.Context) : EditText(context) {
    private val chromePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val imageCache = HashMap<String, Bitmap?>()

    var editorTheme: UiTheme = UiTheme.dark
        set(value) {
            field = value
            applyCursorDrawable()
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
            invalidate()
        }

    private var caretDrawable: FixedHeightCursorDrawable? = null

    /// Lines reserve extra height below the text for blocks/annotations, which
    /// the stock caret would stretch across. The caret height is set per line in
    /// `updateCaretHeight` to mirror iOS `caretRect`: text/heading lines clamp to
    /// their line height; a block line lets the caret span the whole block.
    private fun applyCursorDrawable() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val drawable = FixedHeightCursorDrawable(
                color = editorTheme.accent,
                maxHeightPx = dp(EDITOR_TEXT_LINE_HEIGHT_DP),
                widthPx = max(2, dp(2))
            )
            caretDrawable = drawable
            textCursorDrawable = drawable
            updateCaretHeight()
        }
    }

    /// Sizes the caret to the line it sits on (mirrors iOS `caretRect`): a block
    /// line lets the caret span the whole block (so it reads as active/selected
    /// before/after the block); a heading uses the taller heading height; a plain
    /// text line clamps to the regular text height so the caret never stretches
    /// across a block's reserved area.
    private fun updateCaretHeight() {
        val drawable = caretDrawable ?: return
        val value = text?.toString().orEmpty()
        val caret = selectionStart.coerceIn(0, value.length)
        val lineStart = if (caret == 0) 0 else value.lastIndexOf('\n', caret - 1).let { if (it < 0) 0 else it + 1 }
        val nl = value.indexOf('\n', caret)
        val lineEnd = if (nl < 0) value.length else nl
        val raw = value.substring(lineStart, lineEnd.coerceAtLeast(lineStart))
        val body = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
        val next = when {
            // A block line: don't clamp — the drawable spans the line's full
            // height (the block box), so the caret runs the block's left/right edge.
            body == BLOCK_OBJECT_STRING -> Int.MAX_VALUE / 4
            isMarkdownHeading(body) -> dp(EDITOR_HEADING_LINE_HEIGHT_DP)
            else -> dp(EDITOR_TEXT_LINE_HEIGHT_DP)
        }
        if (drawable.maxHeightPx != next) {
            drawable.maxHeightPx = next
            invalidate()
        }
    }
    var accentColor: Int = Color.BLUE
        set(value) {
            field = value
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
            invalidate()
        }
    private var chromeAdornments: List<EditorLineAdornment>? = emptyList()
    // True once AdornmentSpans have been attached to the live buffer. While true,
    // spans are the sole source of truth; the index-based list is only consulted
    // before spans exist (initial draw, or when set with no editable buffer).
    private var hasAdornmentSpans = false
    var lineAdornments: List<EditorLineAdornment>
        get() = chromeAdornments.orEmpty()
        set(value) {
            chromeAdornments = value
            hasAdornmentSpans = false
            editableText?.let { editable ->
                // Attach AdornmentSpans to each line's trailing '\n' so they move
                // with text edits (pure index-based lookup goes stale when lines
                // are inserted/deleted above a block during live editing).
                editable.getSpans(0, editable.length, AdornmentSpan::class.java).forEach { editable.removeSpan(it) }
                val text = editable.toString()
                var lineStart = 0
                for (adornment in value) {
                    val nl = text.indexOf('\n', lineStart)
                    if (nl < 0) break
                    // Anchor a block line's adornment to its object char (the stable
                    // block marker) rather than the trailing '\n': editing the line
                    // below (Enter / backspace to delete an empty line) shifts or
                    // deletes that '\n', which would otherwise drop the block.
                    val objPos = text.indexOf(BLOCK_OBJECT_CHAR, lineStart)
                    val anchor = if (objPos in lineStart until nl) objPos else nl
                    editable.setSpan(AdornmentSpan(adornment), anchor, anchor + 1, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                    lineStart = nl + 1
                    hasAdornmentSpans = true
                }
                applyPrefixSpans(editable, fullDocument = true)
            }
            updateCaretHeight()
        }

    // Looks up the adornment for the line whose '\n' is at `nlOffset`. Once spans
    // are attached they are authoritative: a line whose '\n' carries no span has
    // no adornment, even if the stale index-based list still references one (which
    // would otherwise draw the block a second time on a diverged physical line).
    private fun adornmentForLine(lineIndex: Int, lineStart: Int, nlOffset: Int): EditorLineAdornment? {
        if (hasAdornmentSpans) {
            val editable = editableText ?: return null
            // The span sits on the line's object char (block lines) or its trailing
            // '\n' (everything else), so search the whole line, not just the '\n'.
            val from = lineStart.coerceIn(0, editable.length)
            val to = (nlOffset + 1).coerceIn(from, editable.length)
            val spans = editable.getSpans(from, to, AdornmentSpan::class.java)
            if (spans.isNotEmpty()) return spans[0].adornment
            return null
        }
        return chromeAdornments?.getOrNull(lineIndex)
    }
    var markerTapHandler: ((Int) -> Unit)? = null
    var selectionChangedHandler: (() -> Unit)? = null
    // Inline table interactions. `tableCellTapHandler` is invoked with the
    // logical line (item), the cell's row/column, and the cell's on-screen rect
    // so the host can float an editable field over it. Row/column add+delete
    // happen through the floated cell editor's Rows/Columns menu (as on iOS).
    var tableCellTapHandler: ((TableCellHit) -> Unit)? = null
    var activeTableCellEdit: TableCellHit? = null
        set(value) {
            field = value
            invalidate()
        }
    // Populated on every draw pass; consumed by touch hit-testing.
    private val tableCellHits = ArrayList<TableCellHit>()

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        // A line's indent + marker is literal prefix text, but it is chrome (drawn
        // in the gutter and hidden in the run), not content: the caret must never
        // sit inside it. Snap a collapsed caret (e.g. from a tap in the gutter)
        // forward to the body start. Arrow-key crossings are handled in onKeyDown,
        // before the movement method runs, since a setSelection here would be
        // overridden by it. Matches iOS/desktop, where the prefix isn't text.
        if (!styling && !clampingCaret && selStart == selEnd) {
            val bodyStart = bodyStartFor(selStart)
            if (selStart < bodyStart) {
                clampingCaret = true
                setSelection(bodyStart)
                clampingCaret = false
                return
            }
        }
        if (!styling) {
            editableText?.let { editable ->
                if (updateRevealedMarkdownRange(editable.toString())) {
                    applyPrefixSpans(editable, fullDocument = true)
                }
            }
        }
        updateCaretHeight()
        selectionChangedHandler?.invoke()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        // Make horizontal arrows treat the indent+marker prefix as if it weren't
        // there: left off the body start jumps to the previous line's end, and
        // right off a line end lands on the next line's body start — never inside a
        // gutter. Handled here (not in onSelectionChanged) so the movement method
        // doesn't clobber the adjusted selection.
        if (selectionStart == selectionEnd) {
            val value = text?.toString().orEmpty()
            val p = selectionStart.coerceIn(0, value.length)
            when (keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> {
                    val bodyStart = bodyStartFor(p)
                    if (p <= bodyStart && bodyStart > 0) {
                        val lineStart = if (p == 0) 0 else value.lastIndexOf('\n', p - 1) + 1
                        setSelection(if (lineStart > 0) lineStart - 1 else bodyStart)
                        return true
                    }
                }
                KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    if (p + 1 < value.length && value[p] == '\n') {
                        setSelection(bodyStartFor(p + 1))
                        return true
                    }
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// The first caret offset past a line's indent+marker prefix (the body start)
    /// for the line containing `pos`.
    private fun bodyStartFor(pos: Int): Int {
        val value = text?.toString().orEmpty()
        if (value.isEmpty()) return 0
        val p = pos.coerceIn(0, value.length)
        val lineStart = if (p == 0) 0 else value.lastIndexOf('\n', p - 1) + 1
        val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
        val prefixLen = chromePrefixLength(value.substring(lineStart, lineEnd))
            .coerceAtMost(lineEnd - lineStart)
        return lineStart + prefixLen
    }

    override fun onFocusChanged(focused: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(focused, direction, previouslyFocusedRect)
        if (!styling) {
            editableText?.let { editable ->
                updateRevealedMarkdownRange(editable.toString())
                applyPrefixSpans(editable, fullDocument = true)
            }
        }
    }

    private var styling = false
    private var pendingEditStart = -1
    private var pendingEditEnd = -1
    private var deletionBrokePrefix = false
    private var revealedMarkdownStart = -1
    private var revealedMarkdownEnd = -1
    // Guards the re-entrant setSelection used to snap the caret out of a prefix.
    private var clampingCaret = false

    init {
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {
                if (styling || s == null) return
                // Flag deletions that bite into a line's *valid* marker token,
                // judged against the pre-edit text so ordinary body text that
                // merely looks marker-ish ("*bold*", "-5") is never touched.
                deletionBrokePrefix = count > after &&
                    deletionDamagesPrefix(s.toString(), start, count)
            }
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                if (styling) return
                pendingEditStart = start
                pendingEditEnd = start + count
            }
            override fun afterTextChanged(s: Editable?) {
                if (!styling && s != null && BaseInputConnection.getComposingSpanStart(s) < 0) {
                    enforceTerminalNewline(s)
                    if (deletionBrokePrefix) {
                        deletionBrokePrefix = false
                        repairBrokenPrefix(s)
                    }
                    // Keep a block's object char alone on its line (iOS invariant
                    // I4): typing on / merging into a block line moves the text to a
                    // fresh adjacent line so the block survives instead of demoting.
                    enforceBlockObjectIsolation(s)
                    handleEnterContinuation(s)
                    applyPrefixSpans(s, fullDocument = true)
                }
                invalidate()
            }
        })
    }

    private fun deletionDamagesPrefix(value: String, start: Int, count: Int): Boolean {
        val anchor = start.coerceIn(0, value.length)
        val lineStart = if (anchor == 0) 0 else value.lastIndexOf('\n', anchor - 1).let { if (it < 0) 0 else it + 1 }
        if (lineStart > anchor) return false
        val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
        if (lineStart >= lineEnd) return false
        val line = value.substring(lineStart, lineEnd)
        val prefixLength = chromePrefixLength(line)
        if (prefixLength <= 0) return false
        val indentLength = lineIndentLength(line)
        if (indentLength >= prefixLength) return false
        val tokenStart = lineStart + indentLength
        val tokenEnd = lineStart + prefixLength
        return start < tokenEnd && start + count > tokenStart
    }

    /// iOS clear-marker backspace, adapted to literal prefixes: a deletion that
    /// bit into a marker token strips whatever is left of the token in one
    /// step (keeping the indent), instead of leaving partial glyph text like
    /// "[ ]" or "1." behind as visible body text.
    private fun repairBrokenPrefix(editable: Editable) {
        val editStart = pendingEditStart
        if (editStart < 0) return
        val value = editable.toString()
        val anchor = editStart.coerceIn(0, value.length)
        val lineStart = if (anchor == 0) 0 else value.lastIndexOf('\n', anchor - 1).let { if (it < 0) 0 else it + 1 }
        if (lineStart > anchor) return
        val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
        if (lineStart >= lineEnd) return
        val line = value.substring(lineStart, lineEnd)
        if (chromePrefixLength(line) > 0) return
        val indentLength = lineIndentLength(line)
        val rest = line.drop(indentLength)
        val remnantLength = brokenPrefixRemnantLength(rest) ?: return
        styling = true
        editable.replace(lineStart + indentLength, lineStart + indentLength + remnantLength, "")
        setSelection((lineStart + indentLength).coerceAtMost(editable.length))
        styling = false
        pendingEditStart = -1
        pendingEditEnd = -1
    }

    private fun lineIndentLength(line: String): Int {
        var rest = line
        var length = 0
        while (rest.startsWith("    ")) {
            rest = rest.drop(4)
            length += 4
        }
        while (rest.startsWith("\t")) {
            rest = rest.drop(1)
            length += 1
        }
        return length
    }

    private fun brokenPrefixRemnantLength(rest: String): Int? {
        brokenCheckboxPrefix.find(rest)?.takeIf { it.value.isNotEmpty() }?.let { return it.value.length }
        brokenNumberedPrefix.find(rest)?.let { return it.value.length }
        if (rest.startsWith("-") || rest.startsWith("*")) return 1
        return null
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
        // Highlights are painted *behind* the glyphs (before the text layer) and
        // sized to the text run, not the line box. Lines that reserve extra
        // height for blocks/annotations would otherwise make a stock
        // BackgroundColorSpan bleed down across the whole reserved area (iOS
        // draws the highlight on the run, so it stays tight).
        drawMarkdownHighlights(canvas)
        super.onDraw(canvas)
        drawEditorChrome(canvas)
    }

    /// Paints the translucent gold background behind every `==…==` run, clipped
    /// to the text's own ascent/descent so it never spills into a line's
    /// reserved block/annotation height. Mirrors iOS's run-level highlight.
    private fun drawMarkdownHighlights(canvas: Canvas) {
        val layout = layout ?: return
        val editable = editableText ?: return
        val spans = editable.getSpans(0, editable.length, EditorMarkdownHighlightSpan::class.java)
        if (spans.isEmpty()) return
        val fm = paint.fontMetricsInt
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = EDITOR_HIGHLIGHT_COLOR
        for (span in spans) {
            val spanStart = editable.getSpanStart(span)
            val spanEnd = editable.getSpanEnd(span)
            if (spanEnd <= spanStart) continue
            val firstLine = layout.getLineForOffset(spanStart)
            val lastLine = layout.getLineForOffset(spanEnd)
            for (line in firstLine..lastLine) {
                val segStart = if (line == firstLine) spanStart else layout.getLineStart(line)
                val segEnd = if (line == lastLine) spanEnd else layout.getLineEnd(line)
                if (segEnd <= segStart) continue
                val x1 = layout.getPrimaryHorizontal(segStart) + totalPaddingLeft
                val x2 = layout.getPrimaryHorizontal(segEnd) + totalPaddingLeft
                val baseline = (layout.getLineBaseline(line) + totalPaddingTop - scrollY).toFloat()
                canvas.drawRect(min(x1, x2), baseline + fm.ascent, max(x1, x2), baseline + fm.descent, chromePaint)
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            // Table chrome is hit-tested first: a tap on a cell takes priority
            // over caret placement / marker toggles.
            tableCellHits.firstOrNull { it.rect.contains(event.x, event.y) }?.let { hit ->
                tableCellTapHandler?.invoke(hit)
                return true
            }
            markerLineAt(event.x, event.y)?.let { line ->
                markerTapHandler?.invoke(line)
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /// Looks up the on-screen rect of a table cell recorded in the last draw
    /// pass, used to re-open the inline editor on Tab/next navigation.
    fun cellRectFor(lineIndex: Int, tableIndex: Int, row: Int, column: Int): RectF? =
        tableCellHits.firstOrNull {
            it.lineIndex == lineIndex && it.tableIndex == tableIndex && it.row == row && it.column == column
        }?.let { RectF(it.rect) }

    private fun markerLineAt(x: Float, y: Float): Int? {
        // iOS `checkboxLineRange`: only checkbox markers respond to taps (a
        // padded hit area around the box itself); bullet/numbered glyphs and
        // the left gutter just place the caret.
        val layout = layout ?: return null
        val value = text?.toString().orEmpty()
        for (visualLine in 0 until layout.lineCount) {
            val lineStart = layout.getLineStart(visualLine)
            if (lineStart > 0 && value.getOrNull(lineStart - 1) != '\n') continue
            val logicalLine = value.substring(0, lineStart).count { it == '\n' }
            val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
            val raw = value.substring(lineStart, lineEnd)
            val parsed = parseChromeLine(raw)
            if (parsed.marker != "checkbox") continue
            val prefixWidth = prefixVisualWidth(parsed, parsed.marker)
            val nlOffset = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
            val adornment = adornmentForLine(logicalLine, lineStart, nlOffset)
            val body = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
            val blocks = blocksForBody(body, adornment)
            val extraHeight = extraHeightFor(adornment, blocks, prefixWidth, collapsesText(blocks))
            val rect = markerRect(
                parsed.indent,
                totalPaddingTop + layout.getLineTop(visualLine) - scrollY,
                totalPaddingTop + layout.getLineBottom(visualLine) - scrollY - extraHeight
            )
            rect.inset(-dp(8).toFloat(), -dp(8).toFloat())
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
        removeSpansInRange(editable, rangeStart, rangeEnd, BlockObjectSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, DoneTextSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, DoneTextColorSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorChromeSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorHangingIndentSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorMarkdownSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorMarkdownHighlightSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorMarkdownMarkerSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorMarkdownStrikeSpan::class.java)
        removeSpansInRange(editable, rangeStart, rangeEnd, EditorTextSizeSpan::class.java)
        updateRevealedMarkdownRange(value)

        var start = rangeStart
        var lineIndex = lineIndexAtStart
        while (start <= rangeEnd) {
            if (start == value.length && value.endsWith("\n")) break
            val nlInText = value.indexOf('\n', start)
            val end = if (nlInText < 0 || nlInText > rangeEnd) rangeEnd else nlInText
            val raw = value.substring(start, end)
            val prefix = chromePrefixLength(raw)
            val parsed = parseChromeLine(raw)
            val adornment = adornmentForLine(lineIndex, start, if (nlInText < 0) value.length else nlInText)
            val marker = parsed.marker
            val prefixWidth = prefixVisualWidth(parsed, marker)
            val bodyStart = (start + prefix).coerceAtMost(end)
            val body = raw.drop(prefix.coerceAtMost(raw.length))
            val isBlockLine = body == BLOCK_OBJECT_STRING
            val blocks = if (isBlockLine) adornment?.blocks.orEmpty() else emptyList()
            val heading = isMarkdownHeading(body)
            val collapse = collapsesText(blocks)
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
                        extraHeight = extraHeightFor(adornment, blocks, prefixWidth, collapse),
                        collapseText = collapse,
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
                // Wrapped lines hang at the text start (indent + marker slot),
                // matching iOS — not just the indent column.
                editable.setSpan(
                    EditorHangingIndentSpan(prefixWidth),
                    start,
                    spanEnd,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            if (bodyStart < end) {
                if (isBlockLine) {
                    // Give the object glyph the block's width (so the caret can sit
                    // before/after the block) but draw nothing — the image/table is
                    // painted by `drawBlockStack` in the reserved height. No markdown
                    // styling on a block.
                    editable.setSpan(BlockObjectSpan(blockObjectWidth(blocks, prefixWidth)), bodyStart, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                } else if (heading) {
                    editable.setSpan(EditorTextSizeSpan(24), bodyStart, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                    editable.setSpan(EditorMarkdownSpan(Typeface.BOLD), bodyStart, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                    headingMarkerLength(body)?.let { markerLength ->
                        applyMarkdownMarkerSpan(
                            editable,
                            bodyStart,
                            bodyStart + markerLength.coerceAtMost(body.length)
                        )
                    }
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

    /// Maintains iOS invariant I4: a block's object char is the only thing on its
    /// line (besides indent). When the user types on a block line — or a backspace
    /// merges a text line into it — the extra text is split onto a fresh adjacent
    /// line (before the glyph if it was typed before it, after otherwise) so the
    /// image/table keeps its own line instead of being demoted to plain text.
    /// Fixes one violating line per pass (afterTextChanged fires per edit).
    private fun enforceBlockObjectIsolation(editable: Editable) {
        val value = editable.toString()
        var lineStart = 0
        while (lineStart <= value.length) {
            val nl = value.indexOf('\n', lineStart)
            val lineEnd = if (nl < 0) value.length else nl
            val line = value.substring(lineStart, lineEnd)
            val objRel = line.indexOf(BLOCK_OBJECT_CHAR)
            if (objRel >= 0) {
                val indentLen = lineIndentLength(line).coerceAtMost(line.length)
                val indent = line.substring(0, indentLen)
                // The block line keeps its indent + marker prefix (a table/image can
                // be checked, bulleted, numbered); only text typed before/after the
                // glyph is split off. The split-off text lines carry the indent but
                // not the marker, so the marker stays with the block.
                val prefixLen = minOf(chromePrefixLength(line).coerceAtMost(line.length), objRel)
                val prefix = line.substring(0, prefixLen)
                val alreadyClean = objRel == prefixLen &&
                    line.length == prefixLen + 1
                if (!alreadyClean) {
                    val absObj = lineStart + objRel
                    val pre = line.substring(prefixLen, objRel)
                    val post = line.substring(objRel + 1).replace(BLOCK_OBJECT_STRING, "")
                    val rebuilt = StringBuilder()
                    if (pre.isNotEmpty()) rebuilt.append(indent).append(pre).append('\n')
                    rebuilt.append(prefix).append(BLOCK_OBJECT_CHAR)
                    if (post.isNotEmpty()) rebuilt.append('\n').append(indent).append(post)
                    val typedBeforeGlyph = pendingEditStart in 0..absObj
                    val caret = when {
                        pre.isNotEmpty() && (typedBeforeGlyph || post.isEmpty()) ->
                            lineStart + indent.length + pre.length
                        post.isNotEmpty() -> lineStart + rebuilt.length
                        else -> lineStart + prefix.length + 1
                    }
                    styling = true
                    editable.replace(lineStart, lineEnd, rebuilt.toString())
                    setSelection(caret.coerceIn(0, editable.length))
                    styling = false
                    pendingEditStart = -1
                    pendingEditEnd = -1
                    return
                }
            }
            if (nl < 0) break
            lineStart = nl + 1
        }
    }

    private fun handleEnterContinuation(editable: Editable) {
        val insertStart = pendingEditStart
        val insertEnd = pendingEditEnd
        if (insertStart < 0 || insertEnd - insertStart != 1) return
        if (insertStart >= editable.length) return
        if (editable[insertStart] != '\n') return
        // A "\n" at position 0 has no source line (e.g. setText of an empty
        // document appending its terminal newline) — nothing to continue.
        if (insertStart == 0) return
        val value = editable.toString()
        val lineStart = value.lastIndexOf('\n', insertStart - 1).let { if (it < 0) 0 else it + 1 }
        if (lineStart > insertStart) return
        val lineText = value.substring(lineStart, insertStart)
        val parsed = parseChromeLine(lineText)
        if (parsed.marker == "blank" && parsed.indent == 0) return
        val indentStr = "    ".repeat(parsed.indent.coerceIn(0, 8))
        // iOS parity: return always continues the marker onto the fresh line,
        // even from an empty marker line (no escape-the-list behavior).
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
        // iOS ordinal rule: nested-deeper lines are transparent; a shallower
        // line or a non-numbered line at the same indent ends the run.
        var ordinal = 1
        var cursor = lineStart
        while (cursor > 0) {
            val prevEnd = cursor - 1 // newline char
            if (prevEnd < 0 || value[prevEnd] != '\n') break
            val prevStart = if (prevEnd == 0) 0 else value.lastIndexOf('\n', prevEnd - 1).let { if (it < 0) 0 else it + 1 }
            val prevLine = value.substring(prevStart, prevEnd)
            val prevParsed = parseChromeLine(prevLine)
            when {
                prevParsed.indent > indent -> Unit // transparent
                prevParsed.indent < indent -> return ordinal + 1
                prevParsed.marker != "numbered" -> return ordinal + 1
                else -> ordinal++
            }
            if (prevStart == 0) break
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

    /// iOS `numberedOrdinal`: count consecutive prior numbered siblings at the
    /// same indent; deeper lines are transparent, shallower or non-numbered
    /// same-indent lines end the run.
    private fun numberedOrdinalAt(lines: List<ChromeDrawLine>, index: Int): Int {
        val indent = lines[index].indent
        var ordinal = 1
        var cursor = index - 1
        while (cursor >= 0) {
            val prev = lines[cursor]
            when {
                prev.indent > indent -> Unit
                prev.indent < indent -> return ordinal
                prev.marker != "numbered" -> return ordinal
                else -> ordinal++
            }
            cursor--
        }
        return ordinal
    }

    private fun drawEditorChrome(canvas: Canvas) {
        val layout = layout ?: return
        val value = text?.toString().orEmpty()
        tableCellHits.clear()
        val lines = chromeDrawLines(value)
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
            // A collapsed block line (image/table) shrinks its text row to a
            // sliver, so centering the marker in it would land it on the block's
            // top edge — half of it poking into the line above. Anchor the marker
            // to a full text-row height at the block top so it sits at the
            // table/image's top-left instead.
            val markerBottom = if (line.collapseText) firstTop + dp(EDITOR_TEXT_LINE_HEIGHT_DP) else firstBottom
            val markerRect = markerRect(line.indent, firstTop, markerBottom)
            val previous = lines.getOrNull(index - 1)
            val next = lines.getOrNull(index + 1)

            drawGuides(canvas, markerRect, line.indent, previous?.indent ?: 0, next?.indent ?: 0, firstTop, rowBottom)
            val lineOrdinal = if (line.marker == "numbered") numberedOrdinalAt(lines, index) else 1
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
            // Block-only lines collapse: their text line carries no glyphs, so
            // blocks start at the line top instead of below a blank text row.
            val blockTop = if (line.collapseText) firstTop else
                contentBottom + if (line.annotation == null) 0 else dp(EDITOR_ANNOTATION_HEIGHT_DP)
            drawBlockStack(canvas, line.blocks, line.prefixWidth, blockTop, index)
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
            val adornment = adornmentForLine(lineIndex, start, end)
            // Blocks draw + reserve height only on the object-char line itself, so
            // a stale adornment can never paint a block onto the wrong line.
            val blocks = blocksForBody(body, adornment)
            out.add(
                ChromeDrawLine(
                    start = start,
                    end = end,
                    indent = parsed.indent,
                    marker = marker,
                    done = parsed.done,
                    annotation = adornment?.annotation,
                    blocks = blocks,
                    prefixWidth = prefixWidth,
                    heading = isMarkdownHeading(body),
                    extraHeight = extraHeightFor(adornment, blocks, prefixWidth, collapseText = collapsesText(blocks)),
                    collapseText = collapsesText(blocks)
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
            // 1dp wide like iOS's 1pt guides (1px was nearly invisible).
            canvas.drawRect(x, top + topMargin, x + dp(1f), max(top + topMargin + 1f, guideBottom - bottomMargin), chromePaint)
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
                // iOS: ordinal right-aligned inside the marker slot, vertically
                // centered — same indentation column as the other markers.
                chromePaint.style = Paint.Style.FILL
                chromePaint.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                chromePaint.textSize = dp(12f)
                chromePaint.color = accentColor
                chromePaint.textAlign = Paint.Align.RIGHT
                val baseline = rect.centerY() - (chromePaint.ascent() + chromePaint.descent()) / 2f
                canvas.drawText("$ordinal.", rect.right, baseline, chromePaint)
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
        canvas.drawRect(x, y1, x + dp(1f), max(y1 + 1f, y2), chromePaint)
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

    /// Draws this line's image/table blocks in document order, stacked from
    /// `yStart`. Records table cell + control hit rects for touch handling.
    private fun drawBlockStack(canvas: Canvas, blocks: List<EditorBlock>, prefixWidth: Int, yStart: Int, lineIndex: Int) {
        if (blocks.isEmpty()) return
        val left = totalPaddingLeft + prefixWidth.toFloat()
        val maxWidth = editorImageMaxWidth(prefixWidth)
        var y = yStart.toFloat()
        var drewImage = false
        var tableIndex = 0
        blocks.forEach { block ->
            when (block) {
                is EditorBlock.Image -> {
                    if (block.media.kind != "image") return@forEach
                    val size = mediaDisplaySize(block.media, maxWidth)
                    if (size.first <= 0f || size.second <= 0f) return@forEach
                    y += if (drewImage) dp(EDITOR_IMAGE_STACK_GAP_DP) else dp(EDITOR_IMAGE_TOP_GAP_DP)
                    val rect = RectF(left, y, left + size.first, y + size.second)
                    drawImageMedia(canvas, block.media, rect)
                    y += size.second
                    drewImage = true
                }
                is EditorBlock.Table -> {
                    y += dp(EDITOR_TABLE_TOP_GAP_DP)
                    y = drawTable(canvas, block.table, left, y, maxWidth, lineIndex, tableIndex)
                    tableIndex++
                    drewImage = false
                }
            }
        }
    }

    /// Renders a table grid on the canvas and registers per-cell and +/- control
    /// hit rects. Returns the y just below the table.
    private fun drawTable(canvas: Canvas, table: EditorTable, left: Float, top: Float, maxWidth: Int, lineIndex: Int, tableIndex: Int): Float {
        val columnCount = max(1, max(table.columns.size, table.rows.maxOfOrNull { it.size } ?: 0))
        // Columns split the full block width evenly, matching iOS
        // (`colWidth = rect.width / columnCount`). Row/column add+delete live in
        // the cell editor's Rows/Columns menu, so no gutter is reserved here.
        val colWidth = (maxWidth.toFloat() / columnCount).coerceAtLeast(1f)
        val headerHeight = dp(EDITOR_TABLE_HEADER_HEIGHT_DP).toFloat()
        val rowHeights = tableRowHeights(table, colWidth)
        val gridRight = left + colWidth * columnCount

        // The grid box: a rounded, filled, outlined panel, then clipped so the
        // header tint and inner rules stay inside the corners (mirrors iOS
        // `drawTable`: buttonBg fill, divider border, bgModal header).
        val gridBottom = top + headerHeight + rowHeights.sum()
        val tablePath = Path().apply {
            addRoundRect(RectF(left, top, gridRight, gridBottom), dp(6f), dp(6f), Path.Direction.CW)
        }
        canvas.save()
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.buttonBg
        canvas.drawPath(tablePath, chromePaint)
        chromePaint.style = Paint.Style.STROKE
        chromePaint.strokeWidth = dp(1f)
        chromePaint.color = editorTheme.divider
        canvas.drawPath(tablePath, chromePaint)
        canvas.clipPath(tablePath)

        // Header row.
        var y = top
        val headerRect = RectF(left, y, gridRight, y + headerHeight)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.bgModal
        canvas.drawRect(headerRect, chromePaint)
        val headerTextColor = if (editorTheme.isDark) editorTheme.textSoft else editorTheme.textDim
        for (col in 0 until columnCount) {
            val name = table.columns.getOrNull(col)?.name.orEmpty()
            if (!isActiveTableEdit(lineIndex, tableIndex, row = -1, column = col)) {
                drawTableText(canvas, name, left + col * colWidth, y, colWidth, headerHeight, headerTextColor, bold = true)
            }
            tableCellHits.add(
                TableCellHit(
                    lineIndex = lineIndex,
                    tableIndex = tableIndex,
                    row = -1,
                    column = col,
                    text = name.ifEmpty { "Column ${col + 1}" },
                    rect = RectF(left + col * colWidth, y, left + (col + 1) * colWidth, y + headerHeight)
                )
            )
        }
        y += headerHeight

        // Body rows.
        table.rows.forEachIndexed { rowIndex, row ->
            val rowTop = y
            val rowHeight = rowHeights.getOrNull(rowIndex) ?: dp(EDITOR_TABLE_ROW_HEIGHT_DP).toFloat()
            for (col in 0 until columnCount) {
                val cellLeft = left + col * colWidth
                val cellRect = RectF(cellLeft, rowTop, cellLeft + colWidth, rowTop + rowHeight)
                val cell = row.getOrNull(col)
                if (!isActiveTableEdit(lineIndex, tableIndex, row = rowIndex, column = col)) {
                    drawTableText(canvas, cell?.display.orEmpty(), cellLeft, rowTop, colWidth, rowHeight, editorTheme.textPrimary, bold = false)
                }
                tableCellHits.add(
                    TableCellHit(
                        lineIndex = lineIndex,
                        tableIndex = tableIndex,
                        row = rowIndex,
                        column = col,
                        text = cell?.display.orEmpty(),
                        rect = RectF(cellRect)
                    )
                )
                // Row delete control sits in the left header column on hover-less
                // mobile we surface it as a tiny "-" at the row's right edge end.
            }
            y += rowHeight
        }

        // Inner grid rules (the outer edges are the rounded border above).
        chromePaint.style = Paint.Style.STROKE
        chromePaint.strokeWidth = dp(1f)
        chromePaint.color = editorTheme.divider
        for (col in 1 until columnCount) {
            val x = left + col * colWidth
            canvas.drawLine(x, top, x, gridBottom, chromePaint)
        }
        var lineY = top + headerHeight
        canvas.drawLine(left, lineY, gridRight, lineY, chromePaint)
        rowHeights.forEach { rowHeight ->
            lineY += rowHeight
            canvas.drawLine(left, lineY, gridRight, lineY, chromePaint)
        }

        canvas.restore()
        chromePaint.style = Paint.Style.FILL
        return gridBottom
    }

    private fun isActiveTableEdit(lineIndex: Int, tableIndex: Int, row: Int, column: Int): Boolean =
        activeTableCellEdit?.let {
            it.lineIndex == lineIndex && it.tableIndex == tableIndex && it.row == row && it.column == column
        } == true

    private fun drawTableText(canvas: Canvas, value: String, left: Float, top: Float, cellWidth: Float, cellHeight: Float, color: Int, bold: Boolean) {
        if (value.isEmpty()) return
        val pad = dp(EDITOR_TABLE_CELL_PAD_DP).toFloat()
        val paint = tableTextPaint(color, bold)
        val content = tableTextMarkdownSpannable(value, bold)
        val layout = tableTextLayout(content, paint, (cellWidth - pad * 2).roundToInt().coerceAtLeast(1))
        canvas.save()
        canvas.clipRect(left, top, left + cellWidth, top + cellHeight)
        canvas.translate(left + pad, top + pad)
        layout.draw(canvas)
        canvas.restore()
    }

    /// A block line carries one object char whose text row is reclaimed so the
    /// block renders in place instead of below a blank row.
    private fun collapsesText(blocks: List<EditorBlock>): Boolean = blocks.isNotEmpty()

    /// The blocks a line draws: non-empty only when the line's body is exactly
    /// the object char, binding block rendering to the sentinel character.
    private fun blocksForBody(body: String, adornment: EditorLineAdornment?): List<EditorBlock> =
        if (body == BLOCK_OBJECT_STRING) adornment?.blocks.orEmpty() else emptyList()

    /// The on-screen width of a block line's content, used to size the object
    /// char so the caret-before sits at the block's left edge and caret-after at
    /// its right edge (matches the block's own drawn width in `drawBlockStack`).
    private fun blockObjectWidth(blocks: List<EditorBlock>, prefixWidth: Int): Int {
        val maxWidth = editorImageMaxWidth(prefixWidth)
        return when (val block = blocks.firstOrNull()) {
            is EditorBlock.Image ->
                if (block.media.kind != "image") maxWidth
                else mediaDisplaySize(block.media, maxWidth).first.roundToInt().coerceIn(1, maxWidth)
            is EditorBlock.Table -> maxWidth
            else -> maxWidth
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

    private fun extraHeightFor(adornment: EditorLineAdornment?, blocks: List<EditorBlock>, prefixWidth: Int, collapseText: Boolean): Int {
        var extra = if (adornment?.annotation == null) 0 else dp(EDITOR_ANNOTATION_HEIGHT_DP)
        extra += blockStackHeight(blocks, editorImageMaxWidth(prefixWidth))
        // A collapsed line reclaims its own text-row height (added by the chrome
        // span shrink) so the total reserved space still fits the blocks.
        if (collapseText) extra += dp(EDITOR_COLLAPSE_TEXT_HEIGHT_DP)
        return extra
    }

    private fun blockStackHeight(blocks: List<EditorBlock>, maxWidth: Int): Int {
        var height = 0
        var drewImage = false
        blocks.forEach { block ->
            when (block) {
                is EditorBlock.Image -> {
                    if (block.media.kind != "image") return@forEach
                    val size = mediaDisplaySize(block.media, maxWidth)
                    if (size.second <= 0f) return@forEach
                    height += if (drewImage) dp(EDITOR_IMAGE_STACK_GAP_DP) else dp(EDITOR_IMAGE_TOP_GAP_DP)
                    height += size.second.roundToInt()
                    drewImage = true
                }
                is EditorBlock.Table -> {
                    height += dp(EDITOR_TABLE_TOP_GAP_DP)
                    height += tableHeight(block.table, maxWidth)
                    drewImage = false
                }
            }
        }
        return height
    }

    private fun tableHeight(table: EditorTable, maxWidth: Int): Int {
        val columnCount = max(1, max(table.columns.size, table.rows.maxOfOrNull { it.size } ?: 0))
        val colWidth = (maxWidth.toFloat() / columnCount).coerceAtLeast(1f)
        return dp(EDITOR_TABLE_HEADER_HEIGHT_DP) + tableRowHeights(table, colWidth).sumOf { it.roundToInt() }
    }

    private fun tableRowHeights(table: EditorTable, columnWidth: Float): List<Float> {
        val minHeight = dp(EDITOR_TABLE_ROW_HEIGHT_DP).toFloat()
        val pad = dp(EDITOR_TABLE_CELL_PAD_DP).toFloat()
        val textWidth = (columnWidth - pad * 2).roundToInt().coerceAtLeast(1)
        val paint = tableTextPaint(editorTheme.textPrimary, bold = false)
        return table.rows.map { row ->
            var height = minHeight
            row.forEach { cell ->
                // Use raw display text for height calculation (called from the
                // applyPrefixSpans path which runs on every keystroke); markdown
                // delimiters are short and don't meaningfully affect line wrapping.
                val layout = tableTextLayout(cell.display, paint, textWidth)
                height = max(height, layout.height + pad * 2)
            }
            height
        }
    }

    private fun tableTextPaint(color: Int, bold: Boolean): TextPaint =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            textSize = dp(13f)
            typeface = if (bold) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.DEFAULT
        }

    private fun tableTextLayout(content: CharSequence, paint: TextPaint, width: Int): StaticLayout =
        StaticLayout.Builder.obtain(content, 0, content.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(0f, 1f)
            .setIncludePad(false)
            .build()

    // Renders `value` with inline markdown (bold, italic, highlight, strike)
    // stripped of delimiter tokens — matching iOS cell rendering. Headers
    // (bold=true) are returned as plain text; body cells get styled spans.
    private fun tableTextMarkdownSpannable(value: String, bold: Boolean): CharSequence {
        if (bold || value.isEmpty()) return value
        if (value.none { it == '*' || it == '_' || it == '=' || it == '~' }) return value
        val ssb = SpannableStringBuilder()
        var lineStart = 0
        while (lineStart <= value.length) {
            if (lineStart == value.length) break
            val lineEnd = value.indexOf('\n', lineStart).let { if (it < 0) value.length else it }
            if (lineStart > 0) ssb.append('\n')
            appendCellMarkdownSegment(ssb, value, lineStart, lineEnd, InlineMarkdownStyle())
            if (lineEnd >= value.length) break
            lineStart = lineEnd + 1
        }
        return ssb
    }

    private fun appendCellMarkdownSegment(ssb: SpannableStringBuilder, src: String, srcStart: Int, srcEnd: Int, style: InlineMarkdownStyle) {
        val body = src.substring(srcStart, srcEnd)
        val limit = body.length
        var index = 0
        var plainStart = 0
        while (index < limit) {
            val delimiter = openMarkdownDelimiter(body, index, limit)
            if (delimiter != null) {
                val tokenLen = delimiter.token.length
                val innerStart = index + tokenLen
                val close = findMarkdownClose(body, delimiter.token, innerStart, limit)
                if (close >= 0) {
                    if (index > plainStart) appendCellStyledText(ssb, body.substring(plainStart, index), style)
                    appendCellMarkdownSegment(ssb, src, srcStart + innerStart, srcStart + close, style.with(delimiter.emphasis))
                    index = close + tokenLen
                    plainStart = index
                    continue
                }
            }
            index++
        }
        if (limit > plainStart) appendCellStyledText(ssb, body.substring(plainStart, limit), style)
    }

    private fun appendCellStyledText(ssb: SpannableStringBuilder, text: String, style: InlineMarkdownStyle) {
        if (text.isEmpty()) return
        val s = ssb.length
        ssb.append(text)
        val e = ssb.length
        val typeface = when {
            style.bold && style.italic -> Typeface.BOLD_ITALIC
            style.bold -> Typeface.BOLD
            style.italic -> Typeface.ITALIC
            else -> null
        }
        if (typeface != null) ssb.setSpan(StyleSpan(typeface), s, e, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (style.highlight) ssb.setSpan(BackgroundColorSpan(EDITOR_HIGHLIGHT_COLOR), s, e, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (style.strike) ssb.setSpan(StrikethroughSpan(), s, e, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
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
        parseInlineMarkdown(
            editable = editable,
            body = body,
            start = 0,
            end = body.length,
            bodyStart = bodyStart,
            bodyEnd = bodyEnd,
            style = InlineMarkdownStyle()
        )
    }

    private fun parseInlineMarkdown(
        editable: Editable,
        body: String,
        start: Int,
        end: Int,
        bodyStart: Int,
        bodyEnd: Int,
        style: InlineMarkdownStyle
    ) {
        var index = start
        var plainStart = index

        fun flushPlain(upTo: Int) {
            if (upTo <= plainStart) return
            applyInlineMarkdownStyle(
                editable = editable,
                start = (bodyStart + plainStart).coerceAtMost(bodyEnd),
                end = (bodyStart + upTo).coerceAtMost(bodyEnd),
                style = style
            )
        }

        while (index < end) {
            val delimiter = openMarkdownDelimiter(body, index, end)
            if (delimiter != null) {
                val innerStart = index + delimiter.token.length
                val close = findMarkdownClose(body, delimiter.token, innerStart, end)
                if (close >= 0) {
                    flushPlain(index)
                    applyMarkdownMarkerSpan(editable, bodyStart + index, bodyStart + innerStart)
                    applyMarkdownMarkerSpan(editable, bodyStart + close, bodyStart + close + delimiter.token.length)
                    if (close > innerStart) {
                        parseInlineMarkdown(
                            editable = editable,
                            body = body,
                            start = innerStart,
                            end = close,
                            bodyStart = bodyStart,
                            bodyEnd = bodyEnd,
                            style = style.with(delimiter.emphasis)
                        )
                    }
                    index = close + delimiter.token.length
                    plainStart = index
                    continue
                }
            }
            index++
        }
        flushPlain(end)
    }

    private fun applyInlineMarkdownStyle(editable: Editable, start: Int, end: Int, style: InlineMarkdownStyle) {
        if (end <= start) return
        val typeface = when {
            style.bold && style.italic -> Typeface.BOLD_ITALIC
            style.bold -> Typeface.BOLD
            style.italic -> Typeface.ITALIC
            else -> null
        }
        if (typeface != null) {
            editable.setSpan(EditorMarkdownSpan(typeface), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (style.highlight) {
            editable.setSpan(EditorMarkdownHighlightSpan(), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (style.strike) {
            editable.setSpan(EditorMarkdownStrikeSpan(), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    private fun applyMarkdownMarkerSpan(editable: Editable, start: Int, end: Int) {
        val safeStart = start.coerceIn(0, editable.length)
        val safeEnd = end.coerceIn(safeStart, editable.length)
        if (safeEnd <= safeStart || markdownRangeIsRevealed(safeStart, safeEnd)) return
        editable.setSpan(EditorMarkdownMarkerSpan(), safeStart, safeEnd, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun markdownRangeIsRevealed(start: Int, end: Int): Boolean =
        revealedMarkdownStart >= 0 && start < revealedMarkdownEnd && end > revealedMarkdownStart

    private fun updateRevealedMarkdownRange(value: String): Boolean {
        if (!hasFocus() || value.isEmpty()) {
            val changed = revealedMarkdownStart != -1 || revealedMarkdownEnd != -1
            revealedMarkdownStart = -1
            revealedMarkdownEnd = -1
            return changed
        }
        val currentSelectionStart = this.selectionStart.coerceIn(0, value.length)
        val currentSelectionEnd = this.selectionEnd.coerceIn(0, value.length)
        val lower = min(currentSelectionStart, currentSelectionEnd)
        val upper = max(currentSelectionStart, currentSelectionEnd)
        val startLine = if (lower == 0) 0 else value.lastIndexOf('\n', lower - 1).let { if (it < 0) 0 else it + 1 }
        val endLine = value.indexOf('\n', upper.coerceAtMost(value.length)).let { if (it < 0) value.length else it }
        val changed = startLine != revealedMarkdownStart || endLine != revealedMarkdownEnd
        revealedMarkdownStart = startLine
        revealedMarkdownEnd = endLine
        return changed
    }

    private fun openMarkdownDelimiter(body: String, index: Int, limit: Int): MarkdownDelimiter? {
        for (candidate in markdownDelimiters) {
            if (matchesMarkdownToken(body, candidate.token, index, limit)) return candidate
        }
        return null
    }

    private fun matchesMarkdownToken(body: String, token: String, index: Int, limit: Int): Boolean =
        index + token.length <= limit && body.regionMatches(index, token, 0, token.length)

    private fun findMarkdownClose(body: String, token: String, start: Int, limit: Int): Int {
        val close = body.indexOf(token, startIndex = start)
        return if (close >= 0 && close + token.length <= limit) close else -1
    }

    private fun headingMarkerLength(body: String): Int? {
        var index = 0
        while (index < body.length && body[index].isWhitespace()) index++
        val hashStart = index
        while (index < body.length && body[index] == '#') index++
        if (index == hashStart) return null
        if (index < body.length && body[index].isWhitespace()) index++
        return index
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
    private fun dp(value: Float): Float = value * resources.displayMetrics.density
}


internal data class UiTheme(
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
            bgApp = rgb(0x000000),
            bgSidebar = rgb(0x000000),
            bgToolbar = rgb(0x151517),
            bgModal = rgb(0x0e0e10),
            rowAlt = rgba(0xffffff, 11),
            rowSelected = rgba(0xffffff, 36),
            buttonBg = rgba(0xffffff, 24),
            divider = rgba(0xffffff, 33),
            dividerSoft = rgba(0xffffff, 20),
            dividerTiny = rgba(0xffffff, 13),
            borderOverlay = rgba(0xffffff, 41),
            textPrimary = rgb(0xf2f2f7),
            textDim = rgba(0xb4bcc4, 189),
            textMuted = rgba(0x98a0aa, 140),
            textSoft = rgba(0xd2dae2, 163),
            textToday = rgb(0xff453a),
            accent = rgb(0x7aa0ff),
            danger = rgb(0xff453a),
        )

        // Clean, near-white light theme matching knotq.com: an off-white canvas,
        // soft gray-green surfaces, near-black ink, and a rose accent. Translucent
        // rows/dividers tint with a slate-green so they read as the site's --line
        // colors over the light canvas.
        val light = UiTheme(
            isDark = false,
            bgApp = rgb(0xfafbf9),
            bgSidebar = rgb(0xf2f5f2),
            bgToolbar = rgb(0xf2f5f2),
            bgModal = rgb(0xffffff),
            rowAlt = rgba(0x3a443d, 10),
            rowSelected = rgba(0xc7375d, 31),
            buttonBg = rgba(0x3a443d, 20),
            divider = rgba(0x3a443d, 41),
            dividerSoft = rgba(0x3a443d, 28),
            dividerTiny = rgba(0x3a443d, 13),
            borderOverlay = rgba(0x3a443d, 51),
            textPrimary = rgb(0x171717),
            textDim = rgba(0x393f39, 230),
            textMuted = rgba(0x6d746d, 204),
            textSoft = rgba(0x393f39, 217),
            textToday = rgb(0xc7375d),
            accent = rgb(0xc7375d),
            danger = rgb(0xb84433),
        )
    }
}
