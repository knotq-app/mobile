package com.enigmadux.knotq

import android.content.Context
import com.google.firebase.FirebaseApp

/**
 * Firebase is only needed for the optional FCM sync wakeup path. Do not let
 * FirebaseInitProvider spend cold-start time initializing it before KnotQ can
 * draw its local-first workspace shell; initialize it at the first explicit
 * push-registration or messaging boundary instead.
 */
internal object KnotQFirebase {
    @Volatile
    private var initialized = false

    fun initialize(context: Context): Boolean {
        if (initialized) return true
        return synchronized(this) {
            if (initialized) return true
            val ready = runCatching {
                FirebaseApp.getApps(context).firstOrNull() ?: FirebaseApp.initializeApp(context)
            }.getOrNull() != null
            if (ready) initialized = true
            ready
        }
    }
}
