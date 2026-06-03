package com.enigmadux.knotq

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class NotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            MobileNotificationScheduler.ACTION_DELIVER -> {
                MobileNotificationScheduler.deliver(context, intent)
            }
            else -> {
                if (MobileNotificationScheduler.isNotificationAction(intent.action)) {
                    runAsync {
                        MobileNotificationScheduler.handleAction(context, intent)
                    }
                }
            }
        }
    }

    private fun runAsync(block: () -> Unit) {
        val pending = goAsync()
        Thread {
            try {
                block()
            } finally {
                pending.finish()
            }
        }.start()
    }
}
