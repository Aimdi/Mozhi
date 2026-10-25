package io.github.aimdi.mozhi

import android.app.Activity
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Hosts the Flutter UI and hands text shared with the app to Dart
 * (`lib/platform/shared_text_service.dart`):
 *
 * - `ACTION_SEND` (text/plain) from the share sheet.
 * - `ACTION_PROCESS_TEXT` (text/plain) from the text selection toolbar
 *   ("Translate with Mozhi"). When the caller's text is editable, Dart may
 *   answer with `returnResult(text)` to replace the selection. The call is
 *   refused unless the current intent is that writable request and the
 *   activity was started for a result.
 * - `ACTION_PROCESS_TEXT` through the exported alias [TRANSLATE_OFFLINE_ALIAS]
 *   ("Translate offline", see [isTranslateOffline]): the same request, which
 *   Dart translates with the on-device engine only. Replace works the same.
 * - [ACTION_TRANSLATE_CLIPBOARD] from the Quick Settings tile
 *   ([TranslateTileService]), the home-screen widget ([MozhiWidgetProvider])
 *   and the "Translate clipboard" launcher shortcut. It is only honoured when
 *   it arrives through the non-exported alias [TRANSLATE_CLIPBOARD_ALIAS]
 *   (see [isTranslateClipboard]): this activity is exported, so any app could
 *   otherwise make Mozhi read, translate and save the clipboard.
 *
 * Payloads are maps `{text: String, readOnly: Boolean, processText: Boolean}`;
 * a selection that arrived through [TRANSLATE_OFFLINE_ALIAS] also carries
 * `action: "translateOffline"`. Clipboard requests are always sent on the
 * event channel, once the window has input focus (Android 10+ only lets the
 * focused app read the clipboard), as `{action: "translateClipboard"}` plus,
 * when the clipboard holds text, `text`/`readOnly: true`/`processText: false`. Readers that
 * ignore `action` therefore treat clipboard text like shared text, and an
 * empty clipboard (no `text`) is ignored.
 *
 * Privacy helpers on [PRIVACY_CHANNEL] (`lib/platform/privacy_channel.dart`):
 * `setSecureScreen(Boolean)` sets or clears `FLAG_SECURE` (no content in
 * recents, no screenshots), and `copySensitiveText(String)` copies text marked
 * `EXTRA_IS_SENSITIVE` on Android 13+ (answering true) and answers false
 * without copying on older versions (Dart then uses `Clipboard.setData`).
 * `isActiveNetworkMetered()` answers whether the active network is metered
 * (`lib/platform/metered_network.dart`: Wi-Fi-only offline model downloads).
 * `setKeepScreenOn(Boolean)` sets or clears `FLAG_KEEP_SCREEN_ON`
 * (`lib/transcribe/data/screen_awake.dart`: while Transcribe listens).
 * `thermalStatus()` answers `PowerManager.getCurrentThermalStatus()` (-1
 * before Android 10) and `isPowerSaveMode()` whether battery saver is on
 * (`lib/platform/device_conditions.dart`: on-device AI waits for the Enter
 * key while the phone is hot or saving battery).
 *
 * [MEMORY_CHANNEL] (`lib/platform/native_memory.dart`): `memoryInfo()` answers
 * what [ActivityManager] says about memory (see [memoryInfo]), which sizes the
 * on-device engines' model caches. Memory pressure needs nothing here: Flutter
 * forwards `onTrimMemory` to Dart (`didHaveMemoryPressure`).
 *
 * Deep links `mozhi://<screen>[/<path>][?<query>][#<fragment>]` are handed to
 * the Flutter router as the plain route `/<screen>[/<path>][?<query>]...`
 * (see [deepLinkRoute]), e.g. `mozhi://image` -> `/image` and
 * `mozhi://translate?text=hola&from=es&to=en` -> `/translate?text=hola&from=es&to=en`.
 *
 * Open for [QuickTranslateActivity], the translucent window of text
 * selections, which shares all of the above.
 */
