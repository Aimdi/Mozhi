package io.github.aimdi.mozhi

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and hands text shared with the app to Dart
 * (`lib/platform/shared_text_service.dart`):
 *
 * - `ACTION_SEND` (text/plain) from the share sheet.
 * - `ACTION_PROCESS_TEXT` (text/plain) from the text selection toolbar
 *   ("Translate with Mozhi"). When the caller's text is editable, Dart may
 *   answer with `returnResult(text)` to replace the selection.
 *
 * Payloads are maps `{text: String, readOnly: Boolean, processText: Boolean}`.
 */
class MainActivity : FlutterActivity() {
    /** Text the activity was started with, until Dart asks for it once. */
    private var initialText: Map<String, Any>? = null

    /** Texts received while Dart is not listening yet. */
    private val pendingTexts = mutableListOf<Map<String, Any>>()

    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Only for a fresh start: neither a recreated activity nor a launch
        // from recents should translate the original text again.
        val flags = intent?.flags ?: 0
        val launchedFromHistory = (flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (savedInstanceState == null && !launchedFromHistory) {
            initialText = sharedTextOf(intent)
        }
        super.onCreate(savedInstanceState)
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
                        callingActivity == null -> result.error(
                            "no_request",
                            "The activity was not started for a result",
                            null,
                        )
                        else -> {
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
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedTextOf(intent) ?: return
        val sink = eventSink
        if (sink != null) {
            sink.success(text)
        } else {
            pendingTexts.add(text)
        }
    }

    private fun sharedTextOf(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                val readOnly = intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)
                if (text.isNullOrBlank()) null else payload(text, readOnly, processText = true)
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

    private companion object {
        const val METHOD_CHANNEL = "io.github.aimdi.mozhi/shared_text"
        const val EVENT_CHANNEL = "io.github.aimdi.mozhi/shared_text_events"
    }
}
