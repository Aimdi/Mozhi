package io.github.aimdi.mozhi

import android.Manifest
import android.annotation.TargetApi
import android.app.Activity
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.ImageReader
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.Settings
import android.util.Size
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The live camera's platform side (`lib/live_camera/data/
 * method_channel_live_camera_controller.dart`), method channel [CHANNEL],
 * added to every Flutter engine of the app by
 * [MainActivity.configureFlutterEngine]. Framework Camera2 only: no CameraX,
 * no androidx, no Google code.
 *
 * - `requestAccess()` answers `granted`, `denied` or `blocked` (denied with
 *   "Don't ask again", or by a policy: Android shows no dialog any more, so
 *   Dart offers the app's settings). The framework's
 *   [Activity.requestPermissions] asks for [Manifest.permission.CAMERA].
 * - `start()` opens the back camera (an external one when there is no back
 *   camera) with three outputs of one aspect ratio (16:9, else 4:3): the
 *   preview on a [TextureRegistry] `SurfaceTexture` (at most 1920 x 1080),
 *   an [ImageReader] of `YUV_420_888` frames for text recognition (at most
 *   1280 x 960) and a JPEG [ImageReader] for the still (at most 8
 *   megapixels). Continuous autofocus. Answers `{textureId, previewWidth,
 *   previewHeight, rotation, analysisWidth, analysisHeight, hasTorch,
 *   minZoom, maxZoom}`; `rotation` is the sensor orientation (the preview
 *   texture is upright in the device's natural orientation; Dart turns it
 *   with the display).
 * - `nextFrame()` answers the next frame's grey Y plane, copied only now
 *   (frames nobody asked for are closed at once, uncopied): `{pixels,
 *   width, height, bytesPerRow, rotationDegrees, timestamp}` (rotation:
 *   clockwise degrees to be upright on the screen as it is turned now;
 *   timestamp in microseconds), or null once the camera stopped. Frames are
 *   never written anywhere.
 * - `setTorch({on})`, `setZoom({ratio})`: `CONTROL_ZOOM_RATIO` on Android
 *   11+ (API 30), a centred `SCALER_CROP_REGION` before.
 * - `takePicture()` answers one JPEG (upright through `JPEG_ORIENTATION`),
 *   or null when the camera is not running. Nothing is saved: the bytes go
 *   to Dart only.
 * - `stop()` closes the session, the camera, the readers, the surfaces, the
 *   texture and the camera thread. The camera also stops by itself when the
 *   activity stops (it is never used in the background), when it detaches
 *   and when the engine goes. `openAppSettings()` opens the app's page in
 *   Android's settings; `displayRotation()` answers the display's rotation
 *   in degrees.
 *
 * Errors are `PlatformException` codes [ERROR_NO_CAMERA],
 * [ERROR_PERMISSION], [ERROR_IN_USE], [ERROR_DISABLED], [ERROR_BACKGROUND]
 * and [ERROR_FAILED].
 */
class LiveCameraPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var textures: TextureRegistry? = null
    private var binding: ActivityPluginBinding? = null
    private var lifecycle: Application.ActivityLifecycleCallbacks? = null
    private var accessCall: MethodChannel.Result? = null
    private var camera: LiveCameraSession? = null

    /** Whether the activity is started (the camera is never opened otherwise). */
    private var visible = true

    override fun onAttachedToEngine(pluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = pluginBinding.applicationContext
        textures = pluginBinding.textureRegistry
        channel = MethodChannel(pluginBinding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(pluginBinding: FlutterPlugin.FlutterPluginBinding) {
        stopCamera()
        channel?.setMethodCallHandler(null)
        channel = null
        textures = null
        context = null
    }

    override fun onAttachedToActivity(activityBinding: ActivityPluginBinding) =
        attach(activityBinding)

    override fun onReattachedToActivityForConfigChanges(activityBinding: ActivityPluginBinding) =
        attach(activityBinding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(activityBinding: ActivityPluginBinding) {
        binding = activityBinding
        visible = true
        activityBinding.addRequestPermissionsResultListener(this)
        val activity = activityBinding.activity
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(started: Activity) {
                if (started === activity) visible = true
            }

            override fun onActivityStopped(stopped: Activity) {
                // The camera is never kept in the background.
                if (stopped !== activity) return
                visible = false
                stopCamera()
            }

            override fun onActivityCreated(created: Activity, state: Bundle?) = Unit
            override fun onActivityResumed(resumed: Activity) = Unit
            override fun onActivityPaused(paused: Activity) = Unit
            override fun onActivitySaveInstanceState(saved: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(destroyed: Activity) = Unit
        }
        activity.application.registerActivityLifecycleCallbacks(callbacks)
        lifecycle = callbacks
    }

    private fun detach() {
        val activityBinding = binding
        activityBinding?.removeRequestPermissionsResultListener(this)
        lifecycle?.let { activityBinding?.activity?.application?.unregisterActivityLifecycleCallbacks(it) }
        lifecycle = null
        binding = null
        stopCamera()
        accessCall?.success(ACCESS_DENIED)
        accessCall = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestAccess" -> requestAccess(result)
            "start" -> startCamera(result)
            "nextFrame" -> {
                val running = camera
                if (running == null) result.success(null) else running.nextFrame(result, displayDegrees())
            }
            "setTorch" -> {
                val on = call.argument<Boolean>("on")
                val running = camera
                when {
                    on == null -> result.error(ERROR_ARGUMENT, "setTorch expects on", null)
                    running == null -> result.success(false)
                    else -> running.setTorch(on, result)
                }
            }
            "setZoom" -> {
                val ratio = call.argument<Number>("ratio")?.toFloat()
                val running = camera
                when {
                    ratio == null || ratio.isNaN() -> result.error(ERROR_ARGUMENT, "setZoom expects ratio", null)
                    running == null -> result.success(1.0)
                    else -> running.setZoom(ratio, result)
                }
            }
            "takePicture" -> {
                val running = camera
                if (running == null) result.success(null) else running.takePicture(result, displayDegrees())
            }
            "stop" -> {
                stopCamera()
                result.success(null)
            }
            "openAppSettings" -> result.success(openAppSettings())
            "displayRotation" -> result.success(displayDegrees())
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // Permission
    // ---------------------------------------------------------------------

    private fun granted(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestAccess(result: MethodChannel.Result) {
        val context = context
        if (context != null && granted(context)) {
            result.success(ACCESS_GRANTED)
            return
        }
        val activity = binding?.activity
        if (activity == null) {
            result.success(ACCESS_DENIED)
            return
        }
        accessCall?.success(ACCESS_DENIED)
        accessCall = result
        activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CAMERA) return false
        val call = accessCall ?: return true
        accessCall = null
        val answer = when {
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED ->
                ACCESS_GRANTED
            // Android asks no more ("Don't ask again", or a policy): only the
            // app's settings can grant it now.
            binding?.activity?.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) == false ->
                ACCESS_BLOCKED
            else -> ACCESS_DENIED
        }
        call.success(answer)
        return true
    }

    private fun openAppSettings(): Boolean {
        val context = context ?: return false
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        )
        val activity = binding?.activity
        return try {
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    // ---------------------------------------------------------------------
    // Camera
    // ---------------------------------------------------------------------

    private fun startCamera(result: MethodChannel.Result) {
        val context = context
        val textures = textures
        if (context == null || textures == null) {
            result.error(ERROR_FAILED, "Not attached", null)
            return
        }
        if (!visible) {
            result.error(ERROR_BACKGROUND, "The app is in the background", null)
            return
        }
        if (!granted(context)) {
            result.error(ERROR_PERMISSION, "Camera permission not granted", null)
            return
        }
        stopCamera()
        val session = LiveCameraSession(context, textures, main)
        camera = session
        session.start(result)
    }

    private fun stopCamera() {
        val session = camera ?: return
        camera = null
        session.close()
    }

    /** The display's rotation in degrees (0, 90, 180 or 270). */
    private fun displayDegrees(): Int {
        val activity = binding?.activity ?: return 0
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            displayRotation(activity)
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }
        return when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun displayRotation(activity: Activity): Int =
        activity.display?.rotation ?: Surface.ROTATION_0

    companion object {
        const val CHANNEL = "mozhi/live_camera"

        const val ACCESS_GRANTED = "granted"
        const val ACCESS_DENIED = "denied"
        const val ACCESS_BLOCKED = "blocked"

        const val ERROR_NO_CAMERA = "no_camera"
        const val ERROR_PERMISSION = "permission"
        const val ERROR_IN_USE = "in_use"
        const val ERROR_DISABLED = "disabled"
        const val ERROR_BACKGROUND = "background"
        const val ERROR_FAILED = "failed"
        const val ERROR_ARGUMENT = "invalid_argument"
        const val ERROR_BUSY = "busy"

        private const val REQUEST_CAMERA = 0x4c43 // "LC"
    }
}

/**
 * One opening of the camera: the device, its capture session, the readers,
 * the preview texture and a camera thread of its own. Calls arrive on the
 * main thread; camera callbacks run on the camera thread; every answer to
 * Dart is posted to the main thread. [close] releases all of it, once.
 */
private class LiveCameraSession(
    private val context: Context,
    private val textures: TextureRegistry,
    private val main: Handler,
) {
    private val thread = HandlerThread("MozhiLiveCamera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private val lock = Any()

    // Main thread.
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    private var startCall: MethodChannel.Result? = null

    // Camera thread (set up on the main thread before the camera opens).
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewSurface: Surface? = null
    private var analysis: ImageReader? = null
    private var still: ImageReader? = null
    private var sensorOrientation = 90
    private var hasTorch = false
    private var minZoom = 1f
    private var maxZoom = 1f
    private var activeArray: Rect? = null
    private var afMode: Int? = null
    private var torchOn = false
    private var zoom = 1f

    @Volatile private var closed = false

    /** Why the camera failed (an error code), once it did. */
    @Volatile private var failure: String? = null

    // Guarded by [lock].
    private var pendingFrame: Pending? = null
    private var pendingStill: MethodChannel.Result? = null

    private class Pending(val result: MethodChannel.Result, val rotation: Int)

    fun start(result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        val id = manager?.let { pickCamera(it) }
        if (manager == null || id == null) {
            result.error(LiveCameraPlugin.ERROR_NO_CAMERA, "No back camera", null)
            close()
            return
        }
        val sizes = try {
            val characteristics = manager.getCameraCharacteristics(id)
            describe(characteristics)
            characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.let { chooseSizes(it) }
        } catch (e: CameraAccessException) {
            null
        } catch (e: RuntimeException) {
            null
        }
        if (sizes == null) {
            result.error(LiveCameraPlugin.ERROR_FAILED, "No usable camera sizes", null)
            close()
            return
        }
        val (preview, frames, jpeg) = sizes
        val entry = textures.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(preview.width, preview.height)
        texture = entry
        previewSurface = Surface(entry.surfaceTexture())
        analysis = ImageReader.newInstance(frames.width, frames.height, ImageFormat.YUV_420_888, 2).also {
            it.setOnImageAvailableListener({ reader -> onFrame(reader) }, handler)
        }
        still = ImageReader.newInstance(jpeg.width, jpeg.height, ImageFormat.JPEG, 1).also {
            it.setOnImageAvailableListener({ reader -> onStill(reader) }, handler)
        }
        startCall = result
        val answer = mapOf(
            "textureId" to entry.id(),
            "previewWidth" to preview.width,
            "previewHeight" to preview.height,
            "rotation" to sensorOrientation,
            "analysisWidth" to frames.width,
            "analysisHeight" to frames.height,
            "hasTorch" to hasTorch,
            "minZoom" to minZoom.toDouble(),
            "maxZoom" to maxZoom.toDouble(),
        )
        try {
            manager.openCamera(id, DeviceCallback(answer), handler)
        } catch (e: SecurityException) {
            fail(LiveCameraPlugin.ERROR_PERMISSION)
        } catch (e: CameraAccessException) {
            fail(errorOf(e))
        } catch (e: RuntimeException) {
            fail(LiveCameraPlugin.ERROR_FAILED)
        }
    }

    /** The first back camera, else the first external one. */
    private fun pickCamera(manager: CameraManager): String? = try {
        val facings = manager.cameraIdList.associateWith {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
        }
        facings.entries.firstOrNull { it.value == CameraMetadata.LENS_FACING_BACK }?.key
            ?: facings.entries.firstOrNull { it.value == CameraMetadata.LENS_FACING_EXTERNAL }?.key
    } catch (e: CameraAccessException) {
        null
    } catch (e: RuntimeException) {
        null
    }

    private fun describe(characteristics: CameraCharacteristics) {
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        hasTorch = characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        afMode = when {
            modes.contains(CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE) ->
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            modes.contains(CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO) ->
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            else -> null
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val range = zoomRatioRange(characteristics)
            minZoom = max(1f, range.first)
            maxZoom = max(minZoom, range.second)
        } else {
            minZoom = 1f
            maxZoom = max(
                1f,
                characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f,
            )
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun zoomRatioRange(characteristics: CameraCharacteristics): Pair<Float, Float> {
        val range = characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
            ?: return Pair(1f, 1f)
        return Pair(range.lower, range.upper)
    }

    /**
     * Preview, analysis and still sizes of one aspect ratio (16:9, else 4:3,
     * else whatever there is), so the frames show what the preview shows.
     */
    private fun chooseSizes(map: StreamConfigurationMap): Triple<Size, Size, Size>? {
        val preview = map.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty()
        val frames = map.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        val jpeg = map.getOutputSizes(ImageFormat.JPEG)?.toList().orEmpty()
        if (preview.isEmpty() || frames.isEmpty() || jpeg.isEmpty()) return null
        for (aspect in listOf(16f / 9f, 4f / 3f)) {
            val p = largest(preview, aspect, PREVIEW_LONG, PREVIEW_SHORT) ?: continue
            val f = largest(frames, aspect, FRAME_LONG, FRAME_SHORT) ?: continue
            val j = largest(jpeg, aspect, STILL_LONG, STILL_SHORT) ?: continue
            return Triple(p, f, j)
        }
        return Triple(
            largest(preview, null, PREVIEW_LONG, PREVIEW_SHORT) ?: smallest(preview),
            largest(frames, null, FRAME_LONG, FRAME_SHORT) ?: smallest(frames),
            largest(jpeg, null, STILL_LONG, STILL_SHORT) ?: smallest(jpeg),
        )
    }

    private fun largest(sizes: List<Size>, aspect: Float?, maxLong: Int, maxShort: Int): Size? =
        sizes.filter {
            val long = max(it.width, it.height)
            val short = min(it.width, it.height)
            short > 0 && long <= maxLong && short <= maxShort &&
                (aspect == null || abs(long.toFloat() / short - aspect) < ASPECT_TOLERANCE)
        }.maxByOrNull { it.width.toLong() * it.height }

    private fun smallest(sizes: List<Size>): Size = sizes.minBy { it.width.toLong() * it.height }

    private inner class DeviceCallback(private val answer: Map<String, Any>) : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
            if (closed) {
                camera.close()
                return
            }
            device = camera
            createSession(camera, answer)
        }

        override fun onDisconnected(camera: CameraDevice) {
            // Another app with a higher priority took the camera.
            camera.close()
            if (device === camera) device = null
            fail(LiveCameraPlugin.ERROR_IN_USE)
        }

        override fun onError(camera: CameraDevice, error: Int) {
            camera.close()
            if (device === camera) device = null
            fail(
                when (error) {
                    ERROR_CAMERA_IN_USE, ERROR_MAX_CAMERAS_IN_USE -> LiveCameraPlugin.ERROR_IN_USE
                    ERROR_CAMERA_DISABLED -> LiveCameraPlugin.ERROR_DISABLED
                    else -> LiveCameraPlugin.ERROR_FAILED
                },
            )
        }
    }

    private fun createSession(camera: CameraDevice, answer: Map<String, Any>) {
        val surfaces = listOfNotNull(previewSurface, analysis?.surface, still?.surface)
        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(configured: CameraCaptureSession) {
                if (closed) {
                    configured.close()
                    return
                }
                session = configured
                if (!applyRepeating()) return
                main.post {
                    val call = startCall
                    startCall = null
                    call?.success(answer)
                }
            }

            override fun onConfigureFailed(failed: CameraCaptureSession) {
                fail(LiveCameraPlugin.ERROR_FAILED)
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                createSessionP(camera, surfaces, callback)
            } else {
                @Suppress("DEPRECATION")
                camera.createCaptureSession(surfaces, callback, handler)
            }
        } catch (e: CameraAccessException) {
            fail(errorOf(e))
        } catch (e: RuntimeException) {
            fail(LiveCameraPlugin.ERROR_FAILED)
        }
    }

    @TargetApi(Build.VERSION_CODES.P)
    private fun createSessionP(
        camera: CameraDevice,
        surfaces: List<Surface>,
        callback: CameraCaptureSession.StateCallback,
    ) {
        val outputs = surfaces.map { OutputConfiguration(it) }
        camera.createCaptureSession(
            SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outputs, executor, callback),
        )
    }

    /** Sets the preview's repeating request (camera thread); false on failure. */
    private fun applyRepeating(): Boolean {
        val camera = device ?: return false
        val configured = session ?: return false
        val preview = previewSurface ?: return false
        val frames = analysis ?: return false
        return try {
            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(preview)
            builder.addTarget(frames.surface)
            configure(builder)
            configured.setRepeatingRequest(builder.build(), null, handler)
            true
        } catch (e: CameraAccessException) {
            fail(errorOf(e))
            false
        } catch (e: RuntimeException) {
            fail(LiveCameraPlugin.ERROR_FAILED)
            false
        }
    }

    /** Autofocus, exposure, torch and zoom of every request. */
    private fun configure(builder: CaptureRequest.Builder) {
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        afMode?.let { builder.set(CaptureRequest.CONTROL_AF_MODE, it) }
        builder.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
        builder.set(
            CaptureRequest.FLASH_MODE,
            if (torchOn && hasTorch) CameraMetadata.FLASH_MODE_TORCH else CameraMetadata.FLASH_MODE_OFF,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            setZoomRatio(builder, zoom)
        } else {
            val active = activeArray ?: return
            if (zoom <= 1f) return
            val width = (active.width() / zoom).toInt()
            val height = (active.height() / zoom).toInt()
            val left = (active.width() - width) / 2
            val top = (active.height() - height) / 2
            builder.set(CaptureRequest.SCALER_CROP_REGION, Rect(left, top, left + width, top + height))
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun setZoomRatio(builder: CaptureRequest.Builder, ratio: Float) {
        builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, ratio)
    }

    // -- Frames -----------------------------------------------------------

    fun nextFrame(result: MethodChannel.Result, displayDegrees: Int) {
        if (closed) {
            val code = failure
            if (code == null) result.success(null) else result.error(code, "The camera stopped", null)
            return
        }
        val rotation = (sensorOrientation - displayDegrees + 360) % 360
        val previous = synchronized(lock) {
            val waiting = pendingFrame
            pendingFrame = Pending(result, rotation)
            waiting
        }
        previous?.result?.error(LiveCameraPlugin.ERROR_BUSY, "Superseded by a newer request", null)
    }

    /** A frame arrived (camera thread): copied only when Dart waits for one. */
    private fun onFrame(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return
        try {
            val pending = synchronized(lock) {
                val waiting = pendingFrame
                pendingFrame = null
                waiting
            } ?: return
            val frame = try {
                val plane = image.planes[0]
                val width = image.width
                val height = image.height
                val stride = plane.rowStride
                val buffer = plane.buffer
                val pixels = ByteArray(width * height)
                for (row in 0 until height) {
                    buffer.position(row * stride)
                    buffer.get(pixels, row * width, width)
                }
                mapOf(
                    "pixels" to pixels,
                    "width" to width,
                    "height" to height,
                    "bytesPerRow" to width,
                    "rotationDegrees" to pending.rotation,
                    "timestamp" to image.timestamp / 1000L,
                )
            } catch (e: RuntimeException) {
                // A frame that could not be read: wait for the next one.
                synchronized(lock) { if (pendingFrame == null) pendingFrame = pending }
                null
            } ?: return
            main.post { pending.result.success(frame) }
        } finally {
            image.close()
        }
    }

    // -- Torch, zoom, still -------------------------------------------------

    fun setTorch(on: Boolean, result: MethodChannel.Result) {
        if (closed || !hasTorch) {
            result.success(false)
            return
        }
        handler.post {
            torchOn = on
            val applied = applyRepeating()
            main.post { result.success(applied) }
        }
    }

    fun setZoom(ratio: Float, result: MethodChannel.Result) {
        if (closed) {
            result.success(1.0)
            return
        }
        handler.post {
            zoom = ratio.coerceIn(minZoom, maxZoom)
            applyRepeating()
            val applied = zoom.toDouble()
            main.post { result.success(applied) }
        }
    }

    fun takePicture(result: MethodChannel.Result, displayDegrees: Int) {
        if (closed) {
            result.success(null)
            return
        }
        val busy = synchronized(lock) {
            if (pendingStill != null) {
                true
            } else {
                pendingStill = result
                false
            }
        }
        if (busy) {
            result.error(LiveCameraPlugin.ERROR_BUSY, "A picture is being taken", null)
            return
        }
        val orientation = (sensorOrientation - displayDegrees + 360) % 360
        handler.post {
            val camera = device
            val configured = session
            val jpeg = still
            val preview = previewSurface
            if (camera == null || configured == null || jpeg == null || preview == null) {
                answerStill(null)
                return@post
            }
            try {
                val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                builder.addTarget(preview)
                builder.addTarget(jpeg.surface)
                configure(builder)
                builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)
                builder.set(CaptureRequest.JPEG_QUALITY, JPEG_QUALITY)
                configured.capture(builder.build(), null, handler)
            } catch (e: CameraAccessException) {
                answerStill(null)
            } catch (e: RuntimeException) {
                answerStill(null)
            }
        }
    }

    /** The still arrived (camera thread). */
    private fun onStill(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (e: IllegalStateException) {
            null
        } ?: return
        val bytes = try {
            val buffer = image.planes[0].buffer
            ByteArray(buffer.remaining()).also { buffer.get(it) }
        } catch (e: RuntimeException) {
            null
        } finally {
            image.close()
        }
        answerStill(bytes)
    }

    private fun answerStill(bytes: ByteArray?) {
        val call = synchronized(lock) {
            val waiting = pendingStill
            pendingStill = null
            waiting
        } ?: return
        main.post { call.success(bytes) }
    }

    // -- Errors and release -------------------------------------------------

    private fun errorOf(error: CameraAccessException): String = when (error.reason) {
        CameraAccessException.CAMERA_IN_USE, CameraAccessException.MAX_CAMERAS_IN_USE ->
            LiveCameraPlugin.ERROR_IN_USE
        CameraAccessException.CAMERA_DISABLED -> LiveCameraPlugin.ERROR_DISABLED
        else -> LiveCameraPlugin.ERROR_FAILED
    }

    /** The camera failed with [code] (any thread): tells Dart and releases. */
    private fun fail(code: String) {
        if (failure == null) failure = code
        main.post {
            val call = startCall
            startCall = null
            call?.error(code, "The camera failed", null)
            val frame = synchronized(lock) {
                val waiting = pendingFrame
                pendingFrame = null
                waiting
            }
            frame?.result?.error(code, "The camera failed", null)
            close()
        }
    }

    /** Releases everything (main thread), once; waiting calls get null. */
    fun close() {
        if (closed && texture == null && startCall == null) return
        closed = true
        val call = startCall
        startCall = null
        call?.error(LiveCameraPlugin.ERROR_BACKGROUND, "The camera was stopped", null)
        val frame = synchronized(lock) {
            val waiting = pendingFrame
            pendingFrame = null
            waiting
        }
        frame?.result?.success(null)
        val picture = synchronized(lock) {
            val waiting = pendingStill
            pendingStill = null
            waiting
        }
        picture?.success(null)
        val entry = texture
        texture = null
        handler.post {
            try {
                session?.close()
            } catch (e: RuntimeException) {
                // Already closed.
            }
            session = null
            device?.close()
            device = null
            analysis?.close()
            analysis = null
            still?.close()
            still = null
            previewSurface?.release()
            previewSurface = null
            main.post { entry?.release() }
            thread.quitSafely()
        }
    }

    companion object {
        const val PREVIEW_LONG = 1920
        const val PREVIEW_SHORT = 1080
        const val FRAME_LONG = 1280
        const val FRAME_SHORT = 960
        const val STILL_LONG = 3264
        const val STILL_SHORT = 2448
        const val ASPECT_TOLERANCE = 0.02f
        const val JPEG_QUALITY: Byte = 92
    }
}
