package com.enigmadux.knotq

import java.util.concurrent.atomic.AtomicLong

/**
 * Generation gate for serialized asynchronous work.
 * Beginning a newer request makes every older completion inert. The atomic
 * generation also lets a worker thread cheaply cancel a queued payload before
 * it enters a slow or side-effecting operation.
 */
internal class LatestRequestGate {
    private val generation = AtomicLong(0L)

    fun begin(): Long {
        return generation.incrementAndGet()
    }

    fun isCurrent(token: Long): Boolean = token == generation.get()
}
