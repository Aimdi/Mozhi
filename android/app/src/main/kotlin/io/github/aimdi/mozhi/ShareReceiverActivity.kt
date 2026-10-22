package io.github.aimdi.mozhi

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

/**
 * The share sheet's "Mozhi" target (`ACTION_SEND`), an invisible window
 * that hands what was shared to [MainActivity] and finishes:
 *
 * - Text (`EXTRA_TEXT`) goes on as `ACTION_SEND` text/plain, which
 *   MainActivity shows in the translate tab (`SharedTextHandler`).
 * - A file (`EXTRA_STREAM`) is copied into the app's cache,
 *   `<cache>/[SHARED_FOLDER]/<token>/<name>`, on a background thread, then
 *   opened with the explicit link `mozhi://image?shared=<token>` (images) or
 *   `mozhi://documents?shared=<token>` (subtitles, text, Markdown, JSON),
 *   read by `lib/app/shared_files.dart`. Nothing is translated or sent
 *   because something was shared: the screens wait for the user (an image
 *   is only read on the device first, see `createAppRouter`).
 *
 * Only `content://` streams of other apps are read: a `file://` path or a
 * content URI of one of Mozhi's own providers could otherwise make Mozhi
 * read its own private files. Files above [MAX_IMAGE_BYTES] or
 * [MAX_DOCUMENT_BYTES] are not copied (the screen opens without them), and
 * shared files older than [MAX_AGE_MILLIS] are deleted at every share.
 *
 * MainActivity is started into the sharing app's task, as when it was the
 * share target itself.
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated window has nothing left to hand over.
        if (savedInstanceState != null) {
            finish()
            return
        }
        val intent = intent
        val stream = if (intent?.action == Intent.ACTION_SEND) streamOf(intent) else null
        if (stream == null) {
            forwardText(intent)
            finish()
            return
        }
        val type = (contentResolver.getType(stream) ?: intent.type)?.lowercase(Locale.ROOT)
        val isImage = type?.startsWith("image/") == true
        executor.execute {
            val token = try {
                store(stream, type, isImage)
            } catch (e: IOException) {
                null
            } catch (e: SecurityException) {
                null
            }
            runOnUiThread {
                if (!isDestroyed) open(isImage, token)
                finish()
            }
        }
    }

    /** Hands shared text to MainActivity (or just opens it). */
    private fun forwardText(intent: Intent?) {
        val text = intent?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val forward = Intent(this, MainActivity::class.java)
        if (!text.isNullOrBlank() && intent?.action == Intent.ACTION_SEND) {
            forward.setAction(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, text)
        }
        startActivity(forward)
    }

    /** Opens the image or document screen, with the file of [token] if any. */
    private fun open(isImage: Boolean, token: String?) {
        val screen = if (isImage) "image" else "documents"
        val link = StringBuilder("${MainActivity.DEEP_LINK_SCHEME}://$screen")
        if (token != null) link.append("?$TOKEN_PARAMETER=").append(token)
        startActivity(
            Intent(this, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse(link.toString())),
        )
    }

    /**
     * The shared content URI of [intent], or null when there is none or it
     * may not be read (see the class documentation).
     */
    private fun streamOf(intent: Intent): Uri? {
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        } ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) return null
        val authority = uri.authority ?: return null
        // Mozhi's own providers always resolve; other apps' may be hidden
        // (package visibility), which is fine.
        @Suppress("DEPRECATION")
        val provider = packageManager.resolveContentProvider(authority, 0)
        if (provider?.packageName == packageName) return null
        return uri
    }

    /**
     * Copies [uri] into a new folder of the shared files and returns its
     * token; null when it is too large or empty. Deletes old shared files
     * first.
     */
    private fun store(uri: Uri, type: String?, isImage: Boolean): String? {
        val root = File(cacheDir, SHARED_FOLDER)
        deleteExpired(root)
        val token = UUID.randomUUID().toString().replace("-", "")
        val folder = File(root, token)
        if (!folder.mkdirs()) return null
        val target = File(folder, fileName(uri, type, isImage))
        val limit = if (isImage) MAX_IMAGE_BYTES else MAX_DOCUMENT_BYTES
        var copied = 0L
        val input = contentResolver.openInputStream(uri)
        if (input == null) {
            folder.deleteRecursively()
            return null
        }
        input.use { source ->
            target.outputStream().use { sink ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    copied += read
                    if (copied > limit) {
                        sink.close()
                        folder.deleteRecursively()
                        return null
                    }
                    sink.write(buffer, 0, read)
                }
            }
        }
        if (copied == 0L) {
            folder.deleteRecursively()
            return null
        }
        return token
    }

    /**
     * A safe file name for [uri]: its display name without path separators
     * or control characters, at most [MAX_NAME_LENGTH] characters, with an
     * extension the screens know for [type] when it has none.
     */
    private fun fileName(uri: Uri, type: String?, isImage: Boolean): String {
        val display = try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
                }
        } catch (e: RuntimeException) {
            null
        }
        var name = (display ?: "")
            .replace(Regex("[\\u0000-\\u001f\\u007f/\\\\:]"), "_")
            .trim()
            .trimStart('.')
        if (name.length > MAX_NAME_LENGTH) name = name.takeLast(MAX_NAME_LENGTH)
        if (name.isEmpty()) name = if (isImage) "image" else "document"
        if (!name.contains('.')) {
            extensionFor(type, isImage)?.let { name = "$name.$it" }
        }
        return name
    }

    private fun deleteExpired(root: File) {
        val now = System.currentTimeMillis()
        root.listFiles()?.forEach { folder ->
            if (now - folder.lastModified() > MAX_AGE_MILLIS) folder.deleteRecursively()
        }
    }

    companion object {
        /** Cache folder of the shared files (`SharedFiles.folder`). */
        const val SHARED_FOLDER = "shared_files"

        /** Query parameter of the token (`SharedFiles.parameter`). */
        const val TOKEN_PARAMETER = "shared"

        /** Largest image copied. */
        const val MAX_IMAGE_BYTES = 40L * 1024 * 1024

        /** Largest document copied (the document screen takes 2 MB). */
        const val MAX_DOCUMENT_BYTES = 8L * 1024 * 1024

        /** How long an unopened shared file is kept (`SharedFiles.maxAge`). */
        const val MAX_AGE_MILLIS = 60L * 60 * 1000

        private const val MAX_NAME_LENGTH = 120

        private val executor = Executors.newSingleThreadExecutor()

        /** The file extension the screens expect for [type], if any. */
        fun extensionFor(type: String?, isImage: Boolean): String? = when (type) {
            "image/png" -> "png"
            "image/jpeg", "image/jpg" -> "jpg"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "image/heic", "image/heif" -> "heic"
            "application/x-subrip", "text/x-subrip", "application/srt" -> "srt"
            "text/vtt" -> "vtt"
            "application/json" -> "json"
            "text/markdown", "text/x-markdown" -> "md"
            "text/plain" -> "txt"
            else -> if (isImage) "jpg" else if (type?.startsWith("text/") == true) "txt" else null
        }
    }
}
