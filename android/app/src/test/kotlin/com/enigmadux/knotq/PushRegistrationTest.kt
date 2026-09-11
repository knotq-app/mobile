package com.enigmadux.knotq

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRegistrationTest {
    @Test
    fun dispatchRunsRegistrationOffTheCallingThread() {
        val executor = SerialCoreExecutor("push-registration-test")
        try {
            val caller = Thread.currentThread()
            val worker = AtomicReference<Thread>()
            val finished = CountDownLatch(1)

            PushRegistration.dispatch(executor) {
                worker.set(Thread.currentThread())
                finished.countDown()
            }

            assertTrue(finished.await(2, TimeUnit.SECONDS))
            assertNotSame(caller, worker.get())
        } finally {
            executor.close()
        }
    }
}
