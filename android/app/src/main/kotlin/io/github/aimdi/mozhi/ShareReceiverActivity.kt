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
 * - A file (`EXTRA_STREAM`; of several, `ACTION_SEND_MULTIPLE`, the first,
 *   and the link says how many there were: `shared_count`) is copied
 *   into the app's cache,
 *   `<cache>/[SHARED_FOLDER]/<token>/<name>`, on a background thread, then
 *   opened with the explicit link `mozhi://image?shared=<token>` (images) or
 *   `mozhi://documents?shared=<token>` (subtitles, text, Markdown, JSON,
 *   office documents, e-books and PDFs),
 *   read by `lib/app/shared_files.dart`. Nothing is translated or sent
 *   because something was shared: the screens wait for the user (an image
 *   is only read on the device first, see `createAppRouter`).
 *
 * Only `content://` streams of other apps are read: a `file://` path or a
 * content URI of one of Mozhi's own providers could otherwise make Mozhi
 * read its own private files. Files above [MAX_IMAGE_BYTES] or
 * [MAX_DOCUMENT_BYTES] are not copied, nor are files that cannot be read:
 * the screen then opens with a token without a file, the reason
 * (`shared_error=too_large|unreadable`) and the file's name (`name`), and
 * says why. Shared files older than [MAX_AGE_MILLIS] are deleted at every
 * share.
 *
 * MainActivity is started into the sharing app's task, as when it was the
 * share target itself. A sender without a task of its own (one that starts
 * this window with `FLAG_ACTIVITY_NEW_TASK`, e.g. from a service, a
 * notification or `adb shell am start`) gives this window a new task
 * instead: MainActivity then goes to its own task ([forwarded]), where the
 * running window gets what was shared (`onNewIntent`). Otherwise
 * MainActivity would stay behind in this window's task, and Android brings
 * that task to the front for the next share whose intent only differs in
 * its extras (another text) without starting this window: the text would
 * never reach Mozhi, and the second MainActivity (a Flutter engine of its
 * own) would not know what the first one changed.
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
        val streams = when (intent?.action) {
            Intent.ACTION_SEND -> listOf(sharedStream(intent))
            Intent.ACTION_SEND_MULTIPLE -> sharedStreams(intent)
            else -> emptyList()
        }
        // Only the first item is opened.
        val stream = streams.firstOrNull()?.let { readable(it) }
        if (stream == null) {
            forwardText(intent)
            finish()
            return
        }
        val type = (contentResolver.getType(stream) ?: intent.type)?.lowercase(Locale.ROOT)
        val isImage = type?.startsWith("image/") == true
        val count = streams.size
        executor.execute {
            val name = fileName(stream, type, isImage)
            val stored = try {
                store(stream, name, isImage)
            } catch (e: IOException) {
                Stored(newToken(), ERROR_UNREADABLE, name)
            } catch (e: SecurityException) {
                Stored(newToken(), ERROR_UNREADABLE, name)
            }
            runOnUiThread {
                if (!isDestroyed) open(isImage, stored, count)
                finish()
            }
        }
    }

    /**
     * What [store] made of a shared file: the [token] of the screen's link,
     * and when the file could not be copied, why ([error]) and its [name].
     */
    private class Stored(val token: String, val error: String? = null, val name: String? = null)

    /** Hands shared text to MainActivity (or just opens it). */
    private fun forwardText(intent: Intent?) {
        val text = intent?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val forward = Intent(this, MainActivity::class.java)
        if (!text.isNullOrBlank() && intent?.action == Intent.ACTION_SEND) {
            forward.setAction(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, text)
        }
        startActivity(forwarded(forward))
    }

    /**
     * Opens the image or document screen with the file of [stored] (or why
     * there is none), saying how many items were shared ([count]).
     */
    private fun open(isImage: Boolean, stored: Stored, count: Int) {
        startActivity(
            forwarded(
                Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_VIEW)
                    .setData(linkFor(isImage, stored.token, stored.error, stored.name, count)),
            ),
        )
    }

    /**
     * [intent] for MainActivity as it is started from here: into the
     * sharing app's task, or, when this window is the root of a task of its
     * own (see the class documentation), into MainActivity's own task, to
     * the running window there (as the Quick Settings tile does).
     */
    private fun forwarded(intent: Intent): Intent =
        if (isTaskRoot) {
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        } else {
            intent
        }

    /** The URI of an `ACTION_SEND` [intent], if any. */
    private fun sharedStream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        } ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri

    /** The URIs of an `ACTION_SEND_MULTIPLE` [intent], in order. */
    private fun sharedStreams(intent: Intent): List<Uri?> {
        val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }
        if (!uris.isNullOrEmpty()) return uris
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).map { clip.getItemAt(it)?.uri }
    }

    /**
     * [uri] when Mozhi may read it, or null (see the class documentation).
     */
    private fun readable(uri: Uri?): Uri? {
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
     * Copies [uri] into a new folder of the shared files, as [name], and
     * returns its token; when it is too large, empty or cannot be opened,
     * a token without a file and why. Deletes old shared files first.
     */
    private fun store(uri: Uri, name: String, isImage: Boolean): Stored {
        val root = File(cacheDir, SHARED_FOLDER)
        deleteExpired(root)
        val token = newToken()
        val unreadable = Stored(token, ERROR_UNREADABLE, name)
        val folder = File(root, token)
        if (!folder.mkdirs()) return unreadable
        val target = File(folder, name)
        val limit = if (isImage) MAX_IMAGE_BYTES else MAX_DOCUMENT_BYTES
        var copied = 0L
        val input = try {
            contentResolver.openInputStream(uri)
        } catch (e: IOException) {
            folder.deleteRecursively()
            throw e
        } catch (e: SecurityException) {
            folder.deleteRecursively()
            throw e
        }
        if (input == null) {
            folder.deleteRecursively()
            return unreadable
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
                        return Stored(token, ERROR_TOO_LARGE, name)
                    }
                    sink.write(buffer, 0, read)
                }
            }
        }
        if (copied == 0L) {
            folder.deleteRecursively()
            return unreadable
        }
        return Stored(token)
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

        /** Why the file is missing (`SharedFiles.errorParameter`). */
        const val ERROR_PARAMETER = "shared_error"

        /** The missing file's name (`SharedFiles.nameParameter`). */
        const val NAME_PARAMETER = "name"

        /** How many items were shared (`SharedFiles.countParameter`). */
        const val COUNT_PARAMETER = "shared_count"

        /** Larger than [MAX_IMAGE_BYTES] / [MAX_DOCUMENT_BYTES]. */
        const val ERROR_TOO_LARGE = "too_large"

        /** Not readable (or empty). */
        const val ERROR_UNREADABLE = "unreadable"

        private fun newToken(): String = UUID.randomUUID().toString().replace("-", "")

        /**
         * The link that opens the image or document screen with the shared
         * file of [token]: `mozhi://image?shared=<token>` (images) or
         * `mozhi://documents?shared=<token>`, with why it is missing
         * ([error] and the file's [name]) and how many items were shared
         * (more than one: [count]).
         */
        fun linkFor(isImage: Boolean, token: String, error: String?, name: String?, count: Int): Uri {
            val link = Uri.Builder()
                .scheme(MainActivity.DEEP_LINK_SCHEME)
                .authority(if (isImage) "image" else "documents")
                .appendQueryParameter(TOKEN_PARAMETER, token)
            if (error != null) {
                link.appendQueryParameter(ERROR_PARAMETER, error)
                if (!name.isNullOrEmpty()) link.appendQueryParameter(NAME_PARAMETER, name)
            }
            if (count > 1) link.appendQueryParameter(COUNT_PARAMETER, count.toString())
            return link.build()
        }

        /** Largest image copied. */
        const val MAX_IMAGE_BYTES = 40L * 1024 * 1024

        /**
         * Largest document copied (the document screen takes 2 MB of text
         * and 25 MB office documents, e-books and PDFs).
         */
        const val MAX_DOCUMENT_BYTES = 25L * 1024 * 1024

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
            "application/x-xliff+xml", "application/xliff+xml" -> "xliff"
            "application/x-gettext" -> "po"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
            "application/vnd.oasis.opendocument.text" -> "odt"
            "application/vnd.oasis.opendocument.presentation" -> "odp"
            "application/vnd.oasis.opendocument.spreadsheet" -> "ods"
            "application/epub+zip" -> "epub"
            "application/pdf" -> "pdf"
            "text/markdown", "text/x-markdown" -> "md"
            "text/plain" -> "txt"
            else -> if (isImage) "jpg" else if (type?.startsWith("text/") == true) "txt" else null
        }
    }
}
