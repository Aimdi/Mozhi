package io.github.aimdi.mozhi

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Takes one screenshot for [ScreenTranslateActivity], right after the user
 * agreed in the system's screen-capture dialog (asked every time, see
 * [ScreenTranslateActivity.requestConsent]):
 *
 * 1. goes to the foreground with the type `mediaProjection` (required since
 *    Android 10, and on Android 14+ before `getMediaProjection`), with a
 *    quiet notification for the second it takes;
 * 2. mirrors the display into an [ImageReader] through a [VirtualDisplay]
 *    at the display's size and density;
 * 3. waits until the screen is still (the consent dialog has faded out:
 *    no new frame for [QUIET_MILLIS], at least [MIN_MILLIS] after the
 *    start, at most [MAX_SETTLE_MILLIS] after the first frame);
 * 4. stops the projection at once, writes that one frame as a PNG into the
 *    app's private cache ([ScreenCaptures.folder]; no MediaStore, no
 *    external storage) and hands it to the window ([ScreenCaptures.deliver]);
 * 5. stops itself.
 *
 * Nothing is recorded or kept beyond that one frame; the window deletes the
 * file as soon as Dart has read it. Not exported: only the window starts
 * it, with the consent's result in [EXTRA_RESULT_DATA].
 */
class ScreenCaptureService : Service() {
    private val main = Handler(Looper.getMainLooper())

    // Set on the main thread before the worker gets any work.
    @Volatile private var worker: HandlerThread? = null
    @Volatile private var handler: Handler? = null
    private var destroyed = false

