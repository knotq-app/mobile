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

    internal fun SchemeEditText.applyMarkdownSpans(editable: Editable, body: String, bodyStart: Int, bodyEnd: Int) {
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

    internal fun SchemeEditText.parseInlineMarkdown(
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

    internal fun SchemeEditText.applyInlineMarkdownStyle(editable: Editable, start: Int, end: Int, style: InlineMarkdownStyle) {
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

    internal fun SchemeEditText.applyMarkdownMarkerSpan(editable: Editable, start: Int, end: Int) {
        val safeStart = start.coerceIn(0, editable.length)
        val safeEnd = end.coerceIn(safeStart, editable.length)
        if (safeEnd <= safeStart || markdownRangeIsRevealed(safeStart, safeEnd)) return
        editable.setSpan(EditorMarkdownMarkerSpan(), safeStart, safeEnd, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    internal fun SchemeEditText.markdownRangeIsRevealed(start: Int, end: Int): Boolean =
        revealedMarkdownStart >= 0 && start < revealedMarkdownEnd && end > revealedMarkdownStart

    internal fun SchemeEditText.updateRevealedMarkdownRange(value: String): Boolean {
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

    internal fun SchemeEditText.openMarkdownDelimiter(body: String, index: Int, limit: Int): MarkdownDelimiter? {
        for (candidate in markdownDelimiters) {
            if (matchesMarkdownToken(body, candidate.token, index, limit)) return candidate
        }
        return null
    }

    internal fun SchemeEditText.matchesMarkdownToken(body: String, token: String, index: Int, limit: Int): Boolean =
        index + token.length <= limit && body.regionMatches(index, token, 0, token.length)

    internal fun SchemeEditText.findMarkdownClose(body: String, token: String, start: Int, limit: Int): Int {
        val close = body.indexOf(token, startIndex = start)
        return if (close >= 0 && close + token.length <= limit) close else -1
    }

    internal fun SchemeEditText.headingMarkerLength(body: String): Int? {
        var index = 0
        while (index < body.length && body[index].isWhitespace()) index++
        val hashStart = index
        while (index < body.length && body[index] == '#') index++
        if (index == hashStart) return null
        if (index < body.length && body[index].isWhitespace()) index++
        return index
    }
