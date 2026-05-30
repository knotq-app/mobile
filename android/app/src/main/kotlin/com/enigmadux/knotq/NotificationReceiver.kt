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
            MobileNotificationScheduler.ACTION_MARK_DONE,
            MobileNotificationScheduler.ACTION_SNOOZE_10_MINUTES,
            MobileNotificationScheduler.ACTION_SNOOZE_1_HOUR -> runAsync {
                MobileNotificationScheduler.handleAction(context, intent)
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
