package io.github.aimdi.mozhi

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Live captions of other apps' sound for Dart
 * (`lib/live_captions/data/method_channel_captions_host.dart`), added to
 * every Flutter engine by [MainActivity]; only the engine that started the
 * captions gets their audio and events.
 *
 * - [CHANNEL] `start()`: asks for the microphone permission when it is not
 *   granted (`RECORD_AUDIO`, which capturing other apps' sound needs),
 *   then for the system's capture consent (every time), then starts
 *   [LiveCaptionService]. Answers `{status: "started", captionBar}`
 *   (whether the caption bar shows: "Display over other apps" is allowed),
 *   `{status: "declined"}` or `{status: "failed", reason}`.
 * - `show({translation, original})`: the caption bar's text.
 * - `stop()`: ends the captions.
 * - [AUDIO_CHANNEL]: 16 kHz mono float blocks (`Float32List`) of about
 *   100 ms while the captions run.
 * - [EVENTS_CHANNEL]: `stopTapped`, `openTapped`, `ended`, `locked`,
 *   `unlocked` ([LiveCaptions]).
 *
 * The captions stop when this engine detaches.
 */
class LiveCaptionsPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener,
    LiveCaptions.Listener {
    private var channel: MethodChannel? = null
    private var audioChannel: EventChannel? = null
    private var eventsChannel: EventChannel? = null
    private var audioSink: EventChannel.EventSink? = null
    private var eventsSink: EventChannel.EventSink? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null

    /** The `start()` call waiting for the permission, the consent or the service. */
    private var startCall: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val messenger = binding.binaryMessenger
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
        audioChannel = EventChannel(messenger, AUDIO_CHANNEL).also {
            it.setStreamHandler(sinkHandler { audioSink = it })
        }
        eventsChannel = EventChannel(messenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(sinkHandler { eventsSink = it })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = context
        if (LiveCaptions.listener === this) {
            LiveCaptions.listener = null
            // Nobody is left to read the captions.
            if (context != null) stopCaptions(context)
        }
        // Nobody can hear the answer any more.
        startCall = null
        channel?.setMethodCallHandler(null)
        audioChannel?.setStreamHandler(null)
        eventsChannel?.setStreamHandler(null)
        channel = null
        audioChannel = null
        eventsChannel = null
        audioSink = null
        eventsSink = null
        this.context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
        // In the activity's onCreate: its start is seen (LiveCaptions.appInFront).
        LiveCaptions.followWindows(binding.activity.application)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // The consent's result still reaches the new activity.
        removeListeners()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        removeListeners()
        // A permission or consent asked for this activity cannot come back.
        if (LiveCaptions.listener !== this || !LiveCaptions.awaitingService) {
            answer(failed(REASON_DETACHED))
        }
    }

    private fun removeListeners() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context
        if (context == null) {
            result.error("unavailable", "Not attached", null)
            return
        }
        when (call.method) {
            "start" -> start(context, result)
            "show" -> {
                val translation = call.argument<String>("translation") ?: ""
                val original = call.argument<String>("original") ?: ""
                if (LiveCaptions.listener === this) LiveCaptions.service?.show(translation, original)
                result.success(null)
            }
            "stop" -> {
                if (LiveCaptions.listener === this) {
                    LiveCaptions.listener = null
                    stopCaptions(context)
                }
                answer(mapOf(KEY_STATUS to STATUS_DECLINED))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // Start: microphone permission, consent, service
    // ---------------------------------------------------------------------

    private fun start(context: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(failed(LiveCaptionService.REASON_UNSUPPORTED))
            return
        }
        // A second start replaces the first.
        answer(failed(LiveCaptionService.REASON_BUSY))
        // Captions that run (this engine's or another's) end first.
        if (LiveCaptions.listener != null) {
            LiveCaptions.listener = null
            stopCaptions(context)
        }
        val activity = binding?.activity
        if (activity == null) {
            result.success(failed(REASON_NO_WINDOW))
            return
        }
        startCall = result
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            requestConsent(activity)
        } else {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_MICROPHONE) return false
        if (startCall == null) return true
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val activity = binding?.activity
        when {
            !granted -> answer(failed(REASON_PERMISSION))
            activity == null -> answer(failed(REASON_NO_WINDOW))
            else -> requestConsent(activity)
        }
        return true
    }

    /**
     * The system's capture dialog. On Android 14+ for the whole display:
     * only the sound is used, and picking one app would bring it in front.
     */
    private fun requestConsent(activity: Activity) {
        val manager = activity.getSystemService(MediaProjectionManager::class.java)
        if (manager == null) {
            answer(failed(LiveCaptionService.REASON_UNSUPPORTED))
            return
        }
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CONSENT)
            // The consent is part of starting the captions: an own trip of
            // the app lock, like a file picker.
            AppLockPlugin.noteActivityStartedForResult(ownTrip = true)
        } catch (e: ActivityNotFoundException) {
            answer(failed(LiveCaptionService.REASON_UNSUPPORTED))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CONSENT) return false
        val context = context
        if (startCall == null || context == null) return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            answer(mapOf(KEY_STATUS to STATUS_DECLINED))
            return true
        }
        val session = LiveCaptions.begin(this)
        try {
            LiveCaptionService.start(context, session, resultCode, data)
        } catch (e: IllegalStateException) {
            LiveCaptions.listener = null
            answer(failed(LiveCaptionService.REASON_FOREGROUND))
        } catch (e: SecurityException) {
            LiveCaptions.listener = null
            answer(failed(LiveCaptionService.REASON_FOREGROUND))
        }
        return true
    }

    // ---------------------------------------------------------------------
    // LiveCaptions.Listener (main thread)
    // ---------------------------------------------------------------------

    override fun onStarted(captionBar: Boolean) {
        answer(mapOf(KEY_STATUS to STATUS_STARTED, KEY_CAPTION_BAR to captionBar))
    }

    override fun onFailed(reason: String) {
        LiveCaptions.listener = null
        answer(failed(reason))
    }

    override fun onAudio(samples: FloatArray) {
        audioSink?.success(samples)
    }

    override fun onEvent(event: String) {
        if (event == LiveCaptions.EVENT_STOP_TAPPED || event == LiveCaptions.EVENT_ENDED) {
            LiveCaptions.listener = null
        }
        eventsSink?.success(event)
    }

    // ---------------------------------------------------------------------

    private fun answer(value: Map<String, Any>) {
        val call = startCall ?: return
        startCall = null
        call.success(value)
    }

    private fun failed(reason: String): Map<String, Any> =
        mapOf(KEY_STATUS to STATUS_FAILED, KEY_REASON to reason)

    private fun stopCaptions(context: Context) {
        val service = LiveCaptions.service
        when {
            service != null -> service.stopFromDart()
            // Starting (startForegroundService): it stops itself once it
            // runs, as nobody listens any more (LiveCaptions.started).
            LiveCaptions.awaitingService -> Unit
            else -> context.stopService(Intent(context, LiveCaptionService::class.java))
        }
    }

    private fun sinkHandler(set: (EventChannel.EventSink?) -> Unit) =
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) = set(events)

            override fun onCancel(arguments: Any?) = set(null)
        }

    companion object {
        /** See `MethodChannelCaptionsHost.channelName`. */
        const val CHANNEL = "io.github.aimdi.mozhi/live_captions"
        const val AUDIO_CHANNEL = "io.github.aimdi.mozhi/live_captions/audio"
        const val EVENTS_CHANNEL = "io.github.aimdi.mozhi/live_captions/events"

        const val STATUS_STARTED = "started"
        const val STATUS_DECLINED = "declined"
        const val STATUS_FAILED = "failed"

        // Failure reasons of the plugin (the service's are in LiveCaptionService).
        const val REASON_PERMISSION = "permission"
        const val REASON_NO_WINDOW = "noWindow"
        const val REASON_DETACHED = "detached"

        private const val KEY_STATUS = "status"
        private const val KEY_REASON = "reason"
        private const val KEY_CAPTION_BAR = "captionBar"
        private const val REQUEST_MICROPHONE = 0x5c91
        private const val REQUEST_CONSENT = 0x5c92
    }
}

