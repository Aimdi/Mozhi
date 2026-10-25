package io.github.aimdi.mozhi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.Collections
import kotlin.concurrent.thread

/** How a screen capture of [ScreenCaptureService] ended. */
sealed class ScreenCaptureOutcome {
    /**
     * One frame of the screen as a PNG [file] in the app's private cache
     * ([ScreenCaptures.folder]), [width] x [height] pixels. [blank] when the
     * frame came out black (an app on screen that blocks capture with
     * `FLAG_SECURE`).
     */
    data class Captured(
        val file: File,
        val width: Int,
        val height: Int,
        val blank: Boolean,
    ) : ScreenCaptureOutcome()

    /** The user turned the screen-capture consent down. */
    data object Declined : ScreenCaptureOutcome()

    /** Nothing could be captured; [reason] is a short code for Dart. */
    data class Failed(val reason: String) : ScreenCaptureOutcome()
}

/**
 * Hands capture results from [ScreenCaptureService] to the
 * [ScreenTranslateActivity] that asked for them (same process), and keeps
 * the screenshots' folder.
 *
 * Each window asks under a request id of its own; a result whose window is
 * gone (or not listening yet) waits in memory until a window with that id
 * listens, [discard]s it, or the next window deletes every leftover file
 * ([deleteAll]). A file left by an earlier app process (one that ended
 * between saving a PNG and reading it) also goes when this process opens
 * its first window of any kind ([sweepLeftovers]). Main thread only, except
 * [deliver] and [newFile].
 */
object ScreenCaptures {
    /**
     * Cache folder of the screenshots: `<cache>/screen_translate`. Never
     * external storage or MediaStore; not backed up (the app opts out of
     * every backup, and caches are never backed up anyway).
     */
    const val FOLDER = "screen_translate"

    private val main = Handler(Looper.getMainLooper())
    private val listeners = mutableMapOf<String, (ScreenCaptureOutcome) -> Unit>()
    private val pending = mutableMapOf<String, ScreenCaptureOutcome>()

    /**
     * The names of the files this process made ([newFile], on the capture
     * service's thread): [sweepLeftovers] leaves them to their window.
     */
    private val ownFiles: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /** Whether this process ran [sweepLeftovers] already. */
    private var leftoversSwept = false

    fun folder(context: Context): File = File(context.cacheDir, FOLDER)

    /**
     * A new file for a screenshot named [token] (the folder is created).
     * Any thread.
     */
    fun newFile(context: Context, token: String): File {
        val folder = folder(context)
        folder.mkdirs()
        val name = "$token.png"
        // Before the file exists: the sweep can never take it.
        ownFiles.add(name)
        return File(folder, name)
    }

    /**
     * Deletes the screenshots an earlier app process left behind, once per
     * process and on a thread of its own (the folder is listed and files
     * are deleted). Called when any window of the app opens
     * ([MainActivity.onCreate]). Files this process made ([newFile]) stay:
     * a Translate screen window may be about to read one.
     */
    fun sweepLeftovers(context: Context) {
        if (leftoversSwept) return
        leftoversSwept = true
        val folder = folder(context.applicationContext)
        thread(name = SWEEP_THREAD) {
            folder.listFiles()?.forEach { file ->
                if (file.name !in ownFiles) file.delete()
            }
        }
    }

    /** Deletes every screenshot left behind by an earlier window. */
    fun deleteAll(context: Context) {
        folder(context).listFiles()?.forEach { it.delete() }
    }

    /** Hands [outcome] to the window of [requestId] (any thread). */
    fun deliver(requestId: String, outcome: ScreenCaptureOutcome) {
        main.post {
            val listener = listeners[requestId]
            if (listener != null) {
                listener(outcome)
            } else {
                (pending.put(requestId, outcome) as? ScreenCaptureOutcome.Captured)?.file?.delete()
            }
        }
    }

    /** Calls [listener] with the outcome of [requestId] once it is known. */
    fun listen(requestId: String, listener: (ScreenCaptureOutcome) -> Unit) {
        listeners[requestId] = listener
        pending.remove(requestId)?.let(listener)
    }

    fun stopListening(requestId: String) {
        listeners.remove(requestId)
    }

    /** Forgets (and deletes) a result of [requestId] nobody took. */
    fun discard(requestId: String) {
        (pending.remove(requestId) as? ScreenCaptureOutcome.Captured)?.file?.delete()
    }

    private const val SWEEP_THREAD = "MozhiScreenshotSweep"
}

/**
 * The notification channels of the screen translation's foreground
 * services: [CAPTURE] (shown for the second the screenshot takes) and
 * [BUBBLE] (while the bubble is on). Both quiet (low importance, no badge).
 * Their names are set again every time, so they follow the app language.
 */
object ScreenTranslateNotifications {
    const val CAPTURE = "screen_capture"
    const val BUBBLE = "translate_bubble"

    /** Creates (or renames) the channel [id]. */
    fun ensureChannel(context: Context, id: String, name: Int, description: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            id,
            context.getString(name),
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = context.getString(description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    /** A notification builder for [channel]. */
    fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
        }
}
