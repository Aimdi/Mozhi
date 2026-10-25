package io.github.aimdi.mozhi

import android.annotation.TargetApi
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/**
 * Pushes the phone's heat and battery saver to Dart
 * (`lib/platform/device_conditions.dart`) on the event channel [CHANNEL],
 * added to every Flutter engine of the app by
 * [MainActivity.configureFlutterEngine].
 *
 * While Dart listens, each event is `{thermal: Int, powerSave: Boolean}`:
 * `PowerManager.getCurrentThermalStatus()` (0 for none to 6 for shutdown,
 * -1 before Android 10) and `PowerManager.isPowerSaveMode`. One is sent
 * when Dart starts listening, then one on every change: a
 * [PowerManager.OnThermalStatusChangedListener] (Android 10, API 29, and
 * later) and a receiver of [PowerManager.ACTION_POWER_SAVE_MODE_CHANGED],
 * both registered only while Dart listens. Before Android 10 the thermal
 * status stays -1 and Dart keeps asking `thermalStatus()` on the privacy
 * channel as a fallback.
 */
class DeviceConditionsPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private var channel: EventChannel? = null
    private var context: Context? = null
    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    /** The thermal listener (an `Any` so this class loads before API 29). */
    private var thermalListener: Any? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = EventChannel(binding.binaryMessenger, CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopWatching()
        channel?.setStreamHandler(null)
        channel = null
        context = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stopWatching()
        sink = events
        val context = context ?: return
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        send()
        val saver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = send()
        }
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // A system broadcast still reaches a receiver other apps cannot.
                context.registerReceiver(saver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(saver, filter)
            }
            receiver = saver
        } catch (e: RuntimeException) {
            // No pushed battery saver changes: Dart asks again from time to time.
        }
        if (power != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            thermalListener = addThermalListener(power)
        }
    }

    override fun onCancel(arguments: Any?) = stopWatching()

    @TargetApi(Build.VERSION_CODES.Q)
    private fun addThermalListener(power: PowerManager): Any? {
        val listener = PowerManager.OnThermalStatusChangedListener { send() }
        return try {
            // Called on the main thread, where the sink must be used.
            power.addThermalStatusListener(listener)
            listener
        } catch (e: RuntimeException) {
            null
        }
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun removeThermalListener(power: PowerManager, listener: Any) {
        try {
            power.removeThermalStatusListener(
                listener as PowerManager.OnThermalStatusChangedListener,
            )
        } catch (e: RuntimeException) {
            // Already gone.
        }
    }

    private fun stopWatching() {
        val context = context
        receiver?.let {
            try {
                context?.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Not registered.
            }
        }
        receiver = null
        val listener = thermalListener
        if (listener != null && context != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (power != null) removeThermalListener(power, listener)
        }
        thermalListener = null
        sink = null
    }

    /** Sends the current conditions to Dart (main thread). */
    private fun send() {
        val sink = sink ?: return
        val power = context?.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val thermal = if (power != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            currentThermalStatus(power)
        } else {
            -1
        }
        sink.success(mapOf("thermal" to thermal, "powerSave" to (power?.isPowerSaveMode ?: false)))
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun currentThermalStatus(power: PowerManager): Int = power.currentThermalStatus

    companion object {
        const val CHANNEL = "io.github.aimdi.mozhi/device_conditions"
    }
}
