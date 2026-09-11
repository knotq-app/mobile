package com.enigmadux.knotq

import java.lang.ref.WeakReference

/**
 * Tracks the one Activity instance allowed to publish foreground UI callbacks.
 * The weak reference avoids making a stopped Activity live through process
 * services, while identity checks reject completions from an older instance
 * during Activity recreation.
 */
internal class LiveInstanceGate<T : Any> {
    @Volatile
    private var reference: WeakReference<T>? = null

    fun publish(instance: T) {
        reference = WeakReference(instance)
    }

    fun current(): T? = reference?.get()

    fun isCurrent(instance: T): Boolean = current() === instance

    fun clearIfCurrent(instance: T) {
        if (isCurrent(instance)) reference = null
    }
}
