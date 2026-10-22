package io.github.aimdi.mozhi

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The translucent window of text selected in another app: "Translate with
 * Mozhi" (`ACTION_PROCESS_TEXT`) and, through the exported alias
 * [MainActivity.TRANSLATE_OFFLINE_ALIAS], "Translate offline". It shows only
 * the quick translate sheet above the calling app, which stays visible
 * around it, and closes when the sheet closes.
 *
 * Everything else is [MainActivity]'s: the selection reaches Dart on the
 * same channels (`lib/platform/shared_text_service.dart`), Replace answers
 * the caller through `returnResult`, and the privacy helpers work the same.
 * The differences:
 *
 * - The window is translucent (`@style/TransparentTheme`) and Flutter draws
 *   on a transparent surface ([getBackgroundMode]).
 * - Flutter starts at [ROUTE] (`AppRoutes.quickTranslate` in
 *   `lib/app/router.dart`), a transparent page; deep links are ignored.
 * - [CHANNEL] (`lib/quick_translate/quick_translate_host.dart`): `close()`
 *   finishes the window; `openInApp({text})` opens the text in
 *   [MainActivity]'s translate tab (as `ACTION_SEND`, like shared text) and
 *   `openInApp({location})` opens that location there (as the explicit link
 *   `mozhi://<location>`, see [MainActivity.deepLinkRoute]), then finishes.
 *
 * It runs a Flutter engine of its own (as MainActivity started for a
 * selection always did): one engine cannot be attached to two activities,
 * and the main window may be open in its own task meanwhile.
 */
class QuickTranslateActivity : MainActivity() {
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun getInitialRoute(): String = ROUTE

    override fun shouldHandleDeeplinking(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
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

    private fun close() {
        if (!isFinishing) finish()
    }

    /** [text] for [MainActivity]'s translate tab, as plain shared text. */
    private fun textIntent(text: String): Intent =
        Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)

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
    }

    companion object {
        /** The Flutter route of the window (`AppRoutes.quickTranslate`). */
        const val ROUTE = "/quick-translate"

        /** See `QuickTranslateHost.channelName`. */
        const val CHANNEL = "io.github.aimdi.mozhi/quick_translate"
    }
}
