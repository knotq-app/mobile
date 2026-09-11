package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Test

class RememberedScrollTest {
    @Test
    fun savedOffsetIsClampedToTheCurrentContent() {
        assertEquals(0, restoredScrollOffset(-40, 1000, 600))
        assertEquals(400, restoredScrollOffset(900, 1000, 600))
        assertEquals(120, restoredScrollOffset(120, 1000, 600))
    }

    @Test
    fun shortContentAlwaysStartsAtTheTop() {
        assertEquals(0, restoredScrollOffset(250, 400, 600))
    }
}
