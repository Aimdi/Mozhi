package io.github.aimdi.mozhi

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Opt-in listener for incoming notifications from other apps so Mozhi can
 * translate them **strictly on this device** (offline engine only; never sent
 * to any server or cloud provider).
 *
 * Off by default (`PREF_ENABLED` = false). Ignores Mozhi's own notifications,
 * muted packages, secret/ongoing/foreground/no-clear/group-summary
 * notifications, non-message categories, and pauses while the device screen
 * is locked.
 */
class NotificationTranslateService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (!isEnabled(this)) return
        if (sbn.packageName == packageName) return
        if (isPackageMuted(this, sbn.packageName)) return
        val notification = sbn.notification ?: return
        if (notification.visibility == Notification.VISIBILITY_SECRET) return
        val flags = notification.flags
        if ((flags and Notification.FLAG_ONGOING_EVENT) != 0) return
        if ((flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        if ((flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) return
        if ((flags and Notification.FLAG_NO_CLEAR) != 0) return
        if ((flags and Notification.FLAG_LOCAL_ONLY) != 0 &&
            sbn.tag == TRANSLATED_TAG
        ) {
            return
        }
        if (notification.category in IGNORED_CATEGORIES) return
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard?.isKeyguardLocked == true) return

        val extras = notification.extras ?: return
        val (title, body) = extractContent(extras)
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

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (sbn.packageName == packageName) return
        cancelTranslation(this, sbn.key.hashCode())
    }

    private fun extractContent(extras: Bundle): Pair<String, String> {
        var title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        if (title.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            title = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
                ?.toString()
                ?.trim()
                .orEmpty()
        }

        // Prefer latest MessagingStyle message when present.
        val messaging = extractLatestMessagingMessage(extras)
        if (messaging != null) {
            val (sender, text) = messaging
            val resolvedTitle = title.ifEmpty { sender }
            return resolvedTitle to text
        }

        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        val body = bigText?.takeIf { it.isNotEmpty() }
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        return title to body
    }

    private fun extractLatestMessagingMessage(extras: Bundle): Pair<String, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        val messages: Array<out Parcelable>? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                extras.getParcelableArray(Notification.EXTRA_MESSAGES, Parcelable::class.java)
            } else {
                @Suppress("DEPRECATION")
                extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            }
        if (messages.isNullOrEmpty()) return null
        for (index in messages.indices.reversed()) {
            val bundle = messages[index] as? Bundle ?: continue
            val text = bundle.getCharSequence("text")?.toString()?.trim().orEmpty()
            if (text.isEmpty()) continue
            var sender = bundle.getCharSequence("sender")?.toString()?.trim().orEmpty()
            if (sender.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val person = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    bundle.getParcelable("sender_person", Person::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    bundle.getParcelable("sender_person")
                }
                sender = person?.name?.toString()?.trim().orEmpty()
            }
            return sender to text
        }
        return null
    }

    companion object {
        const val PREFS = "mozhi_notification_translate"
        const val PREF_ENABLED = "enabled"
        const val PREF_MUTED_PACKAGES = "muted_packages"
        const val PREF_TARGET_LANGUAGE = "target_language"
        const val CHANNEL_ID = "notification_translate"
        const val TRANSLATED_TAG = "mozhi_translated_notification"
        private const val MAX_TITLE_CHARS = 120
        private const val MAX_TEXT_CHARS = 500

        private val IGNORED_CATEGORIES = setOf(
            Notification.CATEGORY_CALL,
            Notification.CATEGORY_ALARM,
            Notification.CATEGORY_SYSTEM,
            Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_TRANSPORT,
            Notification.CATEGORY_SERVICE,
        )

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_ENABLED, false)

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_ENABLED, enabled)
                .apply()
        }

        fun mutedPackages(context: Context): Set<String> {
            val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getStringSet(PREF_MUTED_PACKAGES, null)
            return if (stored == null) emptySet() else stored.toSet()
        }

        fun isPackageMuted(context: Context, packageName: String): Boolean =
            mutedPackages(context).contains(packageName)

        fun setPackageMuted(context: Context, packageName: String, muted: Boolean) {
            val trimmed = packageName.trim()
            if (trimmed.isEmpty()) return
            val updated = mutedPackages(context).toMutableSet()
            if (muted) {
                updated.add(trimmed)
            } else {
                updated.remove(trimmed)
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putStringSet(PREF_MUTED_PACKAGES, updated)
                .apply()
        }

        fun targetLanguage(context: Context): String? =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(PREF_TARGET_LANGUAGE, null)
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

        fun setTargetLanguage(context: Context, code: String?) {
            val trimmed = code?.trim()?.takeIf { it.isNotEmpty() }
            val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            if (trimmed == null) {
                editor.remove(PREF_TARGET_LANGUAGE)
            } else {
                editor.putString(PREF_TARGET_LANGUAGE, trimmed)
            }
            editor.apply()
        }

        fun cancelTranslation(context: Context, id: Int) {
            context.getSystemService(NotificationManager::class.java)
                ?.cancel(TRANSLATED_TAG, id)
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
            val builder = ScreenTranslateNotifications.builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_tile_translate)
                .setContentTitle(displayTitle)
                .setContentText(translation)
                .setStyle(Notification.BigTextStyle().bigText(translation))
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setLocalOnly(true)
                .setAutoCancel(true)
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        id,
                        launchIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            context.getSystemService(NotificationManager::class.java)
                ?.notify(TRANSLATED_TAG, id, builder.build())
        }
    }
}
