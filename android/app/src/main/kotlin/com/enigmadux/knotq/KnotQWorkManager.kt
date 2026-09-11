package com.enigmadux.knotq

import android.content.Context
import android.util.Log
import androidx.work.Configuration
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import java.util.concurrent.Executors

/**
 * Lazy WorkManager bootstrap.
 *
 * WorkManager's AndroidX Startup provider otherwise initializes on every cold
 * foreground launch, before the first KnotQ frame can be drawn. KnotQ only
 * needs it when a background sync is actually scheduled (or an action arrives
 * from a receiver), so keep that cost off the normal startup path. The lock
 * also makes receiver/activity races safe when both try to bootstrap at once.
 */
internal object KnotQWorkManager {
    private val lock = Any()
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "knotq-work-manager").apply { isDaemon = true }
    }

    internal fun get(context: Context): WorkManager? {
        val appContext = context.applicationContext
        synchronized(lock) {
            runCatching { WorkManager.getInstance(appContext) }.getOrNull()?.let { return it }

            runCatching {
                WorkManager.initialize(
                    appContext,
                    Configuration.Builder()
                        .setMinimumLoggingLevel(Log.INFO)
                        .build(),
                )
            }

            return runCatching { WorkManager.getInstance(appContext) }.getOrNull()
        }
    }

    internal fun enqueuePeriodic(
        context: Context,
        name: String,
        policy: ExistingPeriodicWorkPolicy,
        request: PeriodicWorkRequest,
    ) {
        executor.execute {
            get(context)?.enqueueUniquePeriodicWork(name, policy, request)
        }
    }

    internal fun cancel(context: Context, name: String) {
        executor.execute {
            get(context)?.cancelUniqueWork(name)
        }
    }

    internal fun enqueueUnique(
        context: Context,
        name: String,
        policy: ExistingWorkPolicy,
        request: OneTimeWorkRequest,
    ) {
        executor.execute {
            get(context)?.enqueueUniqueWork(name, policy, request)
        }
    }
}
