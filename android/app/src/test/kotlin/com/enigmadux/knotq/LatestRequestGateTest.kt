package com.enigmadux.knotq

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LatestRequestGateTest {
    @Test
    fun beginningANewRequestInvalidatesOlderCompletions() {
        val gate = LatestRequestGate()
        val first = gate.begin()
        assertTrue(gate.isCurrent(first))

        val second = gate.begin()
        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(second))
    }

    @Test
    fun unrelatedTokensNeverBecomeCurrent() {
        val gate = LatestRequestGate()
        val token = gate.begin()
        assertFalse(gate.isCurrent(token + 1))
        assertFalse(gate.isCurrent(Long.MIN_VALUE))
    }

    @Test
    fun gateCanInvalidateAQueuedWorkerFromAnotherThread() {
        val gate = LatestRequestGate()
        val queued = gate.begin()
        val ready = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit {
                ready.countDown()
                while (gate.isCurrent(queued)) {
                    Thread.yield()
                }
            }
            assertTrue(ready.await(1, TimeUnit.SECONDS))
            gate.begin()
            future.get(1, TimeUnit.SECONDS)
            assertFalse(gate.isCurrent(queued))
        } finally {
            executor.shutdownNow()
        }
    }
}
