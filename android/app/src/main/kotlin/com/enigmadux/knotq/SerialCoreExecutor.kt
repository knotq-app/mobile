package com.enigmadux.knotq

import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One FIFO boundary for every call into the disk-backed/native mobile core.
 *
 * Most UI work submits fire-and-forget jobs. A few background loops need a
 * result before deciding what to do next, so [call] submits the operation and
 * waits on the calling background thread. It executes inline when already on
 * this queue, which prevents a nested call from deadlocking the single worker.
 * The UI thread should use [execute] and never [call].
 */
internal class SerialCoreExecutor(
    threadName: String = "KnotQ-core",
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val onCoreThread = ThreadLocal<Boolean>()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor(
        ThreadFactory { runnable ->
            Thread {
                onCoreThread.set(true)
                try {
                    runnable.run()
                } finally {
                    onCoreThread.remove()
                }
            }.apply { name = threadName }
        },
    )

    fun execute(block: () -> Unit) {
        check(!closed.get()) { "KnotQ core executor is closed" }
        executor.execute {
            onCoreThread.set(true)
            try {
                block()
            } finally {
                onCoreThread.remove()
            }
        }
    }

    fun <T> call(block: () -> T): T {
        if (onCoreThread.get() == true) return block()
        check(!closed.get()) { "KnotQ core executor is closed" }
        return try {
            executor.submit(Callable { block() }).get()
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IllegalStateException("Interrupted while waiting for KnotQ core", error)
        } catch (error: ExecutionException) {
            throw error.cause ?: error
        }
    }

    /**
     * Prevents new work, lets already accepted work finish in FIFO order, and
     * runs [after] as the final queue item. This is used for native teardown:
     * closing the bridge before an in-flight request finishes can race JNA and
     * turn a lifecycle transition into a process crash. The caller never waits
     * on the queue, so Activity destruction remains non-blocking.
     */
    fun closeAfter(after: () -> Unit) {
        if (!closed.compareAndSet(false, true)) return
        executor.execute {
            runCatching { after() }
        }
        executor.shutdown()
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            executor.shutdownNow()
        }
    }
}