/**
 * Links [LiveCaptionService] with the [LiveCaptionsPlugin] ([listener],
 * one Flutter engine) that started it, in the app's process. Each start is
 * a session of its own ([begin]); what the service reports for an older
 * session is dropped. The service reports from any thread; the listener
 * hears on the main thread. Also tells the service whether a Mozhi window
 * is on screen ([appInFront]).
 */
object LiveCaptions {
    const val EVENT_STOP_TAPPED = "stopTapped"
    const val EVENT_OPEN_TAPPED = "openTapped"
    const val EVENT_ENDED = "ended"
    const val EVENT_LOCKED = "locked"
    const val EVENT_UNLOCKED = "unlocked"

    /** What the service reports to the plugin that started it. */
    interface Listener {
        fun onStarted(captionBar: Boolean)
        fun onFailed(reason: String)
        fun onAudio(samples: FloatArray)
        fun onEvent(event: String)
    }

    private val main = Handler(Looper.getMainLooper())

    /** The current session (read by the service's reader thread too). */
    @Volatile private var session = 0

    /** The plugin of the running (or starting) captions. Main thread. */
    var listener: Listener? = null

    /** The running service, if any. Main thread. */
    var service: LiveCaptionService? = null

    /** The service was started and has not said whether it runs. Main thread. */
    var awaitingService = false
        private set

    /** Whether captions run (the Quick Settings tile shows it). Main thread. */
    val isRunning: Boolean
        get() = service?.isCapturing == true

    /**
     * The app lock engaged or was lifted ([AppLockSession.setUnlocked]): the
     * caption bar says "Mozhi is locked" instead of captions. Main thread.
     */
    fun onAppLockChanged(locked: Boolean) {
        service?.onAppLockChanged(locked)
    }

    /** A new session for [owner]; returns its id. Main thread. */
    fun begin(owner: Listener): Int {
        listener = owner
        awaitingService = true
        session += 1
        return session
    }

    /** The captions of session [id] run; stopped at once when nobody wants them. */
    fun started(id: Int, captionBar: Boolean) {
        main.post {
            awaitingService = false
            val current = listener
            if (current != null && id == session) {
                current.onStarted(captionBar)
            } else {
                // Stopped (or replaced) while starting.
                service?.stopFromDart()
            }
        }
    }

    fun failed(id: Int, reason: String) {
        main.post {
            awaitingService = false
            val current = listener
            if (current != null && id == session) current.onFailed(reason)
        }
    }

    fun audio(id: Int, samples: FloatArray) = post(id) { it.onAudio(samples) }

    fun event(id: Int, event: String) = post(id) { it.onEvent(event) }

    private fun post(id: Int, action: (Listener) -> Unit) {
        main.post {
            val current = listener
            if (current != null && id == session) action(current)
        }
    }

    // ---------------------------------------------------------------------
    // Mozhi's windows on screen (main thread)
    // ---------------------------------------------------------------------

    private val windowsListener = AppWindows.Listener { service?.onWindowsChanged() }

    /** A Mozhi window is on screen: the caption bar hides ([AppWindows]). */
    val appInFront: Boolean
        get() = AppWindows.inFront

    /** Follows [application]'s activities from now on ([AppWindows.follow]). */
    fun followWindows(application: Application) {
        AppWindows.follow(application)
        AppWindows.addListener(windowsListener)
    }
}
