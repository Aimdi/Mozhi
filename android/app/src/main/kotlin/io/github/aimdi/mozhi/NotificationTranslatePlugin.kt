package io.github.aimdi.mozhi

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Bridges Android's opt-in [NotificationTranslateService] to Dart over
 * `io.github.aimdi.mozhi/notification_translate` (methods) and
 * `io.github.aimdi.mozhi/notification_translate/events` (incoming text stream).
 */
class NotificationTranslatePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var notificationPermissionCall: MethodChannel.Result? = null

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

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        notificationPermissionCall?.success(false)
        notificationPermissionCall = null
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
                    "notificationsAllowed" to notificationsAllowed(ctx),
                    "mutedPackages" to NotificationTranslateService.mutedPackages(ctx).sorted(),
                    "targetLanguage" to NotificationTranslateService.targetLanguage(ctx),
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
            "requestNotificationPermission" -> requestNotificationPermission(ctx, result)
            "mutedPackages" -> result.success(
                NotificationTranslateService.mutedPackages(ctx).sorted(),
            )
            "setPackageMuted" -> {
                val packageName = call.argument<String>("packageName").orEmpty()
                val muted = call.argument<Boolean>("muted") ?: false
                NotificationTranslateService.setPackageMuted(ctx, packageName, muted)
                result.success(null)
            }
            "setTargetLanguage" -> {
                val code = call.argument<String>("code")
                NotificationTranslateService.setTargetLanguage(ctx, code)
                result.success(null)
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

    private fun notificationsAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission(context: Context, result: MethodChannel.Result) {
        if (notificationsAllowed(context) || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val activity: Activity? = activityBinding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        notificationPermissionCall?.success(false)
        notificationPermissionCall = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val call = notificationPermissionCall ?: return true
        notificationPermissionCall = null
        call.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        return true
    }

    companion object {
        const val CHANNEL = "io.github.aimdi.mozhi/notification_translate"
        const val EVENTS_CHANNEL = "io.github.aimdi.mozhi/notification_translate/events"
        private const val REQUEST_NOTIFICATIONS = 0x5c82

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
