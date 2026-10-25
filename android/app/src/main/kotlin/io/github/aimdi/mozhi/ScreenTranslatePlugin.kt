package io.github.aimdi.mozhi

import android.Manifest
import android.app.Activity
import android.app.StatusBarManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The settings of "Translate screen" and the bubble
 * (`lib/screen_translate/data/screen_translate_controls.dart`), on
 * [CHANNEL] in every window (registered by [MainActivity]):
 *
 * - `status()`: `{bubbleRunning, canDrawOverlays, notificationsAllowed,
 *   canAddTile}`.
 * - `requestOverlayPermission()`: opens Android's "Display over other apps"
 *   page for Mozhi; answers whether it is allowed once the user is back.
 * - `requestNotificationPermission()`: asks for notifications on Android
 *   13+ (for the bubble's notification and its Stop action); true when
 *   allowed or not needed.
 * - `startBubble()`: starts [TranslateBubbleService]; false without
 *   "Display over other apps". `stopBubble()` stops it.
 * - `requestAddTile()`: offers the "Translate screen" tile for Quick
 *   Settings (Android 13+, `StatusBarManager.requestAddTileService`):
 *   `added`, `alreadyAdded`, `notAdded`, `unsupported` or `failed`.
 */
class ScreenTranslatePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null
    private var overlayCall: MethodChannel.Result? = null
    private var notificationCall: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        overlayCall?.success(false)
        overlayCall = null
        notificationCall?.success(false)
        notificationCall = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context
        if (context == null) {
            result.error("unavailable", "Not attached", null)
            return
        }
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "bubbleRunning" to TranslateBubbleService.isRunning,
                    "canDrawOverlays" to Settings.canDrawOverlays(context),
                    "notificationsAllowed" to notificationsAllowed(context),
                    "canAddTile" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU),
                ),
            )
            "requestOverlayPermission" -> requestOverlayPermission(context, result)
            "requestNotificationPermission" -> requestNotificationPermission(context, result)
            "startBubble" -> {
                if (!Settings.canDrawOverlays(context)) {
                    result.success(false)
                    return
                }
                try {
                    TranslateBubbleService.start(context)
                    result.success(true)
                } catch (e: IllegalStateException) {
                    result.success(false)
                } catch (e: SecurityException) {
                    result.success(false)
                }
            }
            "stopBubble" -> {
                TranslateBubbleService.stop(context)
                result.success(null)
            }
            "requestAddTile" -> requestAddTile(context, result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // Display over other apps
    // ---------------------------------------------------------------------

    private fun requestOverlayPermission(context: Context, result: MethodChannel.Result) {
        if (Settings.canDrawOverlays(context)) {
            result.success(true)
            return
        }
        val activity = binding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        overlayCall?.success(false)
        overlayCall = result
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}"),
        )
        try {
            activity.startActivityForResult(intent, REQUEST_OVERLAY)
        } catch (e: ActivityNotFoundException) {
            overlayCall = null
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OVERLAY) return false
        val call = overlayCall ?: return true
        overlayCall = null
        val context = context
        if (context == null) {
            call.success(false)
            return true
        }
        if (Settings.canDrawOverlays(context)) {
            call.success(true)
        } else {
            // Android 8 reports a fresh grant a moment late.
            main.postDelayed({ call.success(Settings.canDrawOverlays(context)) }, RECHECK_MILLIS)
        }
        return true
    }

    // ---------------------------------------------------------------------
    // Notifications
    // ---------------------------------------------------------------------

    private fun notificationsAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission(context: Context, result: MethodChannel.Result) {
        if (notificationsAllowed(context) || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val activity: Activity? = binding?.activity
        if (activity == null) {
            result.success(false)
            return
        }
        notificationCall?.success(false)
        notificationCall = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val call = notificationCall ?: return true
        notificationCall = null
        call.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        return true
    }

    // ---------------------------------------------------------------------
    // Quick Settings tile
    // ---------------------------------------------------------------------

    private fun requestAddTile(context: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(TILE_UNSUPPORTED)
            return
        }
        val statusBar = context.getSystemService(StatusBarManager::class.java)
        if (statusBar == null) {
            result.success(TILE_UNSUPPORTED)
            return
        }
        var answered = false
        fun answer(value: String) {
            if (answered) return
            answered = true
            result.success(value)
        }
        try {
            statusBar.requestAddTileService(
                ComponentName(context, TranslateScreenTileService::class.java),
                context.getString(R.string.tile_translate_screen_label),
                Icon.createWithResource(context, R.drawable.ic_tile_translate_screen),
                context.mainExecutor,
            ) { code ->
                answer(
                    when (code) {
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> TILE_ADDED
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> TILE_ALREADY_ADDED
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> TILE_NOT_ADDED
                        else -> TILE_FAILED
                    },
                )
            }
        } catch (e: IllegalArgumentException) {
            answer(TILE_FAILED)
        } catch (e: SecurityException) {
            answer(TILE_FAILED)
        }
    }

    companion object {
        /** See `ScreenTranslateControls.channelName`. */
        const val CHANNEL = "io.github.aimdi.mozhi/screen_translate_controls"

        const val TILE_ADDED = "added"
        const val TILE_ALREADY_ADDED = "alreadyAdded"
        const val TILE_NOT_ADDED = "notAdded"
        const val TILE_UNSUPPORTED = "unsupported"
        const val TILE_FAILED = "failed"

        private const val REQUEST_OVERLAY = 0x5c80
        private const val REQUEST_NOTIFICATIONS = 0x5c81
        private const val RECHECK_MILLIS = 500L
    }
}
