package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Test

class SearchPreviewTest {
    @Test
    fun stripsStoredMarkdownWithoutDroppingContent() {
        assertEquals(
            "sharper labels Thesis concrete, small",
            searchPreviewText("**sharper labels**\n### Thesis\n__concrete, small__"),
        )
        assertEquals("done plain text", searchPreviewText("[x] done\nplain text"))
    }

    @Test
    fun malformedPreviewInputNeverThrows() {
        var state = 0x31415926
        repeat(8192) {
            state = state xor (state shl 13)
            state = state xor (state ushr 17)
            state = state xor (state shl 5)
            val length = (state ushr 26) and 0x7f
            val raw = buildString(length) {
                repeat(length) {
                    state = state * 1664525 + 1013904223
                    append(
                        when ((state ushr 28) and 7) {
                            0 -> '*'
                            1 -> '_'
                            2 -> '#'
                            3 -> '['
                            4 -> ']'
                            5 -> '\n'
                            else -> ('a'.code + ((state ushr 1) % 26)).toChar()
                        },
                    )
                }
            }
            searchPreviewText(raw)
        }
    }
}
