package com.enigmadux.knotq

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageAttachLimitsTest {
    @Test
    fun cappedReadAcceptsExactLimitAndPreservesBytes() {
        val source = byteArrayOf(0, 1, 2, 3, 4)
        assertArrayEquals(source, ByteArrayInputStream(source).readBytesCapped(source.size.toLong()))
    }

    @Test(expected = IllegalArgumentException::class)
    fun cappedReadRejectsTheFirstBytePastTheLimit() {
        ByteArrayInputStream(byteArrayOf(1, 2, 3)).readBytesCapped(2L)
    }

    @Test
    fun cappedReadHandlesStreamsThatTemporarilyReturnZero() {
        val source = byteArrayOf(8, 13, 21, 34)
        val stream = object : InputStream() {
            private var offset = 0
            private var zero = true

            override fun read(buffer: ByteArray, off: Int, len: Int): Int {
                if (zero) {
                    zero = false
                    return 0
                }
                if (offset == source.size) return -1
                val count = minOf(len, source.size - offset)
                source.copyInto(buffer, off, offset, offset + count)
                offset += count
                zero = true
                return count
            }

            override fun read(): Int = if (offset == source.size) -1 else source[offset++].toInt()
        }

        assertArrayEquals(source, stream.readBytesCapped(source.size.toLong()))
    }

    @Test
    fun deterministicFuzzerNeverExceedsItsConfiguredLimit() {
        var state = 0x51f15e77
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(2048) {
            val size = next().ushr(1) % 4096
            val limit = (next().ushr(1) % 4096).toLong()
            val bytes = ByteArray(size) { next().toByte() }
            val result = runCatching { ByteArrayInputStream(bytes).readBytesCapped(limit) }
            if (size.toLong() <= limit) {
                assertTrue(result.isSuccess)
                assertEquals(size, result.getOrThrow().size)
            } else {
                assertTrue(result.isFailure)
            }
        }
    }
}
