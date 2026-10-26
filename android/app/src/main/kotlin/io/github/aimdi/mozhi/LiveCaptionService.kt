package io.github.aimdi.mozhi

import android.annotation.TargetApi
import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Live captions of what other apps play (`lib/live_captions/`), after the
 * user agreed in the system's capture dialog (asked every time, see
 * [LiveCaptionsPlugin]):
 *
 * 1. goes to the foreground with the type `mediaProjection` (required for
 *    `getMediaProjection` on Android 14+) and a quiet notification with
 *    **Stop**;
 * 2. records the sound of other apps with an [AudioPlaybackCaptureConfiguration]
 *    (Android 10+; media, games and unknown usages, from apps that allow
 *    it) into an [AudioRecord]: 16 kHz mono float, or what the device
 *    gives (16-bit, 48 or 44.1 kHz), resampled to 16 kHz;
 * 3. hands it to Dart in blocks of about 100 ms ([LiveCaptions.audio], an
 *    event channel), in memory only: nothing is written anywhere, and no
 *    picture of the screen is taken (no virtual display);
 * 4. shows Dart's captions in a caption bar over other apps
 *    ([TYPE_APPLICATION_OVERLAY], with "Display over other apps"): the
 *    translation in large text, the original smaller below it, **Open** and
 *    **Stop**; draggable up and down, never focusable (it cannot take the
 *    keyboard from another app), text in `sp` so it follows the font size.
 *    It hides while a Mozhi window is on screen (the transcript is there,
 *    and Translate screen's screenshot must not show it) and while the phone
 *    is locked.
 *
 * While the phone is locked (screen off, or the lock screen up) no audio
 * is handed on ([LiveCaptions.EVENT_LOCKED] / [LiveCaptions.EVENT_UNLOCKED]).
 * It ends when Dart stops it, from the bar's or the notification's Stop
 * ([LiveCaptions.EVENT_STOP_TAPPED]), when the projection is revoked (the
 * status bar's stop) or the recording fails ([LiveCaptions.EVENT_ENDED]),
 * and when the Flutter engine that started it goes away
 * ([LiveCaptionsPlugin.onDetachedFromEngine]). Not exported; never
 * restarted by the system.
 */
class LiveCaptionService : Service() {
    private val main = Handler(Looper.getMainLooper())

    private var session = 0
    private var projection: MediaProjection? = null
    private var capture: AudioCapture? = null
    private var reader: Thread? = null
    private var receiver: BroadcastReceiver? = null
    private var bar: CaptionBar? = null
    private var ended = false

    /** Read by the reader thread. */
    @Volatile private var running = false

    /** The phone is locked: audio is dropped. Read by the reader thread. */
    @Volatile private var locked = false

    /** The Mozhi activities on screen (started, not stopped). */
    private val visibleActivities = mutableSetOf<Int>()

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            visibleActivities.add(System.identityHashCode(activity))
            updateBar()
        }

        override fun onActivityStopped(activity: Activity) {
            visibleActivities.remove(System.identityHashCode(activity))
            updateBar()
        }

        override fun onActivityDestroyed(activity: Activity) {
            visibleActivities.remove(System.identityHashCode(activity))
            updateBar()
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // Revoked by the system or the user (the status bar's stop).
            main.post { end(LiveCaptions.EVENT_ENDED) }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        LiveCaptions.service = this
        application.registerActivityLifecycleCallbacks(activityCallbacks)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            end(LiveCaptions.EVENT_STOP_TAPPED)
            return START_NOT_STICKY
        }
        // Started with startForegroundService: into the foreground first,
        // whatever happens next.
        val foreground = startInForeground()
        if (intent == null) {
            if (!running) end(null)
            return START_NOT_STICKY
        }
        val id = intent.getIntExtra(EXTRA_SESSION, 0)
        if (running) {
            // One capture at a time (the plugin stops the old one first).
            LiveCaptions.failed(id, REASON_BUSY)
            return START_NOT_STICKY
        }
        session = id
        ended = false
        val data = consentData(intent)
        when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q -> fail(REASON_UNSUPPORTED)
            !foreground -> fail(REASON_FOREGROUND)
            data == null -> fail(REASON_PROJECTION)
            else -> begin(intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED), data)
        }
        return START_NOT_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // A rotation, a new font size: the bar measures itself again.
        main.post { bar?.refresh() }
    }

    override fun onDestroy() {
        stopCapture()
        application.unregisterActivityLifecycleCallbacks(activityCallbacks)
        bar?.detach()
        bar = null
        if (LiveCaptions.service === this) LiveCaptions.service = null
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // Capture
    // ---------------------------------------------------------------------

    @TargetApi(Build.VERSION_CODES.Q)
    private fun begin(resultCode: Int, data: Intent) {
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = try {
            manager?.getMediaProjection(resultCode, data)
        } catch (e: SecurityException) {
            null
        } catch (e: IllegalStateException) {
            null
        }
        if (projection == null) {
            fail(REASON_PROJECTION)
            return
        }
        this.projection = projection
        projection.registerCallback(projectionCallback, main)
        val capture = AudioCapture.open(projection)
        if (capture == null || !capture.start()) {
            capture?.release()
            fail(REASON_AUDIO)
            return
        }
        this.capture = capture
        running = true
        watchLock()
        val shown = Settings.canDrawOverlays(this) && showBar()
        LiveCaptions.started(session, shown)
        val id = session
        reader = Thread({ read(capture, id) }, READER_THREAD).also { it.start() }
    }

    /** The reader thread: blocks of audio to Dart until stopped. */
    private fun read(capture: AudioCapture, id: Int) {
        while (running) {
            val block = capture.read()
            if (block == null) {
                // The recording broke (another app took it, a dead server).
                main.post { end(LiveCaptions.EVENT_ENDED) }
                return
            }
            if (block.isNotEmpty() && running && !locked) LiveCaptions.audio(id, block)
        }
    }

    private fun stopCapture() {
        running = false
        val capture = capture
        this.capture = null
        // Unblocks the reader's read().
        capture?.stop()
        reader?.let { thread ->
            try {
                thread.join(JOIN_MILLIS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        reader = null
        capture?.release()
        projection?.let {
            it.unregisterCallback(projectionCallback)
            it.stop()
        }
        projection = null
        receiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Not registered.
            }
        }
        receiver = null
    }

    private fun fail(reason: String) {
        LiveCaptions.failed(session, reason)
        end(null)
    }

    /**
     * Ends the captions once: [event] tells Dart why (null: Dart knows,
     * it stopped them or their start failed).
     */
    private fun end(event: String?) {
        if (ended) return
        ended = true
        stopCapture()
        bar?.detach()
        if (event != null) LiveCaptions.event(session, event)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Stops the captions for Dart ([LiveCaptionsPlugin]'s `stop`). */
    fun stopFromDart() = end(null)

    // ---------------------------------------------------------------------
    // Lock
    // ---------------------------------------------------------------------

    /** Screen off: locked. Screen on without a lock screen, or unlocked: not. */
    private fun watchLock() {
        val keyguard = getSystemService(KeyguardManager::class.java)
        locked = keyguard?.isKeyguardLocked ?: false
        val watcher = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF -> setLocked(true)
                    Intent.ACTION_USER_PRESENT -> setLocked(false)
                    Intent.ACTION_SCREEN_ON ->
                        if (keyguard?.isKeyguardLocked != true) setLocked(false)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(watcher, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(watcher, filter)
            }
            receiver = watcher
        } catch (e: RuntimeException) {
            // Without it the captions just go on while locked.
        }
        if (locked) LiveCaptions.event(session, LiveCaptions.EVENT_LOCKED)
    }

    private fun setLocked(value: Boolean) {
        if (locked == value || ended) return
        locked = value
        LiveCaptions.event(
            session,
            if (value) LiveCaptions.EVENT_LOCKED else LiveCaptions.EVENT_UNLOCKED,
        )
        updateBar()
    }

    // ---------------------------------------------------------------------
    // Foreground
    // ---------------------------------------------------------------------

    private fun startInForeground(): Boolean {
        ScreenTranslateNotifications.ensureChannel(
            this,
            CHANNEL,
            R.string.live_captions_channel,
            R.string.live_captions_channel_description,
        )
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
            true
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (Android 12+).
            false
        }
    }

    /** "Live captions are on" with Stop; a tap opens Mozhi. */
    private fun notification(): Notification {
        val stop = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, LiveCaptionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopAction = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_live_captions_stop),
            getString(R.string.live_captions_stop),
            stop,
        ).build()
        val builder = ScreenTranslateNotifications
            .builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_live_captions)
            .setContentTitle(getString(R.string.live_captions_notification_title))
            .setContentText(getString(R.string.live_captions_notification_text))
            .setStyle(
                Notification.BigTextStyle().bigText(getString(R.string.live_captions_notification_text)),
            )
            .addAction(stopAction)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        openIntent()?.let { open ->
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    REQUEST_OPEN,
                    open,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        return builder.build()
    }

    /** Brings Mozhi's task to the front, as the launcher icon does. */
    private fun openIntent(): Intent? =
        packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)

    private fun openApp() {
        val intent = openIntent() ?: return
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            return
        }
        LiveCaptions.event(session, LiveCaptions.EVENT_OPEN_TAPPED)
    }

    private fun consentData(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA) as? Intent
        }

    // ---------------------------------------------------------------------
    // Caption bar
    // ---------------------------------------------------------------------

    /** Shows Dart's caption ([LiveCaptionsPlugin]'s `show`). */
    fun show(translation: String, original: String) {
        bar?.setText(translation, original)
    }

    private fun showBar(): Boolean {
        if (bar != null) return true
        val created = CaptionBar(overlayContext())
        bar = created
        updateBar()
        return true
    }

    /** Shown unless a Mozhi window is on screen or the phone is locked. */
    private fun updateBar() {
        val bar = bar ?: return
        if (ended || locked || visibleActivities.isNotEmpty() || !Settings.canDrawOverlays(this)) {
            bar.detach()
        } else {
            bar.attach()
        }
    }

    /** A context for overlay windows (a window context on Android 11+). */
    private fun overlayContext(): Context {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return this
        val display = getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return this
        return createDisplayContext(display)
            .createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
    }

    /**
     * The bar: a dark rounded panel with the translation (large) above the
     * original (smaller, hidden when empty), Open and Stop. Dragged up and
     * down by its text; where it was is kept for next time. Only made on
     * Android 10+ (the captions need it).
     */
    @TargetApi(Build.VERSION_CODES.Q)
    private inner class CaptionBar(private val context: Context) {
        private val manager = context.getSystemService(WindowManager::class.java)
        private val translation = TextView(context)
        private val original = TextView(context)
        private val root = LinearLayout(context)
        private val params = WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        )
        private var attached = false

        init {
            root.orientation = LinearLayout.HORIZONTAL
            root.gravity = Gravity.CENTER_VERTICAL
            root.setBackgroundResource(R.drawable.live_captions_bar_background)
            root.contentDescription = getString(R.string.live_captions_bar_description)
            val pad = dp(PADDING_DP)
            root.setPadding(pad, pad / 2, pad / 2, pad / 2)
            val texts = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setOnTouchListener(DragHandler())
            }
            translation.apply {
                setTextColor(context.getColor(R.color.live_captions_text))
                maxLines = TRANSLATION_LINES
                ellipsize = TextUtils.TruncateAt.END
                // Not announced on every change: Mozhi's own screen
                // announces pauses and the end.
                accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_NONE
            }
            original.apply {
                setTextColor(context.getColor(R.color.live_captions_original))
                maxLines = ORIGINAL_LINES
                ellipsize = TextUtils.TruncateAt.END
                visibility = View.GONE
            }
            texts.addView(translation)
            texts.addView(original)
            root.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            root.addView(button(R.drawable.ic_live_captions_open, R.string.live_captions_open_description) { openApp() })
            root.addView(button(R.drawable.ic_live_captions_stop, R.string.live_captions_stop_description) {
                end(LiveCaptions.EVENT_STOP_TAPPED)
            })
            params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            refresh()
        }

        private fun button(icon: Int, description: Int, onClick: () -> Unit): View =
            ImageButton(context).apply {
                setImageResource(icon)
                setBackgroundResource(R.drawable.live_captions_button_background)
                contentDescription = getString(description)
                scaleType = android.widget.ImageView.ScaleType.CENTER
                minimumWidth = dp(TOUCH_DP)
                minimumHeight = dp(TOUCH_DP)
                setOnClickListener { onClick() }
                layoutParams = LinearLayout.LayoutParams(dp(TOUCH_DP), dp(TOUCH_DP))
            }

        fun setText(text: String, source: String) {
            translation.text = text
            original.text = source
            original.visibility = if (source.isBlank()) View.GONE else View.VISIBLE
        }

        /** Text sizes in sp (the font size now) and the width and place. */
        fun refresh() {
            translation.setTextSize(TypedValue.COMPLEX_UNIT_SP, TRANSLATION_SP)
            original.setTextSize(TypedValue.COMPLEX_UNIT_SP, ORIGINAL_SP)
            val screen = screenSize()
            params.width = minOf(screen.first - 2 * dp(MARGIN_DP), dp(MAX_WIDTH_DP))
            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            params.y = (screen.second * prefs.getFloat(KEY_Y, DEFAULT_Y)).roundToInt()
            clampY()
            update()
        }

        fun attach() {
            if (attached) return
            try {
                manager?.addView(root, params)
                attached = true
            } catch (e: WindowManager.BadTokenException) {
                attached = false
            } catch (e: SecurityException) {
                attached = false
            } catch (e: IllegalStateException) {
                attached = false
            }
        }

        fun detach() {
            if (!attached) return
            attached = false
            try {
                manager?.removeViewImmediate(root)
            } catch (e: IllegalArgumentException) {
                // Already gone.
            }
        }

        private fun update() {
            if (!attached) return
            try {
                manager?.updateViewLayout(root, params)
            } catch (e: IllegalArgumentException) {
                // Not attached any more.
            }
        }

        private fun clampY() {
            val height = screenSize().second
            val barHeight = maxOf(root.height, dp(TOUCH_DP))
            params.y = params.y.coerceIn(dp(MARGIN_DP), maxOf(dp(MARGIN_DP), height - barHeight - dp(MARGIN_DP)))
        }

        private fun remember() {
            val height = screenSize().second
            if (height <= 0) return
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putFloat(KEY_Y, params.y.toFloat() / height)
                .apply()
        }

        /** The usable screen (without the system bars), width and height. */
        private fun screenSize(): Pair<Int, Int> {
            val manager = manager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && manager != null) {
                val metrics = manager.currentWindowMetrics
                val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
                )
                return Pair(
                    metrics.bounds.width() - insets.left - insets.right,
                    metrics.bounds.height() - insets.top - insets.bottom,
                )
            }
            val metrics = DisplayMetrics()
            if (manager != null) {
                @Suppress("DEPRECATION")
                manager.defaultDisplay.getRealMetrics(metrics)
            } else {
                metrics.setTo(resources.displayMetrics)
            }
            return Pair(metrics.widthPixels, metrics.heightPixels)
        }

        /** Up and down, by the text; a movement beyond the touch slop drags. */
        private inner class DragHandler : View.OnTouchListener {
            private val slop = ViewConfiguration.get(context).scaledTouchSlop
            private var downY = 0f
            private var startY = 0
            private var dragging = false

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downY = event.rawY
                        startY = params.y
                        dragging = false
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dy = event.rawY - downY
                        if (!dragging && abs(dy) > slop) dragging = true
                        if (dragging) {
                            params.y = startY + dy.roundToInt()
                            clampY()
                            update()
                        }
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        if (dragging) remember()
                        dragging = false
                    }
                }
                return true
            }
        }
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    companion object {
        const val ACTION_STOP = "io.github.aimdi.mozhi.action.STOP_LIVE_CAPTIONS"
        const val EXTRA_SESSION = "io.github.aimdi.mozhi.extra.CAPTIONS_SESSION"
        const val EXTRA_RESULT_CODE = "io.github.aimdi.mozhi.extra.CAPTIONS_RESULT_CODE"
        const val EXTRA_RESULT_DATA = "io.github.aimdi.mozhi.extra.CAPTIONS_RESULT_DATA"

        // Failure reasons (`CaptureFailure` in Dart).
        const val REASON_UNSUPPORTED = "unsupported"
        const val REASON_BUSY = "busy"
        const val REASON_FOREGROUND = "foreground"
        const val REASON_PROJECTION = "projection"
        const val REASON_AUDIO = "audio"

        /** The notification channel (a quiet one, like Translate screen's). */
        const val CHANNEL = "live_captions"

        /** Audio blocks handed to Dart per second (about 100 ms each). */
        const val BLOCKS_PER_SECOND = 10

        /** The sample rate Dart (Whisper) needs. */
        const val TARGET_RATE = 16000

        private const val NOTIFICATION_ID = 0x5c90
        private const val REQUEST_STOP = 1
        private const val REQUEST_OPEN = 2
        private const val READER_THREAD = "MozhiLiveCaptions"
        private const val JOIN_MILLIS = 500L
        private const val PREFS = "live_captions"
        private const val KEY_Y = "y"
        private const val DEFAULT_Y = 0.72f
        private const val TRANSLATION_SP = 20f
        private const val ORIGINAL_SP = 15f
        private const val TRANSLATION_LINES = 4
        private const val ORIGINAL_LINES = 2
        private const val PADDING_DP = 16
        private const val MARGIN_DP = 8
        private const val TOUCH_DP = 48
        private const val MAX_WIDTH_DP = 640

        /** Starts the captions with the consent's [resultCode] and [data]. */
        fun start(context: Context, session: Int, resultCode: Int, data: Intent) {
            val intent = Intent(context, LiveCaptionService::class.java)
                .putExtra(EXTRA_SESSION, session)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}

/**
 * Records other apps' sound ([AudioPlaybackCaptureConfiguration]) and
 * returns it as 16 kHz mono float blocks ([read]), whatever the device
 * records in ([open] tries 16 kHz float first).
 */
@TargetApi(Build.VERSION_CODES.Q)
private class AudioCapture(
    private val record: AudioRecord,
    rate: Int,
    private val float: Boolean,
) {
    private val chunk = rate / LiveCaptionService.BLOCKS_PER_SECOND
    private val floats = FloatArray(chunk)
    private val shorts = if (float) null else ShortArray(chunk)
    private val resampler = Resampler(rate.toDouble() / LiveCaptionService.TARGET_RATE)

    fun start(): Boolean = try {
        record.startRecording()
        record.recordingState == AudioRecord.RECORDSTATE_RECORDING
    } catch (e: IllegalStateException) {
        false
    }

    /** The next block (empty after a stop); null when the recording broke. */
    fun read(): FloatArray? {
        val count = if (float) {
            record.read(floats, 0, chunk, AudioRecord.READ_BLOCKING)
        } else {
            val samples = shorts!!
            val read = record.read(samples, 0, chunk, AudioRecord.READ_BLOCKING)
            for (i in 0 until maxOf(0, read)) floats[i] = samples[i] / PCM16_SCALE
            read
        }
        if (count < 0) return null
        return resampler.process(floats, count)
    }

    fun stop() {
        try {
            record.stop()
        } catch (e: IllegalStateException) {
            // Not recording.
        }
    }

    fun release() = record.release()

    companion object {
        private const val PCM16_SCALE = 32768f

        /** Sample rate and encoding, best first. */
        private val FORMATS = listOf(
            LiveCaptionService.TARGET_RATE to AudioFormat.ENCODING_PCM_FLOAT,
            LiveCaptionService.TARGET_RATE to AudioFormat.ENCODING_PCM_16BIT,
            48000 to AudioFormat.ENCODING_PCM_FLOAT,
            48000 to AudioFormat.ENCODING_PCM_16BIT,
            44100 to AudioFormat.ENCODING_PCM_16BIT,
        )

        /** The first format the device records in; null when none works. */
        fun open(projection: MediaProjection): AudioCapture? {
            val config = try {
                AudioPlaybackCaptureConfiguration.Builder(projection)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                    .build()
            } catch (e: RuntimeException) {
                return null
            }
            for ((rate, encoding) in FORMATS) {
                val record = build(config, rate, encoding) ?: continue
                return AudioCapture(record, rate, encoding == AudioFormat.ENCODING_PCM_FLOAT)
            }
            return null
        }

        private fun build(config: AudioPlaybackCaptureConfiguration, rate: Int, encoding: Int): AudioRecord? {
            val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, encoding)
            if (minimum <= 0) return null
            val bytes = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
            // Room for half a second, so a slow moment loses nothing.
            val size = maxOf(minimum, rate / 2 * bytes)
            val format = AudioFormat.Builder()
                .setEncoding(encoding)
                .setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val record = try {
                AudioRecord.Builder()
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(size)
                    .setAudioPlaybackCaptureConfig(config)
                    .build()
            } catch (e: UnsupportedOperationException) {
                return null
            } catch (e: IllegalArgumentException) {
                return null
            } catch (e: SecurityException) {
                // RECORD_AUDIO was taken back.
                return null
            }
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return null
            }
            return record
        }
    }
}

/**
 * Down to 16 kHz by [ratio] (input rate / output rate, at least 1): each
 * output sample is the mean of the input samples since the previous one
 * (a box filter, enough against aliasing for speech). Keeps its phase
 * between blocks.
 */
private class Resampler(private val ratio: Double) {
    private var phase = 0.0
    private var sum = 0.0
    private var count = 0

    fun process(input: FloatArray, length: Int): FloatArray {
        if (length <= 0) return FloatArray(0)
        if (ratio <= 1.0) return input.copyOf(length)
        val out = FloatArray((length / ratio).toInt() + 2)
        var written = 0
        for (i in 0 until length) {
            sum += input[i]
            count++
            phase += 1.0
            if (phase >= ratio) {
                phase -= ratio
                if (written < out.size) out[written++] = (sum / count).toFloat()
                sum = 0.0
                count = 0
            }
        }
        return out.copyOf(written)
    }
}
