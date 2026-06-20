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

// Span classes + inline-markdown styling used by SchemeEditText's rendering.

// Attached to the trailing '\n' of each model item's line so the adornment
// (blocks, annotation, marker) follows the line through live text edits instead
// of staying at its original index in the snapshot list.
internal class AdornmentSpan(val adornment: EditorLineAdornment)

internal class EditorChromeSpan(
    private val lineTextEnd: Int,
    private val heading: Boolean,
    private val extraHeight: Int,
    private val collapseText: Boolean,
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
        // Collapse the (empty) text row of a block-only line so the block draws
        // in place. The shrink is bounded so we never produce a negative line.
        if (collapseText) {
            val shrink = min(dp(EDITOR_COLLAPSE_TEXT_HEIGHT_DP.toFloat()).roundToInt(), max(0, (fm.descent - fm.ascent) - dp(2f).roundToInt()))
            fm.descent -= shrink
            fm.bottom -= shrink
        }
    }

    private fun dp(value: Float): Float = value * density
}

// Renders the block line's object char (BLOCK_OBJECT_CHAR) invisibly while giving
// it the block's *width*, so the caret can sit BEFORE it (left edge of the block)
// and AFTER it (right edge) — the cursor notion desktop/iOS give blocks. It draws
// no glyph (the image/table is painted by `drawBlockStack` in the height reserved
// by EditorChromeSpan). The iOS analog is `KnotQBlockAttachment`.
internal class BlockObjectSpan(private val width: Int) : ReplacementSpan() {
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

internal class HiddenPrefixSpan(private val width: Int) : ReplacementSpan() {
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

internal class EditorHangingIndentSpan(private val width: Int) : LeadingMarginSpan.LeadingMarginSpan2 {
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

internal class DoneTextSpan : StrikethroughSpan()

internal class DoneTextColorSpan(color: Int) : ForegroundColorSpan(color)

internal class EditorMarkdownSpan(style: Int) : StyleSpan(style)

// A tag-only span: the gold fill is painted by `drawMarkdownHighlights` so it
// can be clipped to the text run (a real BackgroundColorSpan fills the whole
// line box, bleeding into reserved block/annotation height).
internal class EditorMarkdownHighlightSpan

internal val EDITOR_HIGHLIGHT_COLOR = rgbaColor(0xffd000, 102)

internal class EditorMarkdownStrikeSpan : StrikethroughSpan()

internal class EditorMarkdownMarkerSpan : ReplacementSpan() {
    override fun getSize(
        paint: Paint,
        text: CharSequence?,
        start: Int,
        end: Int,
        fm: Paint.FontMetricsInt?
    ): Int = 0

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

internal class EditorTextSizeSpan(sizeSp: Int) : AbsoluteSizeSpan(sizeSp, true)

internal data class InlineMarkdownStyle(
    val bold: Boolean = false,
    val italic: Boolean = false,
    val highlight: Boolean = false,
    val strike: Boolean = false,
) {
    fun with(emphasis: InlineMarkdownEmphasis): InlineMarkdownStyle =
        when (emphasis) {
            InlineMarkdownEmphasis.BOLD -> copy(bold = true)
            InlineMarkdownEmphasis.ITALIC -> copy(italic = true)
            InlineMarkdownEmphasis.HIGHLIGHT -> copy(highlight = true)
            InlineMarkdownEmphasis.STRIKE -> copy(strike = true)
        }
}

internal enum class InlineMarkdownEmphasis {
    BOLD,
    ITALIC,
    HIGHLIGHT,
    STRIKE,
}

internal data class MarkdownDelimiter(val token: String, val emphasis: InlineMarkdownEmphasis)

internal val markdownDelimiters = listOf(
    MarkdownDelimiter("**", InlineMarkdownEmphasis.BOLD),
    MarkdownDelimiter("__", InlineMarkdownEmphasis.BOLD),
    MarkdownDelimiter("==", InlineMarkdownEmphasis.HIGHLIGHT),
    MarkdownDelimiter("~~", InlineMarkdownEmphasis.STRIKE),
    MarkdownDelimiter("*", InlineMarkdownEmphasis.ITALIC),
    MarkdownDelimiter("_", InlineMarkdownEmphasis.ITALIC),
)
