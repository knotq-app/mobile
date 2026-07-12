package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class EditorLineBoundsTest {
    @Test
    fun markerButtonCanTransformFirstEmptyLineWithTerminalNewline() {
        val value = "\n"
        val edit = currentEditorLineEdit(value, 0, markerTransform("bullet"))

        assertEquals(EditorLineBounds(0, 0), edit.bounds)
        assertEquals("- \n", applyEdit(value, edit))
        assertEquals(2, edit.selection)
    }

    @Test
    fun currentLineBoundsNeverInvertAroundEmptyLines() {
        val cases = listOf(
            "",
            "\n",
            "\n\n",
            "Plants\n",
            "- \n",
            "    \n",
            "one\n\nthree\n",
            "[ ] task\n",
        )

        for (value in cases) {
            for (cursor in 0..value.length) {
                val bounds = currentEditorLineBounds(value, cursor)
                assertValidBounds(value, bounds)
                value.substring(bounds.start, bounds.end)
            }
        }
    }

    @Test
    fun toolbarLineTransformsAreSafeAcrossEmptyLineFuzzer() {
        val random = Random(7)
        var value = "\n"
        repeat(2_000) {
            val cursor = random.nextInt(value.length + 1)
            val transform = toolbarTransforms[random.nextInt(toolbarTransforms.size)]
            val edit = currentEditorLineEdit(value, cursor, transform)

            assertValidBounds(value, edit.bounds)
            val next = applyEdit(value, edit)
            assertTrue("selection ${edit.selection} outside ${next.length}", edit.selection in 0..next.length)
            value = if (next.length > 220) "\n" else next
        }
    }

    private val toolbarTransforms: List<(String) -> String> = listOf(
        markerTransform("blank"),
        markerTransform("checkbox"),
        markerTransform("bullet"),
        markerTransform("numbered"),
        { raw ->
            val line = parseEditorLine(raw)
            renderEditorLine(line.copy(indent = (line.indent + 1).coerceIn(0, 8)), 1)
        },
        { raw ->
            val line = parseEditorLine(raw)
            renderEditorLine(line.copy(indent = (line.indent - 1).coerceIn(0, 8)), 1)
        },
        { raw ->
            val line = parseEditorLine(raw)
            val body = line.text
            val trimmed = body.trimStart()
            val leading = body.length - trimmed.length
            val nextBody = if (trimmed.startsWith("#")) {
                val hashes = trimmed.takeWhile { it == '#' }.length
                val afterHashes = trimmed.drop(hashes)
                if (afterHashes.isEmpty() || afterHashes.first().isWhitespace()) {
                    body.substring(0, leading) + afterHashes.dropWhile { it == ' ' || it == '\t' }
                } else {
                    "# $body"
                }
            } else {
                "# $body"
            }
            renderEditorLine(line.copy(text = nextBody), 1)
        },
    )

    private fun markerTransform(marker: String): (String) -> String = { raw ->
        val line = parseEditorLine(raw)
        val nextDone = marker == "checkbox" && line.marker == "checkbox" && !line.done
        renderEditorLine(line.copy(marker = marker, done = nextDone), 1)
    }

    private fun applyEdit(value: String, edit: EditorLineEdit): String =
        value.substring(0, edit.bounds.start) + edit.replacement + value.substring(edit.bounds.end)

    private fun assertValidBounds(value: String, bounds: EditorLineBounds) {
        assertTrue("start ${bounds.start} outside ${value.length}", bounds.start in 0..value.length)
        assertTrue("end ${bounds.end} outside ${value.length}", bounds.end in 0..value.length)
        assertTrue("inverted bounds $bounds for `${value.escape()}`", bounds.start <= bounds.end)
    }

    private fun String.escape(): String = replace("\n", "\\n")
}
