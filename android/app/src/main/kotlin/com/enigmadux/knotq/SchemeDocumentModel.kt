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

// Scheme document model: data types + parse/render between the model JSON, the
// editor's plain-text representation, and draw-time line metadata.

internal data class EditorLineAdornment(
    val marker: String,
    val done: Boolean,
    val annotation: String?,
    // Image/table blocks in document order. Pure text inlines are not blocks;
    // they stay in the editor's text line. A block-only item (empty body text)
    // collapses its text line so the block renders in place, not below a blank.
    val blocks: List<EditorBlock>,
)

internal sealed class EditorBlock {
    data class Image(val media: EditorLineMedia) : EditorBlock()
    data class Table(val table: EditorTable) : EditorBlock()
}

internal data class EditorLineMedia(
    val kind: String,
    val path: String?,
    val width: Int?,
    val height: Int?,
)

internal data class EditorTable(
    val columns: List<EditorTableColumn>,
    val rows: List<List<EditorCell>>,
)

internal data class EditorTableColumn(
    val id: String,
    val name: String,
)

internal data class EditorCell(
    val text: String,
    val lines: List<String>,
) {
    /// The cell's display text: prefer the structured per-line text (joined),
    /// falling back to the flat summary the core also provides.
    val display: String get() = if (lines.isNotEmpty()) lines.joinToString("\n") else text
}

/// A tapped table cell: the logical line (item index), which table within that
/// item, the cell's row/column, its current text, and the on-screen rect the
/// host floats the inline editor over.
internal data class TableCellHit(
    val lineIndex: Int,
    val tableIndex: Int,
    val row: Int,
    val column: Int,
    val text: String,
    val rect: RectF,
) {
    val isHeader: Boolean get() = row < 0
}

internal data class ChromeDrawLine(
    val start: Int,
    val end: Int,
    val indent: Int,
    val marker: String,
    val done: Boolean,
    val annotation: String?,
    val blocks: List<EditorBlock>,
    val prefixWidth: Int,
    val heading: Boolean,
    val extraHeight: Int,
    val collapseText: Boolean,
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

internal fun isMarkdownHeading(line: String): Boolean {
    val trimmed = line.trimStart()
    if (!trimmed.startsWith("#")) return false
    val hashes = trimmed.takeWhile { it == '#' }.length
    return hashes > 0 && (trimmed.length == hashes || trimmed.getOrNull(hashes)?.isWhitespace() == true)
}

internal val numberedPrefix = Regex("^\\d+\\.\\s+")
// Marker tokens that lost their trailing space (or more) to a deletion.
internal val brokenCheckboxPrefix = Regex("^\\[[xX ]?\\]?")
internal val brokenNumberedPrefix = Regex("^\\d+\\.")

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
    // A block line (image/table): its rendered body is one BLOCK_OBJECT_CHAR and
    // its model text stays empty. Carried through parse/commit so the block is
    // preserved only while the object char is present.
    val hasBlock: Boolean = false,
) {
    val rawKey: String = "$marker|$indent|$done|$hasBlock|$text"
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
                done = item.optBoolean("done", false),
                hasBlock = editorBlocksForItem(item).isNotEmpty()
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
        out.add(
            EditorLineAdornment(
                marker = item.optString("marker", "blank"),
                done = item.optBoolean("done", false),
                annotation = annotation,
                blocks = editorBlocksForItem(item)
            )
        )
    }
    return out
}

/// Builds the ordered image/table blocks for one item. When the core supplies
/// `content` (inlines in document order) those drive the order; otherwise we
/// fall back to the flat `media` + `tables` lists for backward compatibility.
internal fun editorBlocksForItem(item: JSONObject): List<EditorBlock> {
    val content = item.optJSONArray("content")
    val blocks = ArrayList<EditorBlock>()
    if (content != null && content.length() > 0) {
        content.forEachObject { inline ->
            when (inline.optString("kind")) {
                "image" -> inline.optJSONObject("media")?.let { blocks.add(EditorBlock.Image(parseEditorMedia(it))) }
                "table" -> inline.optJSONObject("table")?.let { blocks.add(EditorBlock.Table(parseEditorTable(it))) }
                // "text" inlines stay in the editor's text line; nothing to draw.
            }
        }
        return blocks
    }
    item.optJSONArray("media")?.forEachObject { blocks.add(EditorBlock.Image(parseEditorMedia(it))) }
    item.optJSONArray("tables")?.forEachObject { blocks.add(EditorBlock.Table(parseEditorTable(it))) }
    return blocks
}

