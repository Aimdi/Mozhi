package io.github.aimdi.mozhi

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's opt-in [NotificationTranslateService] to Dart over
 * `io.github.aimdi.mozhi/notification_translate` (methods) and
 * `io.github.aimdi.mozhi/notification_translate/events` (incoming text stream).
 */
class NotificationTranslatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("detached", "Plugin is not attached", null)
            return
        }
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "hasAccess" to hasNotificationAccess(ctx),
                    "enabled" to NotificationTranslateService.isEnabled(ctx),
                ),
            )
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                NotificationTranslateService.setEnabled(ctx, enabled)
                result.success(null)
            }
            "openAccessSettings" -> {
                val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                try {
                    ctx.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "postTranslation" -> {
                val id = call.argument<Number>("id")?.toInt() ?: 0
                val title = call.argument<String>("title").orEmpty()
                val translation = call.argument<String>("translation").orEmpty()
                NotificationTranslateService.postTranslation(ctx, id, title, translation)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasNotificationAccess(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        val expected = ComponentName(context, NotificationTranslateService::class.java)
            .flattenToString()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    companion object {
        const val CHANNEL = "io.github.aimdi.mozhi/notification_translate"
        const val EVENTS_CHANNEL = "io.github.aimdi.mozhi/notification_translate/events"

        @Volatile
        private var eventSink: EventChannel.EventSink? = null
        private val main = Handler(Looper.getMainLooper())

        fun emitNotification(payload: Map<String, Any>) {
            main.post {
                eventSink?.success(payload)
            }
        }
    }
}
