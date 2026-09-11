package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic malformed-document coverage for the editor's pure model layer. */
class SchemeDocumentFuzzTest {
    @Test
    fun cachedChromeOrdinalsMatchTheDocumentRule() {
        val rawLines = listOf(
            "1. first",
            "    1. child",
            "    2. child",
            "        a deeper interruption",
            "    3. child",
            "1. second",
            "    1. fresh child",
            "    ordinary text",
            "    2. restarted child",
        )
        val document = parseEditorDocument(rawLines.joinToString("\n") + "\n", preserveBlankDocument = true)
        val tracker = ChromeOrdinalTracker()

        rawLines.forEachIndexed { index, raw ->
            assertEquals(
                "ordinal mismatch at line $index",
                documentNumberedOrdinal(document, index),
                tracker.next(parseChromeLine(raw)),
            )
        }

        // The explicit case above is easy to review; this deterministic stream
        // probes the same invariant across many arbitrary nesting transitions.
        // It specifically includes deeper transparent lines and same-level
        // non-numbered interruptions, which are where an incremental tracker
        // can diverge from the reference scan.
        var state = 0x4f1bbcdc
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }
        repeat(8192) {
            val count = (next() ushr 26) and 0x3f
            val generated = buildList(count) {
                repeat(count) {
                    val indent = (next() ushr 28) and 0x0f
                    val marker = when ((next() ushr 29) and 3) {
                        0 -> "${(next() ushr 1) and 0x7fff}. item"
                        1 -> "- item"
                        2 -> "[ ] item"
                        else -> "plain item"
                    }
                    add("    ".repeat(indent) + marker)
                }
            }
            val generatedDocument = parseEditorDocument(
                generated.joinToString("\n") + "\n",
                preserveBlankDocument = true,
            )
            val generatedTracker = ChromeOrdinalTracker()
            generated.forEachIndexed { index, raw ->
                assertEquals(
                    "fuzz ordinal mismatch at case=$it line=$index raw=${raw.take(80)}",
                    documentNumberedOrdinal(generatedDocument, index),
                    generatedTracker.next(parseChromeLine(raw)),
                )
            }
        }
    }

    @Test
    fun extremeUnicodeAndMarkerDocumentsRemainRoundTrippable() {
        var state = 0x51f15e7
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(4096) {
            val lineCount = (next() ushr 27) and 0x1f
            val raw = buildString {
                repeat(lineCount) { lineIndex ->
                    when ((next() ushr 28) and 7) {
                        0 -> append("    ".repeat((next() ushr 29) and 0x0f))
                        1 -> append("\t".repeat((next() ushr 29) and 0x0f))
                        2 -> append("[x] ")
                        3 -> append("[ ] ")
                        4 -> append("- ")
                        5 -> append("* ")
                        6 -> append("${Int.MAX_VALUE}. ")
                        else -> append("[broken")
                    }
                    val characterCount = (next() ushr 26) and 0x3f
                    repeat(characterCount) {
                        append(
                            when ((next() ushr 28) and 15) {
                                0 -> BLOCK_OBJECT_STRING
                                1 -> "\u0000"
                                2 -> "\uD800" // unpaired high surrogate from damaged input
                                3 -> "\uDC00" // unpaired low surrogate from damaged input
                                4 -> "\u200B"
                                5 -> "#"
                                6 -> "💥"
                                else -> ('a'.code + ((next() ushr 1) % 26)).toChar().toString()
                            }
                        )
                    }
                    if (lineIndex + 1 < lineCount) append('\n')
                }
                // Exercise both the editor's terminal-newline invariant and a
                // completely empty document on alternating cases.
                if ((next() and 1) == 0) append('\n')
            }

            val parsed = parseEditorDocument(raw, preserveBlankDocument = true)
            assertTrue(parsed.all { it.indent in 0..8 })
            assertTrue(parsed.all { it.marker in setOf("blank", "checkbox", "bullet", "numbered") })
            parsed.indices.forEach { documentNumberedOrdinal(parsed, it) }

            val rendered = renderDocument(parsed)
            assertTrue("missing terminal newline", rendered.endsWith('\n'))
            val reparsed = parseEditorDocument(rendered, preserveBlankDocument = true)
            assertEquals(parsed.size, reparsed.size)

            val old = parsed.mapIndexed { index, line -> line.copy(id = "fuzz-$index") }
            val reconciled = reconcileEditorLines(old, reparsed)
            assertEquals(reparsed.size, reconciled.size)
            assertTrue(renderDocument(reconciled).endsWith('\n'))
        }
    }
}
