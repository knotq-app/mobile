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

    /// Styles a text line's body: a `---` rule (all marker — the line itself is
    /// painted by `drawBlockMarkup`), a `> quote` (marker hidden, text softened),
    /// or ordinary inline markup.
    internal fun SchemeEditText.applyMarkdownSpans(editable: Editable, body: String, bodyStart: Int, bodyEnd: Int) {
        if (isMarkdownRule(body)) {
            applyMarkdownMarkerSpan(editable, bodyStart, bodyEnd)
            return
        }
        val quoteMarker = markdownQuoteMarkerLength(body)?.coerceAtMost(body.length) ?: 0
        if (quoteMarker > 0) {
            applyMarkdownMarkerSpan(editable, bodyStart, bodyStart + quoteMarker)
            val quoteStart = (bodyStart + quoteMarker).coerceAtMost(bodyEnd)
            if (bodyEnd > quoteStart) {
                editable.setSpan(EditorMarkdownQuoteSpan(editorTheme.textSoft), quoteStart, bodyEnd, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        for (run in inlineMarkdownRuns(body, start = quoteMarker)) {
            val start = (bodyStart + run.start).coerceAtMost(bodyEnd)
            val end = (bodyStart + run.end).coerceAtMost(bodyEnd)
            if (run.marker) {
                applyMarkdownMarkerSpan(editable, start, end)
            } else {
                applyInlineMarkdownStyle(editable, start, end, run.style)
            }
        }
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
        if (style.code) {
            editable.setSpan(EditorMarkdownCodeSpan(), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            // A highlight inside code wins: it is the more deliberate mark.
            if (!style.highlight) {
                editable.setSpan(EditorMarkdownHighlightSpan(editorTheme.dividerSoft), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        } else if (style.link) {
            editable.setSpan(EditorMarkdownLinkSpan(editorTheme.accent), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
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

    internal fun SchemeEditText.headingMarkerLength(body: String): Int? {
        var index = 0
        while (index < body.length && body[index].isWhitespace()) index++
        val hashStart = index
        while (index < body.length && body[index] == '#') index++
        if (index == hashStart) return null
        if (index < body.length && body[index].isWhitespace()) index++
        return index
    }
