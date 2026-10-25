package io.github.aimdi.mozhi

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * "Translate screen": the translucent window that translates what is on
 * the screen, from the Quick Settings tile ([TranslateScreenTileService]),
 * the launcher shortcut and the bubble ([TranslateBubbleService]).
 *
 * As soon as it opens it asks for the system's screen-capture consent
 * ([requestConsent], every time; on Android 14+ for the whole display).
 * Once the user agrees, [ScreenCaptureService] takes one frame while this
 * window is still fully transparent (Dart draws nothing until it has the
 * screenshot, see `ScreenTranslateView`), so the frame shows the app
 * below. Its own Flutter engine starts at [ROUTE]
 * (`AppRoutes.screenTranslate`), shows the screenshot full screen and
 * draws the translation over it (on-device text recognition, then the
 * user's engine and privacy mode).
 *
 * [CHANNEL] (`lib/screen_translate/screen_translate_host.dart`):
 *
 * - `screenshot()` answers once the capture ended: `{status: "ok", bytes,
 *   width, height, blank}`, `{status: "declined"}` or `{status: "failed",
 *   reason}`; the PNG is deleted as soon as its bytes are read (and in any
 *   case when the window closes, and at the next window's start).
 * - `close()` finishes the window: the app below is back.
 * - `openInApp({text})` / `openInApp({location})` continue in
 *   [MainActivity] (the recognised text in the translate tab, or an app
 *   location such as the offline languages), then finish, like
 *   [QuickTranslateActivity].
 *
 * Everything else is [MainActivity]'s (privacy helpers, the settings
 * channel). `FLAG_SECURE` is held off while the frame is taken: a secure
 * window, even a transparent one, turns the whole captured frame black
 * ([holdSecureFlag]). The window closes when it goes out of sight after
 * the capture ([onStop]): it is in no recents list, so it could not be
 * returned to, and the screenshot is not kept around.
 *
 * Not exported: only Mozhi's own tile, bubble and shortcut start it.
 */
class ScreenTranslateActivity : MainActivity() {
    private enum class Phase { CONSENT, CAPTURING, DONE }

    private val main = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor()

    private var requestId: String? = null
    private var phase = Phase.CONSENT
    private var outcome: ScreenCaptureOutcome? = null

    /** Dart's `screenshot()` call, until the capture ended. */
    private var screenshotCall: MethodChannel.Result? = null
    private var screenshotTaken = false

    /** Another activity started for a result (consent, a file picker). */
    private var awaitingResult = false
    private var started = false

    /** Whether `FLAG_SECURE` is held off for the capture. */
    private var holdingSecure = false

    /** Whether `FLAG_SECURE` was (or was meanwhile) asked for. */
    private var secureRequested = false

    private val watchdog = Runnable {
        // Dart never asked for the screenshot: never leave an invisible
        // window over the app.
        if (!screenshotTaken && !isFinishing) finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        drawUnderCutout()
        super.onCreate(savedInstanceState)
        val restored = savedInstanceState?.getString(KEY_REQUEST_ID)
        val id = restored ?: newRequestId()
        requestId = id
        if (restored == null) {
            ScreenCaptures.deleteAll(this)
            ScreenCaptures.listen(id) { onOutcome(it) }
            requestConsent()
        } else if (savedInstanceState?.getBoolean(KEY_AWAITING_CONSENT) == true) {
            // Recreated while the consent dialog was open: its result is
            // still delivered to this window.
            awaitingResult = true
            ScreenCaptures.listen(id) { onOutcome(it) }
        } else {
            // The capture (or its screenshot) is gone with the old window.
            ScreenCaptures.discard(id)
            onOutcome(ScreenCaptureOutcome.Failed(REASON_RESTORED))
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(KEY_REQUEST_ID, requestId)
        outState.putBoolean(KEY_AWAITING_CONSENT, phase == Phase.CONSENT && awaitingResult)
    }

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun getInitialRoute(): String = ROUTE

    override fun shouldHandleDeeplinking(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "screenshot" -> {
                    if (outcome != null) {
                        answer(result)
                    } else {
                        // A second call replaces the first.
                        screenshotCall?.success(null)
                        screenshotCall = result
                    }
                }
                "close" -> {
                    result.success(null)
                    close()
                }
                "openInApp" -> {
                    val text = call.argument<String>("text")
                    val location = call.argument<String>("location")
                    val intent = when {
                        !text.isNullOrBlank() -> textIntent(text)
                        location != null -> locationIntent(location)
                        else -> null
                    }
                    if (intent == null) {
                        result.error(
                            "invalid_argument",
                            "openInApp expects a text or an app location",
                            null,
                        )
                    } else {
                        result.success(null)
                        try {
                            startActivity(intent)
                        } catch (e: ActivityNotFoundException) {
                            // Cannot happen for our own activity; just close.
                        }
                        close()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---------------------------------------------------------------------
    // Capture
    // ---------------------------------------------------------------------

    /**
     * The system's screen-capture dialog. On Android 14+ for the whole
     * display (no single-app choice, which would bring that app in front
     * of this window).
     */
    private fun requestConsent() {
        val manager = getSystemService(MediaProjectionManager::class.java)
        if (manager == null) {
            onOutcome(ScreenCaptureOutcome.Failed(REASON_UNSUPPORTED))
            return
        }
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        try {
            startActivityForResult(intent, REQUEST_CONSENT)
        } catch (e: ActivityNotFoundException) {
            onOutcome(ScreenCaptureOutcome.Failed(REASON_UNSUPPORTED))
        }
    }

    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        // Plugins (a file picker, the app lock's screen-lock check) go
        // through here too: the window stays while they are open. Plain
        // startActivity calls pass -1 and expect no result.
        if (requestCode >= 0) awaitingResult = true
        super.startActivityForResult(intent, requestCode, options)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        awaitingResult = false
        if (requestCode != REQUEST_CONSENT) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        if (phase != Phase.CONSENT || outcome != null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            onOutcome(ScreenCaptureOutcome.Declined)
            return
        }
        val id = requestId ?: return
        phase = Phase.CAPTURING
        holdSecureFlag()
        val (width, height, density) = captureSize()
        try {
            ScreenCaptureService.start(this, id, resultCode, data, width, height, density)
        } catch (e: IllegalStateException) {
            onOutcome(ScreenCaptureOutcome.Failed(REASON_SERVICE))
        } catch (e: SecurityException) {
            onOutcome(ScreenCaptureOutcome.Failed(REASON_SERVICE))
        }
    }

    /**
     * The size and density of the display as this window sees it now (the
     * current rotation), at most [MAX_SIDE] pixels on the long side.
     */
    private fun captureSize(): Triple<Int, Int, Int> {
        var width: Int
        var height: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.maximumWindowMetrics.bounds
            width = bounds.width()
            height = bounds.height()
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(metrics)
            width = metrics.widthPixels
            height = metrics.heightPixels
        }
        var density = resources.displayMetrics.densityDpi
        val longest = maxOf(width, height)
        if (longest > MAX_SIDE) {
            val scale = MAX_SIDE.toDouble() / longest
            width = (width * scale).toInt()
            height = (height * scale).toInt()
            density = maxOf(1, (density * scale).toInt())
        }
        return Triple(width, height, density)
    }

    /** The end of the capture (main thread, once). */
    private fun onOutcome(result: ScreenCaptureOutcome) {
        if (outcome != null) {
            (result as? ScreenCaptureOutcome.Captured)?.file?.delete()
            return
        }
        val wasCapturing = phase == Phase.CAPTURING
        outcome = result
        phase = Phase.DONE
        releaseSecureFlag()
        if (result == ScreenCaptureOutcome.Declined) {
            screenshotCall?.let { call ->
                screenshotCall = null
                answer(call)
            }
            close()
            return
        }
        if (wasCapturing && !started && !isFinishing) {
            // Left while the frame was taken: nothing to show it to.
            close()
            return
        }
        val call = screenshotCall
        if (call != null) {
            screenshotCall = null
            answer(call)
        } else {
            main.postDelayed(watchdog, WATCHDOG_MILLIS)
        }
    }

    /** Answers `screenshot()` with the outcome; reads (and deletes) the PNG. */
    private fun answer(result: MethodChannel.Result) {
        main.removeCallbacks(watchdog)
        when (val captured = outcome) {
            is ScreenCaptureOutcome.Captured -> {
                if (screenshotTaken) {
                    result.success(mapOf("status" to STATUS_FAILED, "reason" to REASON_TAKEN))
                    return
                }
                screenshotTaken = true
                io.execute {
                    val bytes = try {
                        captured.file.readBytes()
                    } catch (e: IOException) {
                        null
                    } finally {
                        captured.file.delete()
                    }
                    main.post {
                        result.success(
                            if (bytes == null) {
                                mapOf("status" to STATUS_FAILED, "reason" to REASON_READ)
                            } else {
                                mapOf(
                                    "status" to STATUS_OK,
                                    "bytes" to bytes,
                                    "width" to captured.width,
                                    "height" to captured.height,
                                    "blank" to captured.blank,
                                )
                            },
                        )
                    }
                }
            }
            is ScreenCaptureOutcome.Failed ->
                result.success(mapOf("status" to STATUS_FAILED, "reason" to captured.reason))
            ScreenCaptureOutcome.Declined -> result.success(mapOf("status" to STATUS_DECLINED))
            null -> result.success(null)
        }
    }

    // ---------------------------------------------------------------------
    // FLAG_SECURE
    // ---------------------------------------------------------------------

    /**
     * Turns `FLAG_SECURE` off for the capture (the window shows nothing
     * yet) and keeps it off until [releaseSecureFlag], remembering whether
     * it was asked for (the "block screenshots" setting).
     */
    private fun holdSecureFlag() {
        holdingSecure = true
        if (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) {
            secureRequested = true
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun releaseSecureFlag() {
        if (!holdingSecure) return
        holdingSecure = false
        if (secureRequested) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onWindowAttributesChanged(params: WindowManager.LayoutParams) {
        if (holdingSecure && params.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) {
            // Asked for during the capture: applied right after it.
            secureRequested = true
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_SECURE.inv()
        }
        super.onWindowAttributesChanged(params)
    }

    // ---------------------------------------------------------------------
    // Window
    // ---------------------------------------------------------------------

    override fun onStart() {
        super.onStart()
        started = true
    }

    override fun onStop() {
        super.onStop()
        started = false
        if (phase == Phase.DONE && !awaitingResult && !isChangingConfigurations && !isFinishing) {
            finish()
        }
    }

    override fun onDestroy() {
        main.removeCallbacks(watchdog)
        requestId?.let {
            ScreenCaptures.stopListening(it)
            ScreenCaptures.discard(it)
        }
        if (!screenshotTaken) (outcome as? ScreenCaptureOutcome.Captured)?.file?.delete()
        if (phase == Phase.CAPTURING && isFinishing) {
            stopService(Intent(this, ScreenCaptureService::class.java))
        }
        io.shutdown()
        super.onDestroy()
    }

    /** Draws into the display cutout too, so the screenshot fits the screen. */
    private fun drawUnderCutout() {
        val mode = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            else -> return
        }
        val attributes = window.attributes
        attributes.layoutInDisplayCutoutMode = mode
        window.attributes = attributes
    }

    private fun close() {
        if (!isFinishing) finish()
    }

    /** [text] for [MainActivity]'s translate tab, as plain shared text. */
    private fun textIntent(text: String): Intent =
        Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * [location] (`/settings/offline`) in [MainActivity], as the link
     * `mozhi://settings/offline`; null for anything but an absolute app
     * path.
     */
    private fun locationIntent(location: String): Intent? {
        if (!location.startsWith("/") || location.startsWith("//")) return null
        val link = Uri.parse("${MainActivity.DEEP_LINK_SCHEME}:/$location")
        if (MainActivity.deepLinkRoute(link) == null) return null
        return Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(link)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun newRequestId(): String = UUID.randomUUID().toString().replace("-", "")

    companion object {
        /** The Flutter route of the window (`AppRoutes.screenTranslate`). */
        const val ROUTE = "/screen-translate"

        /** See `ScreenTranslateHost.channelName`. */
        const val CHANNEL = "io.github.aimdi.mozhi/screen_translate"

        /**
         * Starts a screen translation; only Mozhi's own components can (the
         * activity is not exported). Used by the tile, the bubble and the
         * launcher shortcut (res/xml/shortcuts.xml, which names the action).
         */
        const val ACTION_TRANSLATE_SCREEN = "io.github.aimdi.mozhi.action.TRANSLATE_SCREEN"

        // `screenshot()` answers (`ScreenCaptureStatus` in Dart).
        const val STATUS_OK = "ok"
        const val STATUS_DECLINED = "declined"
        const val STATUS_FAILED = "failed"

        // Failure reasons of the window (the service has its own).
        const val REASON_UNSUPPORTED = "unsupported"
        const val REASON_SERVICE = "service"
        const val REASON_RESTORED = "restored"
        const val REASON_READ = "read"
        const val REASON_TAKEN = "taken"

        /** Largest screenshot side (tablets stay below it). */
        const val MAX_SIDE = 4096

        private const val REQUEST_CONSENT = 0x5c7e
        private const val KEY_REQUEST_ID = "screenTranslate.requestId"
        private const val KEY_AWAITING_CONSENT = "screenTranslate.awaitingConsent"
        private const val WATCHDOG_MILLIS = 15_000L

        /**
         * The intent of a new screen translation, in a task of its own that
         * replaces any earlier one (a window left in the background never
         * comes back with an old screenshot).
         */
        fun launchIntent(context: Context): Intent =
            Intent(context, ScreenTranslateActivity::class.java)
                .setAction(ACTION_TRANSLATE_SCREEN)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION,
                )
    }
}
