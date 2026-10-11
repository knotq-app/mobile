package com.enigmadux.knotq

// The markdown scanner shared by the scheme editor and its table cells. Pure
// Kotlin (no Android types) so the rules are unit-tested on the JVM; the
// callers turn the runs into spans. Mirrors the desktop parser
// (`scheme_editor/markdown.rs`, `links.rs`) and iOS's `applyInlineMarkdownStyling`.

internal data class InlineMarkdownStyle(
    val bold: Boolean = false,
    val italic: Boolean = false,
    val highlight: Boolean = false,
    val strike: Boolean = false,
    val code: Boolean = false,
    val link: Boolean = false,
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

/// One stretch of a line: either content to show in `style`, or marker
/// characters (delimiters, backticks, a link's brackets and address) that
/// collapse when the caret is off the line.
internal data class MarkdownRun(
    val start: Int,
    val end: Int,
    val style: InlineMarkdownStyle,
    val marker: Boolean,
)

/// A `[label](target)` link: where its label and target sit, and the index just
/// past the closing `)`.
internal data class NamedMarkdownLink(
    val labelStart: Int,
    val labelEnd: Int,
    val targetStart: Int,
    val targetEnd: Int,
    val end: Int,
)

/// A line that is nothing but three or more dashes: a horizontal rule.
internal fun isMarkdownRule(body: String): Boolean {
    val trimmed = body.trim { it == ' ' || it == '\t' }
    return trimmed.length >= 3 && trimmed.all { it == '-' }
}

/// Length of the `> ` that opens a quoted line (leading whitespace included),
/// or of the whole line when it is only `>`. null when the line is not a quote.
internal fun markdownQuoteMarkerLength(body: String): Int? {
    var index = 0
    while (index < body.length && (body[index] == ' ' || body[index] == '\t')) index++
    if (index >= body.length || body[index] != '>') return null
    if (index + 1 == body.length) return body.length
    return if (body[index + 1] == ' ') index + 2 else null
}

/// The runs of `body[start, end)`, covering it exactly and in order.
internal fun inlineMarkdownRuns(
    body: String,
    start: Int = 0,
    end: Int = body.length,
    style: InlineMarkdownStyle = InlineMarkdownStyle(),
): List<MarkdownRun> {
    val runs = ArrayList<MarkdownRun>()
    collectInlineMarkdownRuns(body, start, end, style, runs)
    return runs
}

private fun collectInlineMarkdownRuns(
    body: String,
    start: Int,
    end: Int,
    style: InlineMarkdownStyle,
    runs: MutableList<MarkdownRun>,
) {
    var index = start
    var plainStart = start

    fun flushPlain(upTo: Int) {
        if (upTo > plainStart) runs.add(MarkdownRun(plainStart, upTo, style, marker = false))
    }

    fun marker(from: Int, to: Int) {
        if (to > from) runs.add(MarkdownRun(from, to, style, marker = true))
    }

    while (index < end) {
        // Code first: whatever sits between two backticks is literal, so a
        // `**` or a `[` inside it must not start anything.
        val codeClose = codeSpanClose(body, index, end)
        if (codeClose != null) {
            flushPlain(index)
            marker(index, index + 1)
            runs.add(MarkdownRun(index + 1, codeClose, style.copy(code = true), marker = false))
            marker(codeClose, codeClose + 1)
            index = codeClose + 1
            plainStart = index
            continue
        }
        // `[label](url)`: the label is content (and may carry emphasis); the
        // brackets and the address are markers.
        val named = namedMarkdownLink(body, index, end)
        if (named != null) {
            flushPlain(index)
            marker(index, named.labelStart)
            collectInlineMarkdownRuns(body, named.labelStart, named.labelEnd, style.copy(link = true), runs)
            marker(named.labelEnd, named.end)
            index = named.end
            plainStart = index
            continue
        }
        // A bare URL is literal too: an underscore or asterisk in an address is
        // part of the address, never emphasis.
        val bareEnd = if (style.link) null else bareMarkdownLinkEnd(body, index, end)
        if (bareEnd != null) {
            flushPlain(index)
            runs.add(MarkdownRun(index, bareEnd, style.copy(link = true), marker = false))
            index = bareEnd
            plainStart = index
            continue
        }
        val delimiter = markdownDelimiters.firstOrNull { body.startsWith(it.token, index) && index + it.token.length <= end }
        if (delimiter != null) {
            val innerStart = index + delimiter.token.length
            val close = body.indexOf(delimiter.token, innerStart).takeIf { it >= 0 && it + delimiter.token.length <= end }
            if (close != null) {
                flushPlain(index)
                marker(index, innerStart)
                if (close > innerStart) {
                    collectInlineMarkdownRuns(body, innerStart, close, style.with(delimiter.emphasis), runs)
                }
                marker(close, close + delimiter.token.length)
                index = close + delimiter.token.length
                plainStart = index
                continue
            }
        }
        index++
    }
    flushPlain(end)
}

/// The closing backtick of a `` `code` `` span opening at `index`. An empty
/// pair is not a span.
private fun codeSpanClose(body: String, index: Int, limit: Int): Int? {
    if (body[index] != '`') return null
    val close = body.indexOf('`', index + 1)
    return close.takeIf { it > index + 1 && it < limit }
}

/// What a `[label](target)` target may start with. Only web and mail addresses
/// qualify; anything else (`file:`, an app's own scheme) stays plain text.
private val namedLinkTargetPrefixes = listOf("https://", "http://", "www.", "mailto:")

/// Parses a `[label](target)` link opening at `index`. The label must be
/// non-empty and hold no brackets, and the target must be a web or mail address
/// with no whitespace — so ordinary bracketed prose (`[x] (later)`, `[1](2)`)
/// is left alone.
internal fun namedMarkdownLink(body: String, index: Int, limit: Int = body.length): NamedMarkdownLink? {
    if (index >= limit || body[index] != '[') return null
    var labelEnd = index + 1
    while (labelEnd < limit && body[labelEnd] != ']' && body[labelEnd] != '[' && body[labelEnd] != BLOCK_OBJECT_CHAR) labelEnd++
    if (labelEnd == index + 1 || labelEnd + 1 >= limit || body[labelEnd] != ']' || body[labelEnd + 1] != '(') return null
    val targetStart = labelEnd + 2
    var targetEnd = targetStart
    while (targetEnd < limit && body[targetEnd] != ')' && !endsUrl(body[targetEnd])) targetEnd++
    if (targetEnd >= limit || body[targetEnd] != ')') return null
    val qualifies = namedLinkTargetPrefixes.any {
        targetEnd - targetStart > it.length && body.startsWith(it, targetStart)
    }
    if (!qualifies) return null
    return NamedMarkdownLink(index + 1, labelEnd, targetStart, targetEnd, targetEnd + 1)
}

private val bareLinkPrefixes = listOf("https://", "http://", "www.")
private const val BARE_LINK_STOP_CHARS = "<>\"`{}|\\^"
private const val BARE_LINK_TRAILING_TRIM = ".,;:!?'\")]}>"

private fun endsUrl(ch: Char): Boolean = ch.isWhitespace() || ch.isISOControl()

/// The end of a bare `http(s)://` or `www.` URL opening at `index`, with
/// trailing sentence punctuation trimmed (a closing paren is kept when it
/// balances one inside the URL). null when no URL starts here, or when the
/// prefix sits mid-word.
internal fun bareMarkdownLinkEnd(body: String, index: Int, limit: Int = body.length): Int? {
    if (index >= limit) return null
    // Every prefix starts with `h` or `w`; skip the string compares otherwise.
    val first = body[index]
    if (first != 'h' && first != 'w') return null
    if (bareLinkPrefixes.none { index + it.length <= limit && body.startsWith(it, index) }) return null
    if (index > 0) {
        val before = body[index - 1]
        if (before.isLetterOrDigit() || before == '/' || before == '.') return null
    }
    var end = index
    while (end < limit && !endsUrl(body[end]) && body[end] !in BARE_LINK_STOP_CHARS && body[end] != BLOCK_OBJECT_CHAR) end++
    var opens = 0
    var closes = 0
    for (i in index until end) {
        if (body[i] == '(') opens++ else if (body[i] == ')') closes++
    }
    while (end > index) {
        val last = body[end - 1]
        if (last == ')') {
            if (opens >= closes) break
            closes--
        } else if (last !in BARE_LINK_TRAILING_TRIM) {
            break
        }
        end--
    }
    return end.takeIf { it > index }
}

/// What a line reads as with its markers collapsed: the text a preview shows.
internal fun markdownDisplayText(body: String): String =
    inlineMarkdownRuns(body).filterNot { it.marker }.joinToString("") { body.substring(it.start, it.end) }
