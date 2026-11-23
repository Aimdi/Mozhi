package io.github.aimdi.mozhi

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps large on-device model downloads (AI models, Whisper speech models,
 * offline language packs, dictionaries) alive while the user leaves Mozhi.
 *
 * Uses Android's `dataSync` foreground service type with a quiet, low-priority
 * progress notification and a Cancel action that tells Dart to stop the
 * running download cleanly (keeping partial bytes for resume). Not exported.
 */
class ModelDownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                ModelDownloadPlugin.notifyCancelled()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: getString(R.string.notification_downloads_title)
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        val notification = buildNotification(title, progress)
        if (!started) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                started = true
            } catch (e: SecurityException) {
                stopSelf()
                return START_NOT_STICKY
            } catch (e: IllegalStateException) {
                stopSelf()
                return START_NOT_STICKY
            }
        } else {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        started = false
        super.onDestroy()
    }

    private fun buildNotification(title: String, progress: Int): Notification {
        ScreenTranslateNotifications.ensureChannel(
            this,
            CHANNEL_ID,
            R.string.notification_channel_downloads,
            R.string.notification_channel_downloads_description,
        )
        val cancelIntent = Intent(this, ModelDownloadService::class.java).apply {
            action = ACTION_CANCEL
        }
        val cancelPending = PendingIntent.getService(
            this,
            1,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val builder = ScreenTranslateNotifications.builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile_translate)
            .setContentTitle(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, progress.coerceIn(0, 100), progress < 0)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.notification_downloads_cancel),
                    cancelPending,
                ).build(),
            )
        if (openIntent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    openIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }

    companion object {
        const val CHANNEL_ID = "model_downloads"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START = "io.github.aimdi.mozhi.action.DOWNLOAD_START"
        const val ACTION_UPDATE = "io.github.aimdi.mozhi.action.DOWNLOAD_UPDATE"
        const val ACTION_STOP = "io.github.aimdi.mozhi.action.DOWNLOAD_STOP"
        const val ACTION_CANCEL = "io.github.aimdi.mozhi.action.DOWNLOAD_CANCEL"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"

        @Volatile
        private var started = false

        fun startOrUpdate(context: Context, title: String, progress: Int?) {
            val intent = Intent(context, ModelDownloadService::class.java).apply {
                action = if (started) ACTION_UPDATE else ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PROGRESS, progress ?: -1)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !started) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: IllegalStateException) {
                // App is in the background without foreground-service exemption;
                // the download still runs as best-effort.
            } catch (e: SecurityException) {
                // Missing permission; download continues in-process.
            }
        }

        fun stop(context: Context) {
            if (!started) return
            context.stopService(Intent(context, ModelDownloadService::class.java))
        }
    }
}
