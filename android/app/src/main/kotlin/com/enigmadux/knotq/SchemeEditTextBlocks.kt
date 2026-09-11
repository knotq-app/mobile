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
import java.util.concurrent.RejectedExecutionException
import kotlin.math.max
import kotlin.math.min
import kotlin.math.ceil
import kotlin.math.roundToInt

internal data class EditorTableLayoutKey(
    val value: String,
    val width: Int,
    val color: Int,
    val typeface: Typeface?,
    val styled: Boolean,
)

internal data class EditorTableMetrics(
    val width: Int,
    val rowHeights: List<Float>,
)

    /// Draws this line's image/table blocks in document order, stacked from
    /// `yStart`. Records table cell + control hit rects for touch handling.
    internal fun SchemeEditText.drawBlockStack(canvas: Canvas, blocks: List<EditorBlock>, prefixWidth: Int, yStart: Int, lineIndex: Int) {
        if (blocks.isEmpty()) return
        val left = totalPaddingLeft + prefixWidth.toFloat()
        val maxWidth = editorImageMaxWidth(prefixWidth)
        val visibleBottom = (rootView?.height ?: resources.displayMetrics.heightPixels).coerceAtLeast(1).toFloat()
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
                    if (rect.bottom >= 0f && rect.top <= visibleBottom) {
                        drawImageMedia(canvas, block.media, rect)
                    }
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
        val visibleBottom = (rootView?.height ?: resources.displayMetrics.heightPixels).coerceAtLeast(1).toFloat()

        // The grid box: a rounded, filled, outlined panel, then clipped so the
        // header tint and inner rules stay inside the corners (mirrors iOS
        // `drawTable`: buttonBg fill, divider border, bgModal header).
        val gridBottom = top + headerHeight + rowHeights.sum()
        if (gridBottom < 0f || top > visibleBottom) return gridBottom
        val tablePath = tablePathScratch
        tablePath.rewind()
        tableHeaderRectScratch.set(left, top, gridRight, gridBottom)
        tablePath.addRoundRect(tableHeaderRectScratch, dp(6f), dp(6f), Path.Direction.CW)
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
        val headerRect = tableHeaderRectScratch
        headerRect.set(left, y, gridRight, y + headerHeight)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.bgModal
        canvas.drawRect(headerRect, chromePaint)
        val headerTextColor = if (editorTheme.isDark) editorTheme.textSoft else editorTheme.textDim
        if (y + headerHeight >= 0f && y <= visibleBottom) {
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
        }
        y += headerHeight

        // Body rows.
        table.rows.forEachIndexed { rowIndex, row ->
            val rowTop = y
            val rowHeight = rowHeights.getOrNull(rowIndex) ?: dp(EDITOR_TABLE_ROW_HEIGHT_DP).toFloat()
            if (rowTop + rowHeight >= 0f && rowTop <= visibleBottom) {
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
        if (lineY >= 0f && lineY <= visibleBottom) {
            canvas.drawLine(left, lineY, gridRight, lineY, chromePaint)
        }
        rowHeights.forEach { rowHeight ->
            lineY += rowHeight
            if (lineY >= 0f && lineY <= visibleBottom) {
                canvas.drawLine(left, lineY, gridRight, lineY, chromePaint)
            }
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
        val layout = tableTextLayout(
            content = content,
            paint = paint,
            width = (cellWidth - pad * 2).roundToInt().coerceAtLeast(1),
            cacheValue = value,
            styled = !bold,
        )
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
                imageBitmapRectScratch.apply {
                    set(rect.left.roundToInt(), rect.top.roundToInt(), rect.right.roundToInt(), rect.bottom.roundToInt())
                },
                chromePaint
            )
            canvas.restore()
        } else {
            drawImageFallback(canvas, rect)
        }
    }

    internal fun SchemeEditText.drawImageFallback(canvas: Canvas, rect: RectF) {
        val inner = imageFallbackRectScratch
        inner.set(rect.left + 1f, rect.top + 1f, rect.right - 1f, rect.bottom - 1f)
        chromePaint.style = Paint.Style.FILL
        chromePaint.color = editorTheme.bgModal
        canvas.drawRect(inner, chromePaint)
        chromePaint.color = adjustColor(editorTheme.accent, 0.16f)
        canvas.drawCircle(inner.right - inner.width() * 0.23f, inner.top + inner.height() * 0.20f, inner.width() * 0.08f, chromePaint)
        chromePaint.color = editorTheme.divider
        inner.set(inner.left + inner.width() * 0.07f, inner.top + inner.height() * 0.16f, inner.left + inner.width() * 0.47f, inner.top + inner.height() * 0.23f)
        canvas.drawRoundRect(inner, dp(4f), dp(4f), chromePaint)
        inner.set(rect.left + 1f + (rect.width() - 2f) * 0.07f, rect.top + 1f + (rect.height() - 2f) * 0.32f, rect.left + 1f + (rect.width() - 2f) * 0.69f, rect.top + 1f + (rect.height() - 2f) * 0.37f)
        canvas.drawRoundRect(inner, dp(4f), dp(4f), chromePaint)
        inner.set(rect.left + 1f + (rect.width() - 2f) * 0.07f, rect.top + 1f + (rect.height() - 2f) * 0.45f, rect.left + 1f + (rect.width() - 2f) * 0.57f, rect.top + 1f + (rect.height() - 2f) * 0.50f)
        canvas.drawRoundRect(inner, dp(4f), dp(4f), chromePaint)
        inner.set(rect.left + 1f + (rect.width() - 2f) * 0.07f, rect.bottom - 1f - (rect.height() - 2f) * 0.29f, rect.left + 1f + (rect.width() - 2f) * 0.77f, rect.bottom - 1f - (rect.height() - 2f) * 0.16f)
        canvas.drawRoundRect(inner, dp(6f), dp(6f), chromePaint)
        inner.set(rect.left + 1f, rect.top + 1f, rect.right - 1f, rect.bottom - 1f)
        chromePaint.color = editorTheme.textPrimary
        chromePaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        chromePaint.textSize = max(dp(11f), inner.height() * 0.07f)
        canvas.drawText("Image", inner.left + inner.width() * 0.10f, inner.bottom - inner.height() * 0.18f, chromePaint)
        chromePaint.typeface = Typeface.DEFAULT
    }

    internal fun SchemeEditText.bitmapForPath(path: String): Bitmap? {
        synchronized(imageCache) {
            if (imageCache.containsKey(path)) return imageCache[path]
            if (!imageLoadPending.add(path)) return null
        }
        try {
            imageLoader().execute {
                val decoded = runCatching { decodeEditorBitmap(path) }.getOrNull()
                val publish = {
                    val attached = isAttachedToWindow
                    synchronized(imageCache) {
                        if (attached) imageCache[path] = decoded
                        imageLoadPending.remove(path)
                    }
                    // A failed decode leaves the already-painted placeholder
                    // unchanged. Do not schedule another full editor draw for
                    // missing/corrupt media; successful decodes alone need a
                    // frame to replace the placeholder with pixels.
                    if (attached && decoded != null) invalidate()
                }
                if (!post(publish)) {
                    // The editor was detached between the worker check and
                    // posting. Clear the pending marker so a future editor can
                    // request the path again without retaining the old view.
                    synchronized(imageCache) { imageLoadPending.remove(path) }
                }
            }
        } catch (_: RejectedExecutionException) {
            synchronized(imageCache) { imageLoadPending.remove(path) }
        }
        return null
    }

    private fun SchemeEditText.decodeEditorBitmap(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = editorBitmapSampleSize(bounds.outWidth, bounds.outHeight)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(path, options)
    }

internal fun editorBitmapSampleSize(width: Int, height: Int, maxDimension: Int = 2048): Int {
    if (width <= 0 || height <= 0 || maxDimension <= 0) return 1
    var sample = 1
    while (width / sample > maxDimension || height / sample > maxDimension) {
        if (sample > Int.MAX_VALUE / 2) return sample
        sample *= 2
    }
    return sample
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
        val width = columnWidth.roundToInt().coerceAtLeast(1)
        tableMetricsCache[table]?.takeIf { it.width == width }?.let { return it.rowHeights }
        val minHeight = dp(EDITOR_TABLE_ROW_HEIGHT_DP).toFloat()
        val pad = dp(EDITOR_TABLE_CELL_PAD_DP).toFloat()
        val textWidth = (width.toFloat() - pad * 2).roundToInt().coerceAtLeast(1)
        val paint = tableTextPaint(editorTheme.textPrimary, bold = false)
        val lineHeight = paint.fontMetricsInt.run { bottom - top }.coerceAtLeast(1)
        val largeTable = table.rows.sumOf { it.size } > 256
        val rowHeights = table.rows.map { row ->
            var height = minHeight
            row.forEach { cell ->
                // Large tables are also measured from applyPrefixSpans on the
                // UI thread. Creating thousands of StaticLayouts before the
                // first frame turns a dense table into a visible navigation
                // hitch. A conservative paint-width estimate is sufficient for
                // row geometry; visible cells still use the exact cached
                // StaticLayout when they are painted.
                val lines = if (largeTable) {
                    cell.display.split('\n').sumOf { segment ->
                        max(1, ceil(paint.measureText(segment) / textWidth).toInt())
                    }
                } else {
                    tableTextLayout(
                        content = cell.display,
                        paint = paint,
                        width = textWidth,
                        cacheValue = cell.display,
                        styled = false,
                    ).height / lineHeight
                }
                height = max(height, lines * lineHeight + pad * 2)
            }
            height
        }
        tableMetricsCache[table] = EditorTableMetrics(width, rowHeights)
        return rowHeights
    }

    internal fun SchemeEditText.tableTextPaint(color: Int, bold: Boolean): TextPaint =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            textSize = dp(13f)
            typeface = if (bold) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.DEFAULT
        }

    internal fun SchemeEditText.tableTextLayout(
        content: CharSequence,
        paint: TextPaint,
        width: Int,
        cacheValue: String = content.toString(),
        styled: Boolean = content is Spannable,
    ): StaticLayout {
        val key = EditorTableLayoutKey(
            value = cacheValue,
            width = width,
            color = paint.color,
            typeface = paint.typeface,
            styled = styled,
        )
        synchronized(tableLayoutCache) {
            tableLayoutCache[key]?.let { return it }
        }
        val layout = StaticLayout.Builder.obtain(content, 0, content.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(0f, 1f)
            .setIncludePad(false)
            .build()
        synchronized(tableLayoutCache) { tableLayoutCache[key] = layout }
        return layout
    }

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
