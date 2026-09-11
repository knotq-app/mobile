package com.enigmadux.knotq

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveInstanceGateTest {
    @Test
    fun publishingANewInstanceInvalidatesTheOldOne() {
        val gate = LiveInstanceGate<Any>()
        val oldInstance = Any()
        val newInstance = Any()

        gate.publish(oldInstance)
        assertTrue(gate.isCurrent(oldInstance))

        gate.publish(newInstance)
        assertFalse(gate.isCurrent(oldInstance))
        assertTrue(gate.isCurrent(newInstance))
        assertSame(newInstance, gate.current())
    }

    @Test
    fun anOldInstanceCannotClearTheCurrentInstance() {
        val gate = LiveInstanceGate<Any>()
        val oldInstance = Any()
        val currentInstance = Any()
        gate.publish(currentInstance)

        gate.clearIfCurrent(oldInstance)

        assertTrue(gate.isCurrent(currentInstance))
    }
}
