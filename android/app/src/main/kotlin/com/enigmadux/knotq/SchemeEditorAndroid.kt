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

internal class SchemeEditText(context: android.content.Context) : EditText(context) {
    internal val chromePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    internal val imageCache = HashMap<String, Bitmap?>()

    var editorTheme: UiTheme = UiTheme.dark
        set(value) {
            field = value
            applyCursorDrawable()
            editableText?.let { applyPrefixSpans(it, fullDocument = true) }
            invalidate()
        }

    internal var caretDrawable: FixedHeightCursorDrawable? = null

    /// Lines reserve extra height below the text for blocks/annotations, which
    /// the stock caret would stretch across. The caret height is set per line in
    /// `updateCaretHeight` to mirror iOS `caretRect`: text/heading lines clamp to
    /// their line height; a block line lets the caret span the whole block.
    internal fun applyCursorDrawable() {
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
    internal fun updateCaretHeight() {
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
    internal var chromeAdornments: List<EditorLineAdornment>? = emptyList()
    // True once AdornmentSpans have been attached to the live buffer. While true,
    // spans are the sole source of truth; the index-based list is only consulted
    // before spans exist (initial draw, or when set with no editable buffer).
    internal var hasAdornmentSpans = false
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
    internal fun adornmentForLine(lineIndex: Int, lineStart: Int, nlOffset: Int): EditorLineAdornment? {
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
    // Fired after a real user text edit (not the editor's own re-styling, and not
    // mid-IME-composition). The host uses it to debounce a live flush of the
    // document into the core (push-on-type, like desktop) instead of only on blur.
    var onUserEdit: (() -> Unit)? = null
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
    internal val tableCellHits = ArrayList<TableCellHit>()

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
    internal fun bodyStartFor(pos: Int): Int {
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

    internal var styling = false
    internal var pendingEditStart = -1
    internal var pendingEditEnd = -1
    internal var deletionBrokePrefix = false
    internal var revealedMarkdownStart = -1
    internal var revealedMarkdownEnd = -1
    // Guards the re-entrant setSelection used to snap the caret out of a prefix.
    internal var clampingCaret = false

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
                // Schedule a live flush on ANY real edit — including mid-IME
                // composition (the soft keyboard holds a composing span while typing
                // a word, so gating this on `composing < 0` like the styling block
                // above would delay the push until the word/blur committed). The
                // debounce coalesces; the commit reads the currently visible text.
                if (!styling && s != null) {
                    onUserEdit?.invoke()
                }
                invalidate()
            }
        })
    }

    internal fun deletionDamagesPrefix(value: String, start: Int, count: Int): Boolean {
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
    internal fun repairBrokenPrefix(editable: Editable) {
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

    internal fun lineIndentLength(line: String): Int {
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

    internal fun brokenPrefixRemnantLength(rest: String): Int? {
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
    internal fun drawMarkdownHighlights(canvas: Canvas) {
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

    internal fun markerLineAt(x: Float, y: Float): Int? {
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

    internal fun applyPrefixSpans(editable: Editable, fullDocument: Boolean) {
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
    internal fun enforceBlockObjectIsolation(editable: Editable) {
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

    internal fun handleEnterContinuation(editable: Editable) {
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

    internal fun nextNumberedOrdinal(value: String, lineStart: Int, indent: Int): Int {
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

    internal fun enforceTerminalNewline(editable: Editable) {
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
    internal fun numberedOrdinalAt(lines: List<ChromeDrawLine>, index: Int): Int {
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

    internal fun drawEditorChrome(canvas: Canvas) {
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
            val textBaseline = (totalPaddingTop + layout.getLineBaseline(firstVisual) - scrollY).toFloat()
            drawMarker(canvas, markerRect, line.marker, line.done, lineOrdinal, textBaseline)
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

    internal fun chromeDrawLines(value: String): List<ChromeDrawLine> {
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

    internal fun drawGuides(canvas: Canvas, markerRect: RectF, indent: Int, previousIndent: Int, nextIndent: Int, top: Int, bottom: Int) {
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

    internal fun drawMarker(
        canvas: Canvas,
        rect: RectF,
        marker: String,
        done: Boolean,
        ordinal: Int,
        textBaseline: Float
    ) {
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
                // iOS/desktop: ordinal is right-aligned in the marker slot, but
                // shares the row's text baseline instead of being centered in the
                // smaller checkbox-sized rect.
                chromePaint.style = Paint.Style.FILL
                chromePaint.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                chromePaint.textSize = dp(12f)
                chromePaint.color = accentColor
                chromePaint.textAlign = Paint.Align.RIGHT
                canvas.drawText("$ordinal.", rect.right, textBaseline, chromePaint)
                chromePaint.textAlign = Paint.Align.LEFT
                chromePaint.typeface = Typeface.DEFAULT
            }
        }
    }

    internal fun drawAnnotationBar(canvas: Canvas, markerRect: RectF, top: Int, bottom: Int, connectsToPrevious: Boolean, connectsToNext: Boolean) {
        val x = annotationGuideX(markerRect)
        val y1 = if (connectsToPrevious) top.toFloat() else markerRect.top
        val y2 = bottom.toFloat() - if (connectsToNext) 0f else dp(3f)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = accentColor
        canvas.drawRect(x, y1, x + dp(1f), max(y1 + 1f, y2), chromePaint)
    }

    internal fun drawAnnotation(canvas: Canvas, value: String, markerRect: RectF, contentBottom: Int) {
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

    internal fun adjustColor(color: Int, alpha: Float): Int = adjustAlpha(color, alpha)

    internal fun <T> removeSpansInRange(editable: Editable, start: Int, end: Int, kind: Class<T>) {
        editable.getSpans(start, end, kind).forEach { span ->
            val s = editable.getSpanStart(span)
            val e = editable.getSpanEnd(span)
            if (s >= start && e <= end + 1) {
                editable.removeSpan(span)
            }
        }
    }

    internal fun markerRect(indent: Int, top: Int, bottom: Int): RectF {
        val size = dp(EDITOR_CHECKBOX_SIZE_DP).toFloat()
        val left = totalPaddingLeft + indent.coerceIn(0, 8) * dp(EDITOR_INDENT_WIDTH_DP)
        val centerY = (top + bottom) / 2f
        return RectF(left.toFloat(), centerY - size / 2f, left + size, centerY + size / 2f)
    }

    internal fun prefixVisualWidth(parsed: ChromeLine, marker: String): Int {
        val markerSlot = if (marker == "blank") 0 else dp(EDITOR_MARKER_SLOT_DP)
        return parsed.indent.coerceIn(0, 8) * dp(EDITOR_INDENT_WIDTH_DP) + markerSlot
    }


    internal fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
    internal fun dp(value: Float): Float = value * resources.displayMetrics.density
}