    // Worker thread only.
    private var requestId: String? = null
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latest: Image? = null
    private var startedAt = 0L
    private var firstFrameAt = 0L
    private var done = false

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // Stopped by the system (or the user, from the status bar).
            finish(ScreenCaptureOutcome.Failed(REASON_STOPPED))
        }
    }

    private val settled = Runnable { take() }

    private val noFrame = Runnable {
        if (latest == null) finish(ScreenCaptureOutcome.Failed(REASON_NO_FRAME))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Started with startForegroundService: into the foreground first,
        // whatever happens next.
        val foreground = startInForeground()
        val id = intent?.getStringExtra(EXTRA_REQUEST_ID)
        if (intent == null || id == null) {
            if (worker == null) stopNow()
            return START_NOT_STICKY
        }
        val data = consentData(intent)
        if (worker != null) {
            // One capture at a time.
            ScreenCaptures.deliver(id, ScreenCaptureOutcome.Failed(REASON_BUSY))
            return START_NOT_STICKY
        }
        if (!foreground || data == null) {
            ScreenCaptures.deliver(id, ScreenCaptureOutcome.Failed(REASON_FOREGROUND))
            stopNow()
            return START_NOT_STICKY
        }
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val width = intent.getIntExtra(EXTRA_WIDTH, 0)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 0)
        val density = intent.getIntExtra(EXTRA_DENSITY, 0)
        val thread = HandlerThread("MozhiScreenCapture").also { it.start() }
        val handler = Handler(thread.looper)
        worker = thread
        this.handler = handler
        handler.post { setUp(id, resultCode, data, width, height, density) }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        // Stopped from outside (the window closed): end the capture. The
        // worker runs what is already posted before it quits.
        handler?.post { finish(ScreenCaptureOutcome.Failed(REASON_CANCELLED)) }
        worker?.quitSafely()
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // Worker thread
    // ---------------------------------------------------------------------

    // ImageReader takes PixelFormat.RGBA_8888 for screen capture, which its
    // @ImageFormat.Format annotation does not list.
    @SuppressLint("WrongConstant")
    private fun setUp(
        id: String,
        resultCode: Int,
        data: Intent,
        width: Int,
        height: Int,
        density: Int,
    ) {
        requestId = id
        val handler = handler ?: return
        if (width <= 0 || height <= 0 || density <= 0) {
            finish(ScreenCaptureOutcome.Failed(REASON_DISPLAY))
            return
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = try {
            manager?.getMediaProjection(resultCode, data)
        } catch (e: SecurityException) {
            null
        } catch (e: IllegalStateException) {
            null
        }
        if (projection == null) {
            finish(ScreenCaptureOutcome.Failed(REASON_PROJECTION))
            return
        }
        this.projection = projection
        // Android 14+ requires a callback before the virtual display.
        projection.registerCallback(projectionCallback, handler)
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, MAX_IMAGES)
        this.reader = reader
        reader.setOnImageAvailableListener({ onFrame(it) }, handler)
        startedAt = SystemClock.uptimeMillis()
        virtualDisplay = try {
            projection.createVirtualDisplay(
                DISPLAY_NAME,
                width,
                height,
                density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader.surface,
                null,
                handler,
            )
        } catch (e: SecurityException) {
            null
        } catch (e: IllegalStateException) {
            null
        }
        if (virtualDisplay == null) {
            finish(ScreenCaptureOutcome.Failed(REASON_DISPLAY))
            return
        }
        handler.postDelayed(noFrame, NO_FRAME_TIMEOUT_MILLIS)
    }

    /** Keeps the newest frame and waits for the screen to be still. */
    private fun onFrame(reader: ImageReader) {
        if (done) return
        val image = try {
            reader.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return
        latest?.close()
        latest = image
        val handler = handler ?: return
        val now = SystemClock.uptimeMillis()
        if (firstFrameAt == 0L) {
            firstFrameAt = now
            handler.removeCallbacks(noFrame)
            // A screen that never stops moving (a video) is taken anyway.
            handler.postDelayed({ take() }, MAX_SETTLE_MILLIS)
        }
        handler.removeCallbacks(settled)
        val wait = maxOf(QUIET_MILLIS, MIN_MILLIS - (now - startedAt))
        handler.postDelayed(settled, wait)
    }

    /** Stops the projection and saves the newest frame. */
    private fun take() {
        if (done) return
        val image = latest
        if (image == null) {
            finish(ScreenCaptureOutcome.Failed(REASON_NO_FRAME))
            return
        }
        latest = null
        // Not a frame more than needed.
        stopProjection()
        val outcome = try {
            save(image)
        } catch (e: IOException) {
            ScreenCaptureOutcome.Failed(REASON_SAVE)
        } catch (e: RuntimeException) {
            ScreenCaptureOutcome.Failed(REASON_SAVE)
        } catch (e: OutOfMemoryError) {
            ScreenCaptureOutcome.Failed(REASON_SAVE)
        } finally {
            image.close()
        }
        finish(outcome)
    }

    /** Writes [image] (RGBA_8888) as a PNG into the screenshots' folder. */
    private fun save(image: Image): ScreenCaptureOutcome {
        val width = image.width
        val height = image.height
        val plane = image.planes[0]
        if (plane.pixelStride != BYTES_PER_PIXEL) {
            return ScreenCaptureOutcome.Failed(REASON_FORMAT)
        }
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val rowBytes = width * BYTES_PER_PIXEL
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            if (rowStride == rowBytes) {
                buffer.rewind()
                bitmap.copyPixelsFromBuffer(buffer)
            } else {
                // Rows are padded: copy them without the padding (the last
                // row may have none, so the buffer is shorter than
                // rowStride * height).
                val tight = ByteBuffer.allocateDirect(rowBytes * height)
                val row = ByteArray(rowBytes)
                for (y in 0 until height) {
                    buffer.position(y * rowStride)
                    buffer.get(row, 0, rowBytes)
                    tight.put(row)
                }
                tight.rewind()
                bitmap.copyPixelsFromBuffer(tight)
            }
            val blank = isBlank(bitmap)
            val token = UUID.randomUUID().toString().replace("-", "")
            val file = ScreenCaptures.newFile(this, token)
            try {
                FileOutputStream(file).use { out ->
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, out)) {
                        throw IOException("PNG encoding failed")
                    }
                }
            } catch (e: IOException) {
                file.delete()
                throw e
            }
            return ScreenCaptureOutcome.Captured(file, width, height, blank)
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Whether every pixel of a coarse grid is (nearly) black: what an app
     * that blocks capture (`FLAG_SECURE`) leaves in the frame.
     */
    private fun isBlank(bitmap: Bitmap): Boolean {
        val stepX = maxOf(1, bitmap.width / BLANK_GRID)
        val stepY = maxOf(1, bitmap.height / BLANK_GRID)
        var y = stepY / 2
        while (y < bitmap.height) {
            var x = stepX / 2
            while (x < bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (Color.red(pixel) > BLANK_LEVEL ||
                    Color.green(pixel) > BLANK_LEVEL ||
                    Color.blue(pixel) > BLANK_LEVEL
                ) {
                    return false
                }
                x += stepX
            }
            y += stepY
        }
        return true
    }

    private fun stopProjection() {
        virtualDisplay?.release()
        virtualDisplay = null
        projection?.let { projection ->
            projection.unregisterCallback(projectionCallback)
            projection.stop()
        }
        projection = null
    }

    /** Ends the capture with [outcome] (once) and stops the service. */
    private fun finish(outcome: ScreenCaptureOutcome) {
        if (done) {
            if (outcome is ScreenCaptureOutcome.Captured) outcome.file.delete()
            return
        }
        done = true
        handler?.removeCallbacksAndMessages(null)
        latest?.close()
        latest = null
        stopProjection()
        reader?.close()
        reader = null
        val id = requestId
        if (id != null) {
            ScreenCaptures.deliver(id, outcome)
        } else if (outcome is ScreenCaptureOutcome.Captured) {
            outcome.file.delete()
        }
        main.post { stopNow() }
    }

    // ---------------------------------------------------------------------
    // Main thread
    // ---------------------------------------------------------------------

    /** Into the foreground as a media projection; false when refused. */
    private fun startInForeground(): Boolean {
        ScreenTranslateNotifications.ensureChannel(
            this,
            ScreenTranslateNotifications.CAPTURE,
            R.string.notification_channel_screen_capture,
            R.string.notification_channel_screen_capture_description,
        )
        val notification = ScreenTranslateNotifications
            .builder(this, ScreenTranslateNotifications.CAPTURE)
            .setSmallIcon(R.drawable.ic_tile_translate_screen)
            .setContentTitle(getString(R.string.notification_screen_capture_title))
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (Android 12+).
            false
        }
    }

    private fun stopNow() {
        if (destroyed) return
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun consentData(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA) as? Intent
        }

    companion object {
        const val EXTRA_REQUEST_ID = "io.github.aimdi.mozhi.extra.CAPTURE_REQUEST"
        const val EXTRA_RESULT_CODE = "io.github.aimdi.mozhi.extra.CAPTURE_RESULT_CODE"
        const val EXTRA_RESULT_DATA = "io.github.aimdi.mozhi.extra.CAPTURE_RESULT_DATA"
        const val EXTRA_WIDTH = "io.github.aimdi.mozhi.extra.CAPTURE_WIDTH"
        const val EXTRA_HEIGHT = "io.github.aimdi.mozhi.extra.CAPTURE_HEIGHT"
        const val EXTRA_DENSITY = "io.github.aimdi.mozhi.extra.CAPTURE_DENSITY"

        // Failure reasons (`ScreenCaptureFailure` in Dart).
        const val REASON_STOPPED = "stopped"
        const val REASON_NO_FRAME = "noFrame"
        const val REASON_BUSY = "busy"
        const val REASON_FOREGROUND = "foreground"
        const val REASON_PROJECTION = "projection"
        const val REASON_DISPLAY = "display"
        const val REASON_SAVE = "save"
        const val REASON_FORMAT = "format"
        const val REASON_CANCELLED = "cancelled"

        /** No new frame for this long: the screen is still. */
        const val QUIET_MILLIS = 250L

        /** The consent dialog's exit animation takes about this long. */
        const val MIN_MILLIS = 350L

        /** Taken at the latest this long after the first frame. */
        const val MAX_SETTLE_MILLIS = 1500L

        /** Given up when no frame arrives within this time. */
        const val NO_FRAME_TIMEOUT_MILLIS = 4000L

        private const val DISPLAY_NAME = "Mozhi screen translation"
        private const val NOTIFICATION_ID = 0x5c7e
        private const val MAX_IMAGES = 3
        private const val BYTES_PER_PIXEL = 4
        private const val PNG_QUALITY = 100
        private const val BLANK_GRID = 32
        private const val BLANK_LEVEL = 8

        /** Starts a capture with the consent's [resultCode] and [data]. */
        fun start(
            context: Context,
            requestId: String,
            resultCode: Int,
            data: Intent,
            width: Int,
            height: Int,
            density: Int,
        ) {
            val intent = Intent(context, ScreenCaptureService::class.java)
                .putExtra(EXTRA_REQUEST_ID, requestId)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
                .putExtra(EXTRA_WIDTH, width)
                .putExtra(EXTRA_HEIGHT, height)
                .putExtra(EXTRA_DENSITY, density)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
