package com.enigmadux.knotq

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Test

class HttpResponseLimitsTest {
    @Test
    fun responseAtTheCapIsAccepted() {
        val input = ByteArrayInputStream(ByteArray(16) { 'x'.code.toByte() })

        assertEquals("x".repeat(16), input.readUtf8Capped(maxBytes = 16))
    }

    @Test(expected = IllegalArgumentException::class)
    fun responseBeyondTheCapIsRejectedBeforeItCanGrowUnbounded() {
        val input = ByteArrayInputStream(ByteArray(17) { 'x'.code.toByte() })

        input.readUtf8Capped(maxBytes = 16)
    }

    @Test
    fun defaultControlPlaneCapIsOneMiB() {
        assertEquals(1L * 1024L * 1024L, MAX_HTTP_RESPONSE_BYTES)
    }
}
