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

    /// Draws this line's image/table blocks in document order, stacked from
    /// `yStart`. Records table cell + control hit rects for touch handling.
    internal fun SchemeEditText.drawBlockStack(canvas: Canvas, blocks: List<EditorBlock>, prefixWidth: Int, yStart: Int, lineIndex: Int) {
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
    internal fun SchemeEditText.drawTable(canvas: Canvas, table: EditorTable, left: Float, top: Float, maxWidth: Int, lineIndex: Int, tableIndex: Int): Float {
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

    internal fun SchemeEditText.isActiveTableEdit(lineIndex: Int, tableIndex: Int, row: Int, column: Int): Boolean =
        activeTableCellEdit?.let {
            it.lineIndex == lineIndex && it.tableIndex == tableIndex && it.row == row && it.column == column
        } == true

    internal fun SchemeEditText.drawTableText(canvas: Canvas, value: String, left: Float, top: Float, cellWidth: Float, cellHeight: Float, color: Int, bold: Boolean) {
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
    internal fun SchemeEditText.collapsesText(blocks: List<EditorBlock>): Boolean = blocks.isNotEmpty()

    /// The blocks a line draws: non-empty only when the line's body is exactly
    /// the object char, binding block rendering to the sentinel character.
    internal fun SchemeEditText.blocksForBody(body: String, adornment: EditorLineAdornment?): List<EditorBlock> =
        if (body == BLOCK_OBJECT_STRING) adornment?.blocks.orEmpty() else emptyList()

    /// The on-screen width of a block line's content, used to size the object
    /// char so the caret-before sits at the block's left edge and caret-after at
    /// its right edge (matches the block's own drawn width in `drawBlockStack`).
    internal fun SchemeEditText.blockObjectWidth(blocks: List<EditorBlock>, prefixWidth: Int): Int {
        val maxWidth = editorImageMaxWidth(prefixWidth)
        return when (val block = blocks.firstOrNull()) {
            is EditorBlock.Image ->
                if (block.media.kind != "image") maxWidth
                else mediaDisplaySize(block.media, maxWidth).first.roundToInt().coerceIn(1, maxWidth)
            is EditorBlock.Table -> maxWidth
            else -> maxWidth
        }
    }

    internal fun SchemeEditText.drawImageMedia(canvas: Canvas, media: EditorLineMedia, rect: RectF) {
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

    internal fun SchemeEditText.drawImageFallback(canvas: Canvas, rect: RectF) {
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

    internal fun SchemeEditText.bitmapForPath(path: String): Bitmap? {
        if (imageCache.containsKey(path)) return imageCache[path]
        val decoded = BitmapFactory.decodeFile(path)
        imageCache[path] = decoded
        return decoded
    }

    internal fun SchemeEditText.extraHeightFor(adornment: EditorLineAdornment?, blocks: List<EditorBlock>, prefixWidth: Int, collapseText: Boolean): Int {
        var extra = if (adornment?.annotation == null) 0 else dp(EDITOR_ANNOTATION_HEIGHT_DP)
        extra += blockStackHeight(blocks, editorImageMaxWidth(prefixWidth))
        // A collapsed line reclaims its own text-row height (added by the chrome
        // span shrink) so the total reserved space still fits the blocks.
        if (collapseText) extra += dp(EDITOR_COLLAPSE_TEXT_HEIGHT_DP)
        return extra
    }

    internal fun SchemeEditText.blockStackHeight(blocks: List<EditorBlock>, maxWidth: Int): Int {
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

    internal fun SchemeEditText.tableHeight(table: EditorTable, maxWidth: Int): Int {
        val columnCount = max(1, max(table.columns.size, table.rows.maxOfOrNull { it.size } ?: 0))
        val colWidth = (maxWidth.toFloat() / columnCount).coerceAtLeast(1f)
        return dp(EDITOR_TABLE_HEADER_HEIGHT_DP) + tableRowHeights(table, colWidth).sumOf { it.roundToInt() }
    }

    internal fun SchemeEditText.tableRowHeights(table: EditorTable, columnWidth: Float): List<Float> {
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

    internal fun SchemeEditText.tableTextPaint(color: Int, bold: Boolean): TextPaint =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            textSize = dp(13f)
            typeface = if (bold) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.DEFAULT
        }

    internal fun SchemeEditText.tableTextLayout(content: CharSequence, paint: TextPaint, width: Int): StaticLayout =
        StaticLayout.Builder.obtain(content, 0, content.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(0f, 1f)
            .setIncludePad(false)
            .build()

    // Renders `value` with inline markdown (bold, italic, highlight, strike)
    // stripped of delimiter tokens — matching iOS cell rendering. Headers
    // (bold=true) are returned as plain text; body cells get styled spans.
    internal fun SchemeEditText.tableTextMarkdownSpannable(value: String, bold: Boolean): CharSequence {
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

    internal fun SchemeEditText.appendCellMarkdownSegment(ssb: SpannableStringBuilder, src: String, srcStart: Int, srcEnd: Int, style: InlineMarkdownStyle) {
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

    internal fun SchemeEditText.appendCellStyledText(ssb: SpannableStringBuilder, text: String, style: InlineMarkdownStyle) {
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

    internal fun SchemeEditText.mediaDisplaySize(media: EditorLineMedia, maxWidth: Int): Pair<Float, Float> {
        val rawWidth = dp((media.width ?: EDITOR_IMAGE_FALLBACK_WIDTH_DP).coerceAtLeast(1)).toFloat()
        val rawHeight = dp((media.height ?: EDITOR_IMAGE_FALLBACK_HEIGHT_DP).coerceAtLeast(1)).toFloat()
        if (rawWidth <= 0f || rawHeight <= 0f || maxWidth <= 0) return 0f to 0f
        val scale = min(1f, min(maxWidth / rawWidth, dp(EDITOR_IMAGE_MAX_HEIGHT_DP) / rawHeight))
        return rawWidth * scale to rawHeight * scale
    }

    internal fun SchemeEditText.editorImageMaxWidth(prefixWidth: Int): Int =
        max(dp(120), (width.takeIf { it > 0 } ?: dp(EDITOR_IMAGE_FALLBACK_WIDTH_DP + 80)) - totalPaddingLeft - prefixWidth - totalPaddingRight - dp(8))

    internal fun SchemeEditText.annotationGuideX(markerRect: RectF): Float =
        markerRect.left - dp((EDITOR_ANNOTATION_BAR_GAP_DP + EDITOR_INDENT_GUIDE_X_SHIFT_DP).toFloat())

