package com.enigmadux.knotq

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Editable
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
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.widget.EditText
import android.widget.LinearLayout
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal const val EDITOR_TEXT_LEFT_PAD_DP = 35
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
    var selectionChangedHandler: (() -> Unit)? = null

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        selectionChangedHandler?.invoke()
    }

    private var styling = false
    private var pendingEditStart = -1
    private var pendingEditEnd = -1
    private var deletionBrokePrefix = false

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
            val parsed = parseChromeLine(value.substring(lineStart, lineEnd))
            if (parsed.marker != "checkbox") continue
            val prefixWidth = prefixVisualWidth(parsed, parsed.marker)
            val extraHeight = extraHeightFor(lineAdornments.getOrNull(logicalLine), prefixWidth)
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
            val markerRect = markerRect(line.indent, firstTop, firstBottom)
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

internal data class EditorLineAdornment(
    val marker: String,
    val done: Boolean,
    val annotation: String?,
    val media: List<EditorLineMedia>,
)

internal data class EditorLineMedia(
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

internal data class ChromeLine(
    val marker: String,
    val indent: Int,
    val done: Boolean,
)

internal fun parseChromeLine(raw: String): ChromeLine {
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

internal fun chromePrefixLength(raw: String): Int {
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
// Marker tokens that lost their trailing space (or more) to a deletion.
private val brokenCheckboxPrefix = Regex("^\\[[xX ]?\\]?")
private val brokenNumberedPrefix = Regex("^\\d+\\.")

internal fun rgbColor(hex: Int): Int =
    Color.rgb((hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

internal fun rgbaColor(hex: Int, alpha: Int): Int =
    Color.argb(alpha, (hex shr 16) and 0xff, (hex shr 8) and 0xff, hex and 0xff)

internal fun adjustAlpha(color: Int, alpha: Float): Int =
    Color.argb((255 * alpha).roundToInt(), Color.red(color), Color.green(color), Color.blue(color))

internal data class SchemeEditorLine(
    val id: String?,
    val text: String,
    val marker: String,
    val indent: Int,
    val done: Boolean,
) {
    val rawKey: String = "$marker|$indent|$done|$text"
}

internal fun documentLines(scheme: JSONObject): List<SchemeEditorLine> {
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

internal fun editorLineAdornments(scheme: JSONObject, timeFormat24: Boolean): List<EditorLineAdornment> {
    val items = scheme.optJSONArray("items") ?: return emptyList()
    val out = ArrayList<EditorLineAdornment>(items.length())
    for (index in 0 until items.length()) {
        val item = items.optJSONObject(index) ?: continue
        val start = item.optString("start").takeIf { it.isNotEmpty() && it != "null" }
        val end = item.optString("end").takeIf { it.isNotEmpty() && it != "null" }
        val annotation = MobileDateFormatting.annotationLabel(start, end, timeFormat24)
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

internal fun parseEditorDocument(text: String, preserveBlankDocument: Boolean): List<SchemeEditorLine> {
    val body = if (text.endsWith("\n")) text.dropLast(1) else text
    if (body.isEmpty()) {
        return if (preserveBlankDocument) listOf(parseEditorLine("")) else emptyList()
    }
    return body.split("\n", ignoreCase = false, limit = 0).map(::parseEditorLine)
}

internal fun parseEditorLine(raw: String): SchemeEditorLine {
    val parsed = parseChromeLine(raw)
    val text = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
    return SchemeEditorLine(id = null, text = text, marker = parsed.marker, indent = parsed.indent, done = parsed.done)
}

internal fun renderDocument(lines: List<SchemeEditorLine>): String {
    val body = lines.mapIndexed { index, line ->
        renderEditorLine(line, documentNumberedOrdinal(lines, index))
    }.joinToString("\n")
    return "$body\n"
}

/// iOS ordinal rule: count consecutive prior numbered siblings at the same
/// indent; deeper lines are transparent, anything else ends the run.
private fun documentNumberedOrdinal(lines: List<SchemeEditorLine>, index: Int): Int {
    if (lines[index].marker != "numbered") return 1
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

internal fun renderEditorLine(line: SchemeEditorLine, ordinal: Int): String {
    val indent = "    ".repeat(line.indent.coerceIn(0, 8))
    val prefix = when (line.marker) {
        "checkbox" -> if (line.done) "[x] " else "[ ] "
        "bullet" -> "- "
        "numbered" -> "$ordinal. "
        else -> ""
    }
    return "$indent$prefix${line.text}"
}

internal fun reconcileEditorLines(old: List<SchemeEditorLine>, parsed: List<SchemeEditorLine>): List<SchemeEditorLine> {
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
            textDim = rgba(0x302520, 224),
            textMuted = rgba(0x5a4a3c, 192),
            textSoft = rgba(0x382c22, 190),
            textToday = rgb(0xd04e1a),
            accent = rgb(0xc04510),
            danger = rgb(0xc72f24),
        )
    }
}