internal fun parseEditorMedia(raw: JSONObject): EditorLineMedia = EditorLineMedia(
    kind = raw.optString("kind"),
    path = raw.optionalString("path"),
    width = raw.takeUnless { it.isNull("width") }?.optInt("width"),
    height = raw.takeUnless { it.isNull("height") }?.optInt("height")
)

internal fun parseEditorTable(raw: JSONObject): EditorTable {
    val columns = ArrayList<EditorTableColumn>()
    raw.optJSONArray("columns")?.forEachObject { col ->
        columns.add(EditorTableColumn(id = col.optString("id"), name = col.optString("name")))
    }
    val rows = ArrayList<List<EditorCell>>()
    raw.optJSONArray("rows")?.forEachObject { row ->
        val cells = ArrayList<EditorCell>()
        row.optJSONArray("cells")?.forEachObject { cell ->
            val lines = ArrayList<String>()
            cell.optJSONArray("lines")?.forEachObject { line -> lines.add(line.optString("text")) }
            cells.add(EditorCell(text = cell.optString("text"), lines = lines))
        }
        rows.add(cells)
    }
    return EditorTable(columns = columns, rows = rows)
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
    val body = raw.drop(chromePrefixLength(raw).coerceAtMost(raw.length))
    // Object char(s) are always stripped from the stored text. The line stays a
    // block only when its body is exactly the object char (nothing else typed);
    // merging text into it, or deleting the char, demotes it to a text line.
    val cleaned = body.replace(BLOCK_OBJECT_STRING, "")
    val hasBlock = cleaned.isEmpty() && body.contains(BLOCK_OBJECT_CHAR)
    return SchemeEditorLine(
        id = null,
        text = cleaned,
        marker = parsed.marker,
        indent = parsed.indent,
        done = parsed.done,
        hasBlock = hasBlock
    )
}

internal fun renderDocument(lines: List<SchemeEditorLine>): String {
    val body = lines.mapIndexed { index, line ->
        renderEditorLine(line, documentNumberedOrdinal(lines, index))
    }.joinToString("\n")
    return "$body\n"
}

/// iOS ordinal rule: count consecutive prior numbered siblings at the same
/// indent; deeper lines are transparent, anything else ends the run.
internal fun documentNumberedOrdinal(lines: List<SchemeEditorLine>, index: Int): Int {
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
    // A block line (image/table) renders its body as a single object char, but it
    // still carries the indent + marker prefix like any other line — a table or
    // image can be checked off, bulleted, numbered, and indented.
    if (line.hasBlock) return "$indent$prefix$BLOCK_OBJECT_CHAR"
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
    return pinBlockIdsToBlockLines(old, result)
}

/// Guarantees a block item's id follows its object-char line. `reconcileEditorLines`
/// matches ids by position, so splitting a block line (Enter before/after) can hand
/// the block's id to the new blank line and orphan the object-char line — on commit
/// that demotes the empty line (dropping the block) and makes the real block a new,
/// content-less item, deleting the image/table. Here we re-pin block ids (in order)
/// onto the block lines and strip any block id that landed on a non-block line (that
/// block is genuinely being removed — e.g. its object char was deleted).
internal fun pinBlockIdsToBlockLines(
    old: List<SchemeEditorLine>,
    lines: List<SchemeEditorLine>,
): List<SchemeEditorLine> {
    val blockIds = old.filter { it.hasBlock }.mapNotNull { it.id }
    if (blockIds.isEmpty()) return lines
    val blockIdSet = blockIds.toHashSet()
    var nextBlock = 0
    return lines.map { line ->
        when {
            line.hasBlock -> {
                val id = blockIds.getOrNull(nextBlock)?.also { nextBlock++ } ?: line.id
                if (line.id == id) line else line.copy(id = id)
            }
            line.id != null && line.id in blockIdSet -> line.copy(id = null)
            else -> line
        }
    }
}

