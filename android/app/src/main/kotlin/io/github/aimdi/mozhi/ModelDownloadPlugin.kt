package io.github.aimdi.mozhi

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `io.github.aimdi.mozhi/model_downloads` bridging Dart's
 * `DownloadForegroundCoordinator` to [ModelDownloadService].
 */
class ModelDownloadPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler(this)
        channel = methodChannel
        activeChannel = methodChannel
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        if (activeChannel === channel) activeChannel = null
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.success(null)
            return
        }
        when (call.method) {
            "start", "update" -> {
                val title = call.argument<String>("title").orEmpty()
                val progress = call.argument<Number>("progress")?.toInt()
                ModelDownloadService.startOrUpdate(ctx, title, progress)
                result.success(null)
            }
            "stop" -> {
                ModelDownloadService.stop(ctx)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "io.github.aimdi.mozhi/model_downloads"

        @Volatile
        private var activeChannel: MethodChannel? = null
        private val main = Handler(Looper.getMainLooper())

        fun notifyCancelled() {
            main.post {
                activeChannel?.invokeMethod("cancel", null)
            }
        }
    }
}
