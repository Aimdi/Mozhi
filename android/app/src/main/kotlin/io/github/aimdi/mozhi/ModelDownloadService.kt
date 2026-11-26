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
 * offline language packs, dictionaries, OCR data, starter phrasebooks) alive
 * while the user leaves Mozhi.
 *
 * Uses Android's `dataSync` foreground service type with a quiet, low-priority
 * progress notification and a Cancel action that tells Dart to stop the
 * running download cleanly (keeping partial bytes for resume). Not exported.
 */
class ModelDownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        val isCancel = action == ACTION_CANCEL
        val isStop = action == ACTION_STOP
        val (wasRunning, shouldStop, title, progress) = synchronized(stateLock) {
            val stopNow = isCancel || isStop || pendingStop
            val resolvedTitle = latestTitle.takeIf { it.isNotBlank() }
                ?: intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
                ?: getString(R.string.notification_downloads_title)
            val resolvedProgress = if (latestProgress >= 0) {
                latestProgress
            } else {
                intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
            }
            Quad(running, stopNow, resolvedTitle, resolvedProgress)
        }

        if (shouldStop) {
            if (isCancel) {
                ModelDownloadPlugin.notifyCancelled()
            }
            // Android O+ requires startForeground() when started via
            // startForegroundService(), even if we immediately stop.
            if (!wasRunning && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundSafe(buildNotification(this, title, progress))
            }
            stopForegroundCompat()
            synchronized(stateLock) {
                running = false
                startRequested = false
                pendingStop = false
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildNotification(this, title, progress)
        if (!wasRunning) {
            if (!startForegroundSafe(notification)) {
                synchronized(stateLock) {
                    running = false
                    startRequested = false
                    pendingStop = false
                }
                stopSelf()
                return START_NOT_STICKY
            }
            val stoppedDuringStart = synchronized(stateLock) {
                if (pendingStop) {
                    running = false
                    startRequested = false
                    pendingStop = false
                    true
                } else {
                    running = true
                    false
                }
            }
            if (stoppedDuringStart) {
                stopForegroundCompat()
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
        synchronized(stateLock) {
            running = false
            startRequested = false
            pendingStop = false
        }
        super.onDestroy()
    }

    private fun startForegroundSafe(notification: Notification): Boolean =
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
            true
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalStateException) {
            false
        }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: IllegalStateException) {
            // Best-effort cleanup if never promoted to foreground.
        }
    }

    private data class Quad(
        val wasRunning: Boolean,
        val shouldStop: Boolean,
        val title: String,
        val progress: Int,
    )

    companion object {
        const val CHANNEL_ID = "model_downloads"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START = "io.github.aimdi.mozhi.action.DOWNLOAD_START"
        const val ACTION_UPDATE = "io.github.aimdi.mozhi.action.DOWNLOAD_UPDATE"
        const val ACTION_STOP = "io.github.aimdi.mozhi.action.DOWNLOAD_STOP"
        const val ACTION_CANCEL = "io.github.aimdi.mozhi.action.DOWNLOAD_CANCEL"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"

        private val stateLock = Any()
        private var running = false
        private var startRequested = false
        private var pendingStop = false
        private var latestTitle = ""
        private var latestProgress = -1

        private fun buildNotification(
            context: Context,
            title: String,
            progress: Int,
        ): Notification {
            ScreenTranslateNotifications.ensureChannel(
                context,
                CHANNEL_ID,
                R.string.notification_channel_downloads,
                R.string.notification_channel_downloads_description,
            )
            val resolvedTitle = title.ifBlank {
                context.getString(R.string.notification_downloads_title)
            }
            val cancelIntent = Intent(context, ModelDownloadService::class.java).apply {
                action = ACTION_CANCEL
            }
            val cancelPending = PendingIntent.getService(
                context,
                1,
                cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val openIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val builder = ScreenTranslateNotifications.builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_tile_translate)
                .setContentTitle(resolvedTitle)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setProgress(100, progress.coerceIn(0, 100), progress < 0)
                .addAction(
                    Notification.Action.Builder(
                        null,
                        context.getString(R.string.notification_downloads_cancel),
                        cancelPending,
                    ).build(),
                )
            if (openIntent != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        0,
                        openIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            return builder.build()
        }

        fun startOrUpdate(context: Context, title: String, progress: Int?) {
            val resolvedProgress = progress ?: -1
            val actionToTake = synchronized(stateLock) {
                latestTitle = title
                latestProgress = resolvedProgress
                when {
                    // Already foreground and not stopping: update notification
                    // directly to avoid BackgroundServiceStartNotAllowedException.
                    running && !pendingStop -> 0
                    // Start already in flight: clear any pendingStop so
                    // onStartCommand uses the latest title/progress.
                    startRequested && !running -> {
                        pendingStop = false
                        1
                    }
                    // Not started (or stopping): issue a fresh foreground start.
                    else -> {
                        pendingStop = false
                        startRequested = true
                        2
                    }
                }
            }
            when (actionToTake) {
                0 -> {
                    context.getSystemService(NotificationManager::class.java)
                        ?.notify(NOTIFICATION_ID, buildNotification(context, title, resolvedProgress))
                }
                1 -> {
                    // Nothing to dispatch: onStartCommand is already queued.
                }
                2 -> {
                    val intent = Intent(context, ModelDownloadService::class.java).apply {
                        action = ACTION_START
                        putExtra(EXTRA_TITLE, title)
                        putExtra(EXTRA_PROGRESS, resolvedProgress)
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                    } catch (e: IllegalStateException) {
                        synchronized(stateLock) {
                            startRequested = false
                            pendingStop = false
                        }
                    } catch (e: SecurityException) {
                        synchronized(stateLock) {
                            startRequested = false
                            pendingStop = false
                        }
                    }
                }
            }
        }

        fun stop(context: Context) {
            val shouldStopService = synchronized(stateLock) {
                if (!running && !startRequested) return
                pendingStop = true
                running
            }
            if (shouldStopService) {
                context.stopService(Intent(context, ModelDownloadService::class.java))
            }
        }
    }
}