open class MainActivity : FlutterActivity() {
    /** Text the activity was started with, until Dart asks for it once. */
    private var initialText: Map<String, Any>? = null

    /** Texts received while Dart is not listening yet. */
    private val pendingTexts = mutableListOf<Map<String, Any>>()

    private var eventSink: EventChannel.EventSink? = null

    /**
     * Whether the launch intent should be acted upon: false for a recreated
     * activity and for a launch from recents, which replay the original
     * intent (its text, clipboard request or deep link) a second time.
     */
    private var freshStart = false

    /** A clipboard request waiting for the window to gain input focus. */
    private var clipboardRequested = false

    /**
     * Whether the current intent is a writable `ACTION_PROCESS_TEXT` request
     * (`EXTRA_PROCESS_TEXT_READONLY` false) that `returnResult` may answer.
     * Updated for every intent in [onCreate] and [onNewIntent], so a share,
     * deep link or clipboard request arriving later clears it and a stale
     * `callingActivity` can never receive text. Cleared once answered.
     */
    private var writableProcessTextPending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        val flags = intent?.flags ?: 0
        val launchedFromHistory = (flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        freshStart = savedInstanceState == null && !launchedFromHistory
        writableProcessTextPending = isWritableProcessText(intent)
        if (freshStart) {
            initialText = sharedTextOf(intent)
            clipboardRequested = isTranslateClipboard(intent)
        }
        super.onCreate(savedInstanceState)
    }

    /**
     * Initial route for a cold start from a `mozhi://` deep link. Returning
     * null lets Flutter fall back to its defaults (`/` for normal launches).
     */
    override fun getInitialRoute(): String? {
        super.getInitialRoute()?.let { return it }
        val route = deepLinkRoute(intent?.data) ?: return null
        return if (freshStart) route else DEFAULT_ROUTE
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = initialText
                    initialText = null
                    result.success(text)
                }
                "returnResult" -> {
                    val text = call.arguments as? String
                    when {
                        text == null -> result.error(
                            "invalid_argument",
                            "returnResult expects the replacement text",
                            null,
                        )
                        // Only a writable PROCESS_TEXT request started for a
                        // result may be answered; anything else is refused
                        // (Dart ignores the error) without touching the
                        // activity result.
                        !writableProcessTextPending || callingActivity == null -> result.error(
                            "no_request",
                            "No writable PROCESS_TEXT request to answer",
                            null,
                        )
                        else -> {
                            writableProcessTextPending = false
                            setResult(
                                Activity.RESULT_OK,
                                Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, text),
                            )
                            result.success(null)
                            finish()
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureScreen" -> {
                    val enabled = call.arguments as? Boolean
                    if (enabled == null) {
                        result.error("invalid_argument", "setSecureScreen expects a Boolean", null)
                    } else {
                        setSecureScreen(enabled)
                        result.success(null)
                    }
                }
                "copySensitiveText" -> {
                    val text = call.arguments as? String
                    if (text == null) {
                        result.error("invalid_argument", "copySensitiveText expects the text", null)
                    } else {
                        result.success(copySensitiveText(text))
                    }
                }
                "setKeepScreenOn" -> {
                    val on = call.arguments as? Boolean
                    if (on == null) {
                        result.error("invalid_argument", "setKeepScreenOn expects a Boolean", null)
                    } else {
                        // Transcribe keeps the screen on while it listens.
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                }
                "isActiveNetworkMetered" -> result.success(isActiveNetworkMetered())
                // The API level: below 29 the app is not drawn edge to edge
                // and needs an opaque navigation bar (system_bars.dart).
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                // Heat and battery saver (device_conditions.dart).
                "thermalStatus" -> result.success(thermalStatus())
                "isPowerSaveMode" -> result.success(isPowerSaveMode())
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, MEMORY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "memoryInfo" -> result.success(memoryInfo())
                else -> result.notImplemented()
            }
        }

