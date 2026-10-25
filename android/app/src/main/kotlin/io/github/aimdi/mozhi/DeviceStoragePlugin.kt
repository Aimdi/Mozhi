package io.github.aimdi.mozhi

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Storage helpers for the on-device models (`lib/platform/free_space.dart`
 * and `lib/platform/model_file_picker.dart`), method channel [CHANNEL],
 * added to every Flutter engine of the app by
 * [MainActivity.configureFlutterEngine]:
 *
 * - `freeBytes({path})` answers the bytes free for the app on the file
 *   system of `path` (default: the files directory), with [StatFs] on its
 *   nearest existing folder: what a model download may use. -1 when it
 *   cannot tell.
 * - `pickFiles()` lets the user pick documents ([Intent.ACTION_OPEN_DOCUMENT],
 *   several, any type) and answers `[{uri, name, size}]` (size -1 when the
 *   provider does not say; empty when cancelled), without copying them:
 *   unlike `file_picker`, which copies every picked file into the cache
 *   first (a few GB for an on-device AI model) before the app can check
 *   it. Errors `busy` (a pick is running) and `no_activity`.
 * - `copyFile({uri, path, maxBytes})` copies a picked document (read
 *   through the [ContentResolver], on a background thread) to `path`, a new
 *   file inside the app's private storage (files, no-backup or cache
 *   directory; anything else is refused with `invalid_path`), stopping
 *   after `maxBytes + 1` bytes; it answers the bytes written. The model
 *   managers verify the copy (size and checksum) before they install it.
 *   Errors `not_found` and `io`.
 *
 * Only the transient read grant of the pick is used (no persistable
 * permission), and the picked documents are never changed.
 */
class DeviceStoragePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

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
        executor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() {
        detach()
        // The window is gone: the pick can no longer be answered.
        pendingPick?.success(emptyList<Map<String, Any>>())
        pendingPick = null
    }

    private fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    private fun detach() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "freeBytes" -> result.success(freeBytes(call.argument<String>("path")))
            "pickFiles" -> pickFiles(result)
            "copyFile" -> copyFile(call, result)
            else -> result.notImplemented()
        }
    }

    /** Bytes free for this app where [path] lives (-1 when unknown). */
    private fun freeBytes(path: String?): Long {
        val start = path?.let { File(it) } ?: context?.filesDir ?: return -1
        var folder: File? = start
        while (folder != null && !folder.exists()) folder = folder.parentFile
        if (folder == null) return -1
        return try {
            StatFs(folder.path).availableBytes
        } catch (e: IllegalArgumentException) {
            -1
        }
    }

    private fun pickFiles(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.error("no_activity", "No window to pick files from", null)
            return
        }
        if (pendingPick != null) {
            result.error("busy", "Files are being picked already", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        pendingPick = result
        try {
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: ActivityNotFoundException) {
            pendingPick = null
            result.error("no_activity", "No document picker on this device", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick ?: return true
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return true
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        } else {
            data.data?.let { uris.add(it) }
        }
        val resolver = context?.contentResolver
        if (resolver == null) {
            result.success(emptyList<Map<String, Any>>())
            return true
        }
        // Names and sizes come from the provider (a query, no reading).
        executor.execute {
            val files = uris.map { describe(resolver, it) }
            main.post { result.success(files) }
        }
        return true
    }

    private fun describe(resolver: ContentResolver, uri: Uri): Map<String, Any> {
        var name: String? = null
        var size = -1L
        try {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) {
                        name = cursor.getString(nameColumn)
                    }
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                        size = cursor.getLong(sizeColumn)
                    }
                }
            }
        } catch (e: RuntimeException) {
            // Some providers refuse queries: the name from the URI, size unknown.
        }
        val fallback = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        return mapOf("uri" to uri.toString(), "name" to (name ?: fallback), "size" to size)
    }

    private fun copyFile(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let { Uri.parse(it) }
        val path = call.argument<String>("path")
        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
        val context = context
        if (uri == null || path == null || maxBytes == null || maxBytes < 0 || context == null) {
            result.error("invalid_argument", "copyFile expects uri, path and maxBytes", null)
            return
        }
        val target = File(path)
        if (!isPrivate(context, target)) {
            result.error("invalid_path", "Only the app's own storage can be written", null)
            return
        }
        executor.execute {
            val answer: () -> Unit = try {
                val written = copy(context.contentResolver, uri, target, maxBytes)
                ({ result.success(written) })
            } catch (e: SecurityException) {
                ({ result.error("not_found", e.message, null) })
            } catch (e: IOException) {
                ({ result.error("io", e.message, null) })
            } catch (e: IllegalArgumentException) {
                ({ result.error("not_found", e.message, null) })
            }
            main.post(answer)
        }
    }

    /** Copies at most [maxBytes] + 1 bytes of [uri] to [target]. */
    private fun copy(resolver: ContentResolver, uri: Uri, target: File, maxBytes: Long): Long {
        val input = resolver.openInputStream(uri) ?: throw IOException("Cannot open $uri")
        var written = 0L
        input.use { source ->
            FileOutputStream(target).use { output ->
                val buffer = ByteArray(BUFFER_SIZE)
                while (written <= maxBytes) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    written += read
                }
                output.fd.sync()
            }
        }
        return written
    }

    /** Whether [file] is inside the app's files, no-backup or cache folder. */
    private fun isPrivate(context: Context, file: File): Boolean {
        val canonical = try {
            file.canonicalPath
        } catch (e: IOException) {
            return false
        }
        return listOfNotNull(context.filesDir, context.noBackupFilesDir, context.cacheDir)
            .mapNotNull {
                try {
                    it.canonicalPath
                } catch (e: IOException) {
                    null
                }
            }
            .any { canonical.startsWith(it + File.separator) }
    }

    companion object {
        const val CHANNEL = "io.github.aimdi.mozhi/storage"

        /** The request code of the picker (unique among the app's). */
        private const val REQUEST_PICK = 0x4d4f
        private const val BUFFER_SIZE = 1 shl 20
    }
}
