package io.github.aimdi.mozhi

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Opt-in listener for incoming notifications from other apps so Mozhi can
 * translate them **strictly on this device** (offline engine only; never sent
 * to any server or cloud provider).
 *
 * Off by default (`PREF_ENABLED` = false). Ignores Mozhi's own notifications,
 * ongoing/group-summary notifications, and pauses while the screen or app
 * lock is locked.
 */
class NotificationTranslateService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (!isEnabled(this)) return
        if (sbn.packageName == packageName) return
        val notification = sbn.notification ?: return
        val flags = notification.flags
        if ((flags and Notification.FLAG_ONGOING_EVENT) != 0) return
        if ((flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        if ((flags and Notification.FLAG_LOCAL_ONLY) != 0 &&
            sbn.tag == TRANSLATED_TAG
        ) {
            return
        }
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard?.isKeyguardLocked == true) return

        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        val body = (bigText?.takeIf { it.isNotEmpty() }
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty())
        if (body.isEmpty()) return

        NotificationTranslatePlugin.emitNotification(
            mapOf(
                "id" to sbn.key.hashCode(),
                "packageName" to sbn.packageName,
                "title" to title.take(MAX_TITLE_CHARS),
                "text" to body.take(MAX_TEXT_CHARS),
            ),
        )
    }

    companion object {
        const val PREFS = "mozhi_notification_translate"
        const val PREF_ENABLED = "enabled"
        const val CHANNEL_ID = "notification_translate"
        const val TRANSLATED_TAG = "mozhi_translated_notification"
        private const val MAX_TITLE_CHARS = 120
        private const val MAX_TEXT_CHARS = 500

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_ENABLED, false)

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_ENABLED, enabled)
                .apply()
        }

        fun postTranslation(
            context: Context,
            id: Int,
            title: String,
            translation: String,
        ) {
            if (translation.isBlank()) return
            ScreenTranslateNotifications.ensureChannel(
                context,
                CHANNEL_ID,
                R.string.notification_channel_translate_notifications,
                R.string.notification_channel_translate_notifications_description,
            )
            val displayTitle = title.ifBlank {
                context.getString(R.string.notification_translated_title)
            }
            val notification = ScreenTranslateNotifications.builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_tile_translate)
                .setContentTitle(displayTitle)
                .setContentText(translation)
                .setStyle(Notification.BigTextStyle().bigText(translation))
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setLocalOnly(true)
                .setAutoCancel(true)
                .build()
            context.getSystemService(NotificationManager::class.java)
                ?.notify(TRANSLATED_TAG, id, notification)
        }
    }
}
