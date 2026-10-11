package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownInlineTest {
    private fun content(body: String): List<Pair<String, InlineMarkdownStyle>> =
        inlineMarkdownRuns(body).filterNot { it.marker }.map { body.substring(it.start, it.end) to it.style }

    @Test
    fun runsCoverTheLineExactlyAndInOrder() {
        for (body in listOf("", "plain", "**b** _i_ ==h== ~~s~~", "a `c` [l](https://x.y) https://z.w.", "**open", "`", "[", "[a](")) {
            var position = 0
            for (run in inlineMarkdownRuns(body)) {
                assertEquals(body, position, run.start)
                assertTrue(body, run.end > run.start)
                position = run.end
            }
            assertEquals(body, body.length, position)
        }
    }

    @Test
    fun emphasisKeepsItsExistingMeaning() {
        assertEquals("b i h s", markdownDisplayText("**b** _i_ ==h== ~~s~~"))
        assertTrue(content("**b**").single().second.bold)
        assertTrue(content("__b__").single().second.bold)
        assertTrue(content("*i*").single().second.italic)
        assertTrue(content("==h==").single().second.highlight)
        assertTrue(content("~~s~~").single().second.strike)
        assertTrue(content("**_x_**").single().second.let { it.bold && it.italic })
        assertEquals("**open", markdownDisplayText("**open"))
    }

    @Test
    fun backticksMarkCodeAndHideThemselves() {
        assertEquals("run cargo test now", markdownDisplayText("run `cargo test` now"))
        assertEquals(listOf("cargo test"), content("run `cargo test` now").filter { it.second.code }.map { it.first })
    }

    @Test
    fun codeIsLiteralAndAnEmptyPairIsNotASpan() {
        assertEquals("**not bold**", markdownDisplayText("`**not bold**`"))
        assertEquals("[a](https://b.c)", markdownDisplayText("`[a](https://b.c)`"))
        assertEquals("a `` b", markdownDisplayText("a `` b"))
        assertEquals("one ` tick", markdownDisplayText("one ` tick"))
        // A span cannot close outside the emphasis it sits in.
        assertEquals("a `b c`", markdownDisplayText("**a `b** c`"))
    }

    @Test
    fun namedLinkShowsOnlyItsLabel() {
        assertEquals("see the docs today", markdownDisplayText("see [the docs](https://example.com/a_b) today"))
        val label = content("see [the docs](https://example.com) today").single { it.second.link }
        assertEquals("the docs", label.first)
        assertEquals("bold label", markdownDisplayText("[**bold** label](mailto:a@b.co)"))
        assertTrue(content("[**bold** label](mailto:a@b.co)").first().second.let { it.bold && it.link })
    }

    @Test
    fun bracketedProseIsNotALink() {
        for (body in listOf("[x] (later)", "[1](2)", "[](https://a.b)", "[a](file:///etc)", "[a](https://a b)", "[a](https://)", "[a[b](https://a.b)")) {
            assertNull(body, namedMarkdownLink(body, 0))
        }
        assertEquals("[1](2)", markdownDisplayText("[1](2)"))
    }

    @Test
    fun bareLinkKeepsItsUnderscoresAndDropsTrailingPunctuation() {
        val body = "at https://example.com/my_file_name."
        // The address is literal: its underscores are not italic markers.
        assertEquals(body, markdownDisplayText(body))
        assertEquals(listOf("https://example.com/my_file_name"), content(body).filter { it.second.link }.map { it.first })
        assertEquals(listOf("www.knotq.com"), content("(www.knotq.com)").filter { it.second.link }.map { it.first })
        assertNull(bareMarkdownLinkEnd("xhttps://a.b", 1))
        val wiki = "(https://en.wikipedia.org/wiki/Rust_(language))"
        assertEquals(wiki.length - 1, bareMarkdownLinkEnd(wiki, 1))
    }

    @Test
    fun quoteMarkerIsTheLeadingAngleAndSpace() {
        assertEquals(2, markdownQuoteMarkerLength("> said"))
        assertEquals(4, markdownQuoteMarkerLength("  > said"))
        assertEquals(1, markdownQuoteMarkerLength(">"))
        assertNull(markdownQuoteMarkerLength(">said"))
        assertNull(markdownQuoteMarkerLength("a > b"))
        assertNull(markdownQuoteMarkerLength(""))
    }

    @Test
    fun ruleIsThreeOrMoreDashesAlone() {
        assertTrue(isMarkdownRule("---"))
        assertTrue(isMarkdownRule("  ------ "))
        assertFalse(isMarkdownRule("--"))
        assertFalse(isMarkdownRule("--- x"))
        assertFalse(isMarkdownRule("- - -"))
        assertFalse(isMarkdownRule(""))
    }

    @Test
    fun malformedInputNeverThrowsAndAlwaysCoversTheLine() {
        val alphabet = "*_=~`[]()>-h:/w. a"
        var state = 0x2545F491
        repeat(20_000) {
            state = state xor (state shl 13)
            state = state xor (state ushr 17)
            state = state xor (state shl 5)
            val length = (state ushr 27) and 0x1f
            val body = buildString(length) {
                repeat(length) {
                    state = state * 1664525 + 1013904223
                    append(alphabet[((state ushr 8) and 0x7fffff) % alphabet.length])
                }
            }
            val runs = inlineMarkdownRuns(body)
            assertEquals(body, body.length, runs.sumOf { it.end - it.start })
            markdownQuoteMarkerLength(body)
            isMarkdownRule(body)
        }
    }
}