        // Translate screen: the bubble and tile settings (ScreenTranslatePlugin.kt).
        flutterEngine.plugins.add(ScreenTranslatePlugin())

        // App lock: the unlock prompt and the shared lock state (AppLockPlugin.kt).
        flutterEngine.plugins.add(AppLockPlugin())

        // On-device models: free space and imports without a cache copy
        // (DeviceStoragePlugin.kt); pushed heat and battery saver changes
        // (DeviceConditionsPlugin.kt).
        flutterEngine.plugins.add(DeviceStoragePlugin())
        flutterEngine.plugins.add(DeviceConditionsPlugin())

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                    pendingTexts.forEach { events.success(it) }
                    pendingTexts.clear()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        eventSink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        // Flutter pushes the intent's data URI to the router; give it the
        // rewritten route instead of the raw mozhi:// link.
        super.onNewIntent(withDeepLinkRoute(intent))
        setIntent(intent)
        writableProcessTextPending = isWritableProcessText(intent)
        if (isTranslateClipboard(intent)) {
            requestClipboard()
            return
        }
        val text = sharedTextOf(intent) ?: return
        send(text)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && clipboardRequested) {
            clipboardRequested = false
            send(clipboardPayload())
        }
    }

    /**
     * Sets or clears `FLAG_SECURE` on this activity's window for the setting;
     * the app lock may keep it on (below Android 13, [AppLockPlugin.setSecureFlag]).
     */
    private fun setSecureScreen(enabled: Boolean) {
        AppLockPlugin.setSecureFlag(this, AppLockPlugin.SECURE_SETTING, enabled)
    }

    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        // The camera or a file picker opened by Mozhi is part of using it
        // (AppLockPlugin.kt); plain startActivity calls pass -1.
        if (requestCode >= 0) AppLockPlugin.noteActivityStartedForResult()
        super.startActivityForResult(intent, requestCode, options)
    }

    /**
     * Puts [text] on the clipboard marked as sensitive, so the system's copy
     * confirmation and keyboard suggestions hide it. Only on Android 13+ (API
     * 33, where the extra exists and the system confirms copies itself);
     * returns false without copying on older versions.
     */
    private fun copySensitiveText(text: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return false
        val clip = ClipData.newPlainText("", text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        }
        clipboard.setPrimaryClip(clip)
        return true
    }

    /**
     * `PowerManager.getCurrentThermalStatus()`: 0 (none) to 6 (shutdown), see
     * `PowerManager.THERMAL_STATUS_*`. -1 before Android 10 (API 29) or when
     * the service is missing.
     */
    private fun thermalStatus(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return -1
        return power.currentThermalStatus
    }

    /** Whether battery saver is on (`PowerManager.isPowerSaveMode`). */
    private fun isPowerSaveMode(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return power.isPowerSaveMode
    }

    /**
     * Whether the active network is metered (mobile data, a hotspot, a Wi-Fi
     * network marked as metered), via
     * `ConnectivityManager.isActiveNetworkMetered()` (ACCESS_NETWORK_STATE).
     * True when there is no network or the system refuses to tell, so a
     * Wi-Fi-only download never uses mobile data by mistake.
     */
    private fun isActiveNetworkMetered(): Boolean {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        return try {
            connectivity.isActiveNetworkMetered
        } catch (e: SecurityException) {
            true
        }
    }

    /**
     * The device's memory as [ActivityManager] reports it: `memoryClass` and
     * `largeMemoryClass` (the app's heap budget in MB), `totalMem` (bytes of
     * RAM) and `lowRam` (`isLowRamDevice`). Empty when the service is missing.
     */
    private fun memoryInfo(): Map<String, Any> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyMap()
        val info = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(info)
        return mapOf(
            "memoryClass" to activityManager.memoryClass,
            "largeMemoryClass" to activityManager.largeMemoryClass,
            "totalMem" to info.totalMem,
            "lowRam" to activityManager.isLowRamDevice,
        )
    }

    /** Sends [payload] on the event channel, or queues it until Dart listens. */
    private fun send(payload: Map<String, Any>) {
        val sink = eventSink
        if (sink != null) {
            sink.success(payload)
        } else {
            pendingTexts.add(payload)
        }
    }

    private fun requestClipboard() {
        if (hasWindowFocus()) {
            clipboardRequested = false
            send(clipboardPayload())
        } else {
            // Typically the tile's notification shade still has focus; the
            // request is answered in onWindowFocusChanged.
            clipboardRequested = true
        }
    }

    private fun clipboardPayload(): Map<String, Any> {
        val text = clipboardText()
        val action = KEY_ACTION to ACTION_VALUE_TRANSLATE_CLIPBOARD
        return if (text.isNullOrBlank()) {
            mapOf(action)
        } else {
            payload(text, readOnly = true, processText = false) + action
        }
    }

    private fun clipboardText(): String? = try {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clip = clipboard?.primaryClip
        if (clip == null || clip.itemCount == 0) {
            null
        } else {
            clip.getItemAt(0).coerceToText(this)?.toString()
        }
    } catch (e: SecurityException) {
        // Not focused after all (Android 10+); Dart may retry on its own.
        null
    }

    private fun sharedTextOf(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                val readOnly = isProcessTextReadOnly(intent)
                when {
                    text.isNullOrBlank() -> null
                    isTranslateOffline(intent) ->
                        payload(text, readOnly, processText = true) +
                            (KEY_ACTION to ACTION_VALUE_TRANSLATE_OFFLINE)
                    else -> payload(text, readOnly, processText = true)
                }
            }
            Intent.ACTION_SEND -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                when {
                    intent.type?.startsWith("text/") != true -> null
                    text.isNullOrBlank() -> null
                    else -> payload(text, readOnly = true, processText = false)
                }
            }
            else -> null
        }
    }

    private fun payload(text: String, readOnly: Boolean, processText: Boolean): Map<String, Any> =
        mapOf("text" to text, "readOnly" to readOnly, "processText" to processText)

    /**
     * Whether [intent] is a clipboard request from Mozhi itself: the action
     * [ACTION_TRANSLATE_CLIPBOARD] sent to the non-exported alias
     * [TRANSLATE_CLIPBOARD_ALIAS]. Other apps can only reach the exported
     * MainActivity component (the system refuses them the alias), so the
     * same action sent there is ignored and the app just opens.
     */
    private fun isTranslateClipboard(intent: Intent?): Boolean =
        intent != null &&
            intent.action == ACTION_TRANSLATE_CLIPBOARD &&
            intent.component?.let {
                it.packageName == packageName && it.className == TRANSLATE_CLIPBOARD_ALIAS
            } == true

    /**
     * Whether [intent] arrived through the exported alias
     * [TRANSLATE_OFFLINE_ALIAS] ("Translate offline" in the text selection
     * toolbar), whose selection Dart translates on the device only. Any app
     * may start the alias directly; that can only make a request more
     * private, so unlike [isTranslateClipboard] it needs no protection.
     */
    private fun isTranslateOffline(intent: Intent?): Boolean =
        intent?.component?.let {
            it.packageName == packageName && it.className == TRANSLATE_OFFLINE_ALIAS
        } == true

    /**
     * The `readOnly` flag sent to Dart for a PROCESS_TEXT [intent]. A missing
     * extra means editable, as in the platform's own text views.
     */
    private fun isProcessTextReadOnly(intent: Intent): Boolean =
        intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)

    /** Whether [intent] is a PROCESS_TEXT request whose text may be replaced. */
    private fun isWritableProcessText(intent: Intent?): Boolean =
        intent != null &&
            intent.action == Intent.ACTION_PROCESS_TEXT &&
            !isProcessTextReadOnly(intent)

    /** [intent] with its `mozhi://` data replaced by the route, if it has one. */
    private fun withDeepLinkRoute(intent: Intent): Intent {
        val route = deepLinkRoute(intent.data) ?: return intent
        return Intent(intent).setData(Uri.parse(route))
    }

    companion object {
        /**
         * Opens Mozhi and translates the clipboard. Used by the Quick Settings
         * tile, the widget and the static launcher shortcut
         * (res/xml/shortcuts.xml), always through [TRANSLATE_CLIPBOARD_ALIAS].
         */
        const val ACTION_TRANSLATE_CLIPBOARD = "io.github.aimdi.mozhi.action.TRANSLATE_CLIPBOARD"

        /**
         * Class name of the non-exported `<activity-alias>` of this activity
         * (AndroidManifest.xml) that [ACTION_TRANSLATE_CLIPBOARD] must be sent
         * to. Class names follow the namespace, not the flavour's
         * applicationId, so this is the same for every flavour.
         */
        const val TRANSLATE_CLIPBOARD_ALIAS = "io.github.aimdi.mozhi.TranslateClipboardActivity"

        /**
         * Class name of the exported `<activity-alias>` of this activity
         * (AndroidManifest.xml) behind the "Translate offline" text selection
         * action (see [isTranslateOffline]). Like
         * [TRANSLATE_CLIPBOARD_ALIAS], the same for every flavour.
         */
        const val TRANSLATE_OFFLINE_ALIAS = "io.github.aimdi.mozhi.TranslateOfflineActivity"

        /** Scheme of the deep links handled by [deepLinkRoute]. */
        const val DEEP_LINK_SCHEME = "mozhi"

        private const val METHOD_CHANNEL = "io.github.aimdi.mozhi/shared_text"
        private const val EVENT_CHANNEL = "io.github.aimdi.mozhi/shared_text_events"
        private const val PRIVACY_CHANNEL = "io.github.aimdi.mozhi/privacy"
        private const val MEMORY_CHANNEL = "io.github.aimdi.mozhi/memory"
        private const val KEY_ACTION = "action"
        private const val ACTION_VALUE_TRANSLATE_CLIPBOARD = "translateClipboard"
        private const val ACTION_VALUE_TRANSLATE_OFFLINE = "translateOffline"
        private const val DEFAULT_ROUTE = "/"

        /**
         * Intent that brings Mozhi to the front to translate the clipboard
         * (explicit, to [TRANSLATE_CLIPBOARD_ALIAS] in this app's package).
         */
        fun translateClipboardIntent(context: Context): Intent =
            Intent()
                .setClassName(context, TRANSLATE_CLIPBOARD_ALIAS)
                .setAction(ACTION_TRANSLATE_CLIPBOARD)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )

        /**
         * Maps `mozhi://<host>[<path>][?<query>][#<fragment>]` to the router
         * location `/<host>[<path>][?<query>][#<fragment>]`, keeping the
         * percent-encoding of path, query and fragment. The host (the screen)
         * is lower-cased. `mozhi:///<path>` (no host) maps to `/<path>`.
         * Returns null for any other URI.
         */
        fun deepLinkRoute(uri: Uri?): String? {
            if (uri == null || !DEEP_LINK_SCHEME.equals(uri.scheme, ignoreCase = true)) return null
            val route = StringBuilder()
            val host = uri.host?.lowercase(Locale.ROOT).orEmpty()
            if (host.isNotEmpty()) route.append('/').append(host)
            val path = uri.encodedPath.orEmpty()
            if (path.isNotEmpty() && !path.startsWith("/")) route.append('/')
            route.append(path)
            if (route.isEmpty()) route.append(DEFAULT_ROUTE)
            uri.encodedQuery?.takeIf { it.isNotEmpty() }?.let { route.append('?').append(it) }
            uri.encodedFragment?.takeIf { it.isNotEmpty() }?.let { route.append('#').append(it) }
            return route.toString()
        }
    }
}
