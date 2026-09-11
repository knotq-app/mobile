package com.enigmadux.knotq

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SerialCoreExecutorTest {
    @Test
    fun callsAreFifoAndNeverOverlap() {
        val queue = SerialCoreExecutor("test-core")
        try {
            val active = AtomicInteger(0)
            val maxActive = AtomicInteger(0)
            val order = Collections.synchronizedList(mutableListOf<Int>())
            val finished = CountDownLatch(64)

            repeat(64) { index ->
                queue.execute {
                    val now = active.incrementAndGet()
                    maxActive.updateAndGet { old -> maxOf(old, now) }
                    order.add(index)
                    Thread.yield()
                    active.decrementAndGet()
                    finished.countDown()
                }
            }

            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertEquals((0 until 64).toList(), order)
            assertEquals(1, maxActive.get())
        } finally {
            queue.close()
        }
    }

    @Test
    fun callPropagatesFailuresAndNestedCallsDoNotDeadlock() {
        val queue = SerialCoreExecutor("test-core")
        try {
            val worker = queue.call { Thread.currentThread() }
            val nested = queue.call { queue.call { Thread.currentThread() } }
            assertSame(worker, nested)
            assertNotSame(Thread.currentThread(), worker)

            val error = runCatching { queue.call<Int> { error("sentinel") } }.exceptionOrNull()
            assertEquals("sentinel", error?.message)
        } finally {
            queue.close()
        }
    }

    @Test
    fun closeAfterRunsTeardownAfterAcceptedWorkWithoutBlockingCaller() {
        val queue = SerialCoreExecutor("test-core-close-after")
        try {
            val order = Collections.synchronizedList(mutableListOf<String>())
            val finished = CountDownLatch(1)
            queue.execute {
                Thread.sleep(20)
                order += "work"
            }

            queue.closeAfter {
                order += "close"
                finished.countDown()
            }

            assertTrue(finished.await(2, TimeUnit.SECONDS))
            assertEquals(listOf("work", "close"), order)
            assertTrue(runCatching { queue.execute {} }.isFailure)
        } finally {
            // closeAfter is idempotent; this also covers a future implementation
            // where the finalizer is delayed by a test scheduler.
            queue.close()
        }
    }

    @Test
    fun closeAfterDoesNotRunTeardownTwice() {
        val queue = SerialCoreExecutor("test-core-close-once")
        try {
            val closeCount = AtomicInteger(0)
            val completed = CountDownLatch(1)
            queue.closeAfter {
                closeCount.incrementAndGet()
                completed.countDown()
            }
            queue.closeAfter { closeCount.incrementAndGet() }
            assertTrue(completed.await(2, TimeUnit.SECONDS))
            assertEquals(1, closeCount.get())
        } finally {
            queue.close()
        }
    }
}
