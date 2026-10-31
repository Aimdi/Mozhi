package io.github.aimdi.mozhi

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * PDF pages for the documents screen (`lib/documents/pdf/`), method channel
 * [CHANNEL], added to every Flutter engine of the app by
 * [MainActivity.configureFlutterEngine]. Framework API only:
 * [PdfRenderer] reads, [PdfDocument] writes. Every call runs on one
 * background thread, in order, so one document is open at a time and the
 * main thread never waits for a page.
 *
 * - `open({path})`: opens the PDF at `path`, a file in the app's cache (the
 *   copy Dart made of the picked file; anything else is refused with
 *   `invalid_path`), and deletes that file once it is open (the descriptor
 *   keeps it readable). Answers `{widths, heights}`: every page's size in
 *   points. Closes the document open before. Errors: `encrypted` (password
 *   protected: [PdfRenderer] throws a [SecurityException]), `damaged`,
 *   `too_large` (over [MAX_BYTES] or [MAX_PAGES]).
 * - `render({page, maxPixels})`: page `page` on white, scaled to at most
 *   `maxPixels` pixels (never more than [MAX_PIXELS], nor
 *   [MAX_READ_SCALE] times its size in points). Answers `{width, height,
 *   bytesPerPixel: 4, pixels}` (RGBA, opaque). Errors `not_open`,
 *   `invalid_argument`, `too_large` (out of memory).
 * - `text({page})`: the text layer of page `page` on Android 15 (API 35)
 *   and later ([TextLayer]): `{lines: [{text, left, top, right, bottom}]}`,
 *   every line of the page's text with its box in points from the top
 *   left, in the file's order (empty for a page without text, a scan, or
 *   when the framework cannot tell where the text is); null before
 *   Android 15. Dart reads a page with too little text with text
 *   recognition instead. Errors `not_open`, `invalid_argument`.
 * - `write({path, pages})`: writes the translated PDF to `path` (in the
 *   cache). Every page is its source page re-rendered as the background
 *   (at most [MAX_BACKGROUND_SCALE], 150 dpi, and a share of
 *   [TOTAL_BACKGROUND_PIXELS]: [PdfDocument] keeps every page in memory
 *   until the file is written, so a long document gets less), then each
 *   block's area is covered in its background colour and its text drawn
 *   as real text with a [StaticLayout] (its alignment and direction, the
 *   largest size up to the block's `fontSize` that fits; never below
 *   [MIN_FONT_SIZE]: a text that does not fit even then is drawn with
 *   tighter lines and runs on below its box, on the box's colour, rather
 *   than shrinking out of reading). Skia's PDF backend embeds the glyphs
 *   with their characters, so the text can be selected, searched and read
 *   aloud. A failed write deletes the partial file.
 * - `close()`: closes the open document (nothing when none is).
 *
 * Errors close what they opened: a failed open closes the document, a page
 * and its bitmaps are released whatever happens, and the document closes
 * when the engine detaches.
 */
class PdfPagesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    /** The one thread every call runs on, in order. */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Only used on [executor].
    private var descriptor: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            executor.execute { closeDocument() }
        } catch (e: RejectedExecutionException) {
            // Shut down already.
        }
        executor.shutdown()
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                val path = call.argument<String>("path")
                val context = context
                run(result) { open(context, path) }
            }
            "render" -> {
                val page = call.argument<Number>("page")?.toInt()
                val maxPixels = call.argument<Number>("maxPixels")?.toLong()
                run(result) { render(page, maxPixels) }
            }
            "text" -> {
                val page = call.argument<Number>("page")?.toInt()
                run(result) { text(page) }
            }
            "write" -> {
                val path = call.argument<String>("path")
                val pages = call.argument<List<Any?>>("pages")
                val context = context
                run(result) { write(context, path, pages) }
            }
            "close" -> run(result) { closeDocument() }
            else -> result.notImplemented()
        }
    }

    /** Runs [task] on [executor] and answers [result] on the main thread. */
    private fun run(result: MethodChannel.Result, task: () -> Any?) {
        try {
            executor.execute {
                val answer: () -> Unit = try {
                    val value = task()
                    ({ result.success(if (value == Unit) null else value) })
                } catch (e: PdfError) {
                    ({ result.error(e.code, e.message, null) })
                } catch (e: OutOfMemoryError) {
                    ({ result.error("too_large", "Not enough memory", null) })
                } catch (e: IOException) {
                    ({ result.error("io", e.message, null) })
                } catch (e: RuntimeException) {
                    // Whatever else a damaged file makes the framework throw:
                    // Dart is always answered.
                    ({ result.error("failed", e.message, null) })
                }
                main.post { answer() }
            }
        } catch (e: RejectedExecutionException) {
            result.error("closed", "The engine is gone", null)
        }
    }

    private fun open(context: Context?, path: String?): Map<String, Any> {
        val file = privateFile(context, path)
            ?: throw PdfError("invalid_path", "Only a file in the app's cache can be opened")
        closeDocument()
        try {
            if (!file.isFile) throw PdfError("damaged", "No such file")
            if (file.length() > MAX_BYTES) throw PdfError("too_large", "Over $MAX_BYTES bytes")
            val opened = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            descriptor = opened
            val pdf = try {
                PdfRenderer(opened)
            } catch (e: SecurityException) {
                throw PdfError("encrypted", "Password protected")
            } catch (e: IOException) {
                throw PdfError("damaged", e.message ?: "Not a PDF")
            } catch (e: RuntimeException) {
                throw PdfError("damaged", e.message ?: "Not a PDF")
            }
            renderer = pdf
            val count = pdf.pageCount
            if (count <= 0) throw PdfError("damaged", "No pages")
            if (count > MAX_PAGES) throw PdfError("too_large", "Over $MAX_PAGES pages")
            val widths = ArrayList<Int>(count)
            val heights = ArrayList<Int>(count)
            for (index in 0 until count) {
                val page = pdf.openPage(index)
                try {
                    if (page.width <= 0 || page.height <= 0) {
                        throw PdfError("damaged", "Page $index has no size")
                    }
                    widths.add(page.width)
                    heights.add(page.height)
                } finally {
                    page.close()
                }
            }
            return mapOf("widths" to widths, "heights" to heights)
        } catch (e: Throwable) {
            closeDocument()
            throw e
        } finally {
            // The descriptor keeps it readable; no copy stays behind.
            file.delete()
        }
    }

    private fun render(index: Int?, maxPixels: Long?): Map<String, Any> {
        val pdf = renderer ?: throw PdfError("not_open", "No PDF is open")
        if (index == null || index < 0 || index >= pdf.pageCount) {
            throw PdfError("invalid_argument", "No page $index")
        }
        val budget = (maxPixels ?: MAX_PIXELS).coerceIn(1L, MAX_PIXELS)
        val page = pdf.openPage(index)
        try {
            val (width, height) = scaledSize(page.width, page.height, budget, MAX_READ_SCALE)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                renderOnWhite(page, bitmap)
                val pixels = ByteArray(width * height * 4)
                // ARGB_8888 is stored as R, G, B, A bytes.
                bitmap.copyPixelsToBuffer(ByteBuffer.wrap(pixels))
                return mapOf(
                    "width" to width,
                    "height" to height,
                    "bytesPerPixel" to 4,
                    "pixels" to pixels,
                )
            } finally {
                bitmap.recycle()
            }
        } finally {
            page.close()
        }
    }

    /** The text layer of page [index] (`text`), null before Android 15. */
    private fun text(index: Int?): Map<String, Any>? {
        val pdf = renderer ?: throw PdfError("not_open", "No PDF is open")
        if (index == null || index < 0 || index >= pdf.pageCount) {
            throw PdfError("invalid_argument", "No page $index")
        }
        if (Build.VERSION.SDK_INT < TextLayer.SDK) return null
        val page = pdf.openPage(index)
        try {
            return mapOf("lines" to TextLayer.lines(page))
        } finally {
            page.close()
        }
    }

    private fun write(context: Context?, path: String?, pages: List<Any?>?) {
        val target = privateFile(context, path)
            ?: throw PdfError("invalid_path", "Only a file in the app's cache can be written")
        val pdf = renderer ?: throw PdfError("not_open", "No PDF is open")
        if (pages == null || pages.isEmpty() || pages.size > MAX_PAGES) {
            throw PdfError("invalid_argument", "1 to $MAX_PAGES pages")
        }
        val specs = pages.map { pageSpec(it, pdf.pageCount) }
        val budget = max(MIN_BACKGROUND_PIXELS, TOTAL_BACKGROUND_PIXELS / specs.size)
        val document = PdfDocument()
        try {
            for ((number, spec) in specs.withIndex()) {
                val info = PdfDocument.PageInfo.Builder(spec.width, spec.height, number + 1).create()
                val page = document.startPage(info)
                try {
                    drawBackground(pdf, spec, page.canvas, budget)
                    for (block in spec.blocks) drawBlock(page.canvas, block, spec.height.toFloat())
                } finally {
                    document.finishPage(page)
                }
            }
            FileOutputStream(target).use { document.writeTo(it) }
        } catch (e: Throwable) {
            target.delete()
            throw e
        } finally {
            document.close()
        }
    }

    /** The source page of [spec] as the background of [canvas] (points). */
    private fun drawBackground(pdf: PdfRenderer, spec: PageSpec, canvas: Canvas, budget: Long) {
        val source = pdf.openPage(spec.page)
        try {
            val (width, height) = scaledSize(source.width, source.height, budget, MAX_BACKGROUND_SCALE)
            val rendered = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            var drawn = rendered
            try {
                renderOnWhite(source, rendered)
                // Half the memory while the document keeps it (opaque anyway).
                drawn = rendered.copy(Bitmap.Config.RGB_565, false) ?: rendered
                canvas.drawBitmap(
                    drawn,
                    null,
                    RectF(0f, 0f, spec.width.toFloat(), spec.height.toFloat()),
                    BITMAP_PAINT,
                )
            } finally {
                // The document keeps what it drew; the full copy can go.
                if (drawn !== rendered) rendered.recycle()
            }
        } finally {
            source.close()
        }
    }

    /** Covers [block]'s box in its colour and draws its text over it. */
    private fun drawBlock(canvas: Canvas, block: BlockSpec, pageHeight: Float) {
        val width = block.right - block.left
        if (width < 1f || block.bottom - block.top < 1f || block.text.isBlank()) return
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = block.color
            typeface = Typeface.DEFAULT
        }
        val layout = fit(block, paint)
        val bottom = min(pageHeight, max(block.bottom, block.top + layout.height / SCALE))
        val cover = Paint().apply {
            color = block.background
            style = Paint.Style.FILL
        }
        canvas.drawRect(block.left, block.top, block.right, bottom, cover)
        canvas.save()
        try {
            canvas.clipRect(block.left, block.top, block.right, pageHeight)
            canvas.translate(block.left, block.top)
            canvas.scale(1f / SCALE, 1f / SCALE)
            layout.draw(canvas)
        } finally {
            canvas.restore()
        }
    }

    /**
     * The layout of [block]'s text at the largest size up to its `fontSize`
     * that fits its box (a binary search), else at [MIN_FONT_SIZE] with
     * tighter lines (it then runs on below the box). Laid out [SCALE] times
     * larger, for fractional sizes and line positions.
     */
    private fun fit(block: BlockSpec, paint: TextPaint): StaticLayout {
        val width = max(1, floor((block.right - block.left) * SCALE).toInt())
        val room = (block.bottom - block.top) * SCALE * FIT_TOLERANCE
        val largest = block.fontSize.coerceIn(MIN_FONT_SIZE, MAX_FONT_SIZE)
        val atLargest = layout(block, paint, width, largest, 1f)
        if (atLargest.height <= room) return atLargest
        var best = layout(block, paint, width, MIN_FONT_SIZE, 1f)
        if (best.height > room) return layout(block, paint, width, MIN_FONT_SIZE, TIGHT_SPACING)
        var low = MIN_FONT_SIZE
        var high = largest
        repeat(FIT_STEPS) {
            val size = (low + high) / 2
            val candidate = layout(block, paint, width, size, 1f)
            if (candidate.height <= room) {
                best = candidate
                low = size
            } else {
                high = size
            }
        }
        return best
    }

    private fun layout(
        block: BlockSpec,
        paint: TextPaint,
        width: Int,
        size: Float,
        spacing: Float,
    ): StaticLayout {
        paint.textSize = size * SCALE
        return StaticLayout.Builder.obtain(block.text, 0, block.text.length, paint, width)
            .setAlignment(block.alignment)
            .setTextDirection(if (block.rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
            .setLineSpacing(0f, spacing)
            .setIncludePad(false)
            .setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NORMAL)
            .build()
    }

    private fun closeDocument() {
        val pdf = renderer
        val opened = descriptor
        renderer = null
        descriptor = null
        try {
            pdf?.close()
        } catch (e: RuntimeException) {
            // Closed already.
        }
        try {
            opened?.close()
        } catch (e: IOException) {
            // The renderer closed it.
        }
    }

    /** A page of `write`: its source page, size in points and blocks. */
    private class PageSpec(val page: Int, val width: Int, val height: Int, val blocks: List<BlockSpec>)

    /** A translated block in points. */
    private class BlockSpec(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val text: String,
        val color: Int,
        val background: Int,
        val rtl: Boolean,
        val alignment: Layout.Alignment,
        val fontSize: Float,
    )

    private class PdfError(val code: String, message: String) : Exception(message)

    /**
     * Android 15's text layer of a page (`android.graphics.pdf.content`),
     * by reflection: the app compiles against an SDK that may not have it,
     * and nothing here runs before [SDK].
     *
     * `PdfRenderer.Page.getTextContents()` gives the page's text, its lines
     * separated by line breaks. When a content's bounds are one per line
     * (as documented), they are taken as they are; otherwise (Android 15
     * gives the text without bounds) every line is selected by its
     * character indexes (`selectContent` with index `SelectionBoundary`s,
     * stop exclusive) and its box is the union of the selection's bounds.
     * Indexes count UTF-16 units, so a character outside the Basic
     * Multilingual Plane can shift the boxes of the lines after it a little.
     * Anything the framework throws reads as no text: the page is then
     * read with text recognition.
     */
    private object TextLayer {
        const val SDK = 35

        private fun method(owner: String, name: String, vararg types: Class<*>) = try {
            Class.forName(owner).getMethod(name, *types)
        } catch (e: ReflectiveOperationException) {
            null
        } catch (e: LinkageError) {
            null
        }

        private const val CONTENT = "android.graphics.pdf.content.PdfPageTextContent"
        private const val BOUNDARY = "android.graphics.pdf.models.selection.SelectionBoundary"
        private const val SELECTION = "android.graphics.pdf.models.selection.PageSelection"

        private val getTextContents by lazy {
            try {
                PdfRenderer.Page::class.java.getMethod("getTextContents")
            } catch (e: ReflectiveOperationException) {
                null
            }
        }
        private val getText by lazy { method(CONTENT, "getText") }
        private val getBounds by lazy { method(CONTENT, "getBounds") }
        private val selectedTextContents by lazy { method(SELECTION, "getSelectedTextContents") }
        private val boundaryClass by lazy {
            try {
                Class.forName(BOUNDARY)
            } catch (e: ReflectiveOperationException) {
                null
            }
        }
        private val boundaryAt by lazy {
            try {
                boundaryClass?.getConstructor(Int::class.javaPrimitiveType)
            } catch (e: ReflectiveOperationException) {
                null
            }
        }
        private val selectContent by lazy {
            val boundary = boundaryClass ?: return@lazy null
            try {
                PdfRenderer.Page::class.java.getMethod("selectContent", boundary, boundary)
            } catch (e: ReflectiveOperationException) {
                null
            }
        }

        /** The lines of [page]'s text layer with their boxes (points). */
        fun lines(page: PdfRenderer.Page): List<Map<String, Any>> {
            val out = ArrayList<Map<String, Any>>()
            val contents = try {
                getTextContents?.invoke(page) as? List<*>
            } catch (e: Exception) {
                null
            } ?: return out
            // The index of each content's text in the page's text.
            var offset = 0
            for (content in contents) {
                if (out.size >= MAX_TEXT_LINES) break
                if (content == null) continue
                val text = call { getText?.invoke(content) as? String } ?: continue
                val lines = splitLines(text)
                val bounds = rects(call { getBounds?.invoke(content) })
                if (bounds.isNotEmpty() && bounds.size == lines.size) {
                    for ((i, line) in lines.withIndex()) add(out, line.text, bounds[i])
                } else {
                    for (line in lines) {
                        if (out.size >= MAX_TEXT_LINES) break
                        val box = selectionBox(page, offset + line.start, offset + line.end)
                        if (box != null) add(out, line.text, box)
                    }
                }
                offset += text.length
            }
            return out
        }

        /** The union of the bounds of characters [start] until [stop]. */
        private fun selectionBox(page: PdfRenderer.Page, start: Int, stop: Int): RectF? {
            val select = selectContent ?: return null
            val boundary = boundaryAt ?: return null
            val selection = call {
                select.invoke(page, boundary.newInstance(start), boundary.newInstance(stop))
            } ?: return null
            val contents = call { selectedTextContents?.invoke(selection) as? List<*> } ?: return null
            var box: RectF? = null
            for (content in contents) {
                if (content == null) continue
                for (rect in rects(call { getBounds?.invoke(content) })) {
                    val union = box
                    if (union == null) box = RectF(rect) else union.union(rect)
                }
            }
            return box
        }

        /** [block]'s value, null when it throws (the framework or reflection). */
        private inline fun <T> call(block: () -> T?): T? = try {
            block()
        } catch (e: Exception) {
            null
        } catch (e: LinkageError) {
            null
        }

        /** The non-degenerate rectangles of [value] (a list of [RectF]). */
        private fun rects(value: Any?): List<RectF> {
            val list = value as? List<*> ?: return emptyList()
            return list.mapNotNull { rect ->
                (rect as? RectF)?.takeIf {
                    it.width() >= MIN_BOX && it.height() >= MIN_BOX &&
                        it.left.isFinite() && it.top.isFinite() &&
                        it.right.isFinite() && it.bottom.isFinite()
                }
            }
        }

        private fun add(out: MutableList<Map<String, Any>>, text: String, box: RectF) {
            out.add(
                mapOf(
                    "text" to text.take(MAX_TEXT_LINE_CHARS),
                    "left" to box.left.toDouble(),
                    "top" to box.top.toDouble(),
                    "right" to box.right.toDouble(),
                    "bottom" to box.bottom.toDouble(),
                ),
            )
        }

        /** A line of a text: [text], from [start] until [end] (trimmed). */
        class Line(val text: String, val start: Int, val end: Int)

        /** [text]'s non-blank lines (split at CR, LF and CR LF), trimmed. */
        fun splitLines(text: String): List<Line> {
            val lines = ArrayList<Line>()
            var start = 0
            var index = 0
            while (index <= text.length) {
                val atEnd = index == text.length
                val c = if (atEnd) '\n' else text[index]
                if (atEnd || c == '\n' || c == '\r' || c == '\u2028') {
                    var from = start
                    var to = index
                    while (from < to && text[from].isWhitespace()) from++
                    while (to > from && text[to - 1].isWhitespace()) to--
                    if (to > from) lines.add(Line(text.substring(from, to), from, to))
                    start = index + 1
                }
                index++
            }
            return lines
        }

        /** Most lines of a page (`PdfLimits.maxTextLines`), characters of one. */
        private const val MAX_TEXT_LINES = 5_000
        private const val MAX_TEXT_LINE_CHARS = 2_000

        /** Boxes narrower or lower than this (points) are line breaks. */
        private const val MIN_BOX = 0.5f
    }

    companion object {
        const val CHANNEL = "mozhi/pdf_pages"

        /** Largest PDF opened (`PdfLimits.maxBytes`). */
        const val MAX_BYTES = 25L * 1024 * 1024

        /** Most pages (`PdfLimits.maxPages`). */
        const val MAX_PAGES = 200

        /** Most pixels of a page rendered for reading (`PdfLimits.maxPixels`). */
        const val MAX_PIXELS = 8_000_000L

        /** Pages are never rendered for reading above 600 dpi. */
        private const val MAX_READ_SCALE = 600.0 / 72

        /** Backgrounds of the translated PDF: at most 150 dpi... */
        private const val MAX_BACKGROUND_SCALE = 150.0 / 72

        /** ...and this many pixels for the whole document (64 MB), shared by its pages... */
        private const val TOTAL_BACKGROUND_PIXELS = 32_000_000L

        /** ...but at least this many for a page. */
        private const val MIN_BACKGROUND_PIXELS = 160_000L

        /** A rendered side is at most this long (very long strips of paper). */
        private const val MAX_SIDE = 20_000

        /** Most blocks on a page, and characters in one. */
        private const val MAX_BLOCKS = 2_000
        private const val MAX_BLOCK_CHARS = 20_000

        /** The largest page side in points (200 inches, the PDF maximum). */
        private const val MAX_PAGE_POINTS = 14_400

        /** Translations are never drawn smaller than this (points). */
        private const val MIN_FONT_SIZE = 6f
        private const val MAX_FONT_SIZE = 144f

        /** Line spacing when not even [MIN_FONT_SIZE] fits. */
        private const val TIGHT_SPACING = 0.85f

        /** A layout this much taller than the box still fits (tight boxes). */
        private const val FIT_TOLERANCE = 1.15f
        private const val FIT_STEPS = 8

        /** Layouts are made this many times larger than points. */
        private const val SCALE = 4f

        private val BITMAP_PAINT = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

        /** [page] rendered over white into [bitmap], scaled to fill it. */
        private fun renderOnWhite(page: PdfRenderer.Page, bitmap: Bitmap) {
            bitmap.eraseColor(Color.TRANSPARENT)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            // White under whatever the page left transparent.
            Canvas(bitmap).drawColor(Color.WHITE, PorterDuff.Mode.DST_OVER)
        }

        /**
         * Pixel size of a page of [width] x [height] points with at most
         * [budget] pixels, at most [maxScale] pixels per point, every side
         * at least 1 and at most [MAX_SIDE].
         */
        fun scaledSize(width: Int, height: Int, budget: Long, maxScale: Double): Pair<Int, Int> {
            val w = max(1, width).toDouble()
            val h = max(1, height).toDouble()
            var scale = min(sqrt(budget.toDouble() / (w * h)), maxScale)
            scale = min(scale, MAX_SIDE / max(w, h))
            val pixelsWide = max(1, floor(w * scale).toInt())
            val pixelsHigh = max(1, floor(h * scale).toInt())
            return pixelsWide to pixelsHigh
        }

        /**
         * [file] when it is inside the app's cache folder (where Dart's
         * copies are), else null.
         */
        private fun privateFile(context: Context?, path: String?): File? {
            if (context == null || path == null) return null
            return try {
                val file = File(path)
                val cache = context.cacheDir.canonicalPath + File.separator
                if (file.canonicalPath.startsWith(cache)) file else null
            } catch (e: IOException) {
                null
            }
        }

        private fun pageSpec(value: Any?, pageCount: Int): PageSpec {
            val map = value as? Map<*, *> ?: throw PdfError("invalid_argument", "A page is a map")
            val page = (map["page"] as? Number)?.toInt()
            if (page == null || page < 0 || page >= pageCount) {
                throw PdfError("invalid_argument", "No source page $page")
            }
            val width = points(map["width"])
            val height = points(map["height"])
            val blocks = map["blocks"] as? List<*> ?: emptyList<Any?>()
            if (blocks.size > MAX_BLOCKS) throw PdfError("invalid_argument", "Too many blocks")
            return PageSpec(
                page,
                width,
                height,
                blocks.map { blockSpec(it, width.toFloat(), height.toFloat()) },
            )
        }

        private fun points(value: Any?): Int {
            val size = (value as? Number)?.toDouble()
            if (size == null || !size.isFinite() || size < 1 || size > MAX_PAGE_POINTS) {
                throw PdfError("invalid_argument", "Page size $value")
            }
            return Math.round(size).toInt()
        }

        private fun blockSpec(value: Any?, width: Float, height: Float): BlockSpec {
            val map = value as? Map<*, *> ?: throw PdfError("invalid_argument", "A block is a map")
            fun coordinate(key: String, limit: Float): Float {
                val number = (map[key] as? Number)?.toFloat()
                if (number == null || !number.isFinite()) {
                    throw PdfError("invalid_argument", "Block $key")
                }
                return number.coerceIn(0f, limit)
            }
            val text = map["text"] as? String ?: throw PdfError("invalid_argument", "Block text")
            if (text.length > MAX_BLOCK_CHARS) throw PdfError("invalid_argument", "Block text too long")
            val fontSize = (map["fontSize"] as? Number)?.toFloat()?.takeIf { it.isFinite() } ?: 12f
            return BlockSpec(
                left = coordinate("left", width),
                top = coordinate("top", height),
                right = coordinate("right", width),
                bottom = coordinate("bottom", height),
                text = text,
                // Opaque, whatever was sent.
                color = ((map["color"] as? Number)?.toLong() ?: 0xFF000000L).toInt() or OPAQUE,
                background = ((map["background"] as? Number)?.toLong() ?: 0xFFFFFFFFL).toInt() or OPAQUE,
                rtl = map["rtl"] == true,
                alignment = when (map["align"]) {
                    "center" -> Layout.Alignment.ALIGN_CENTER
                    "end" -> Layout.Alignment.ALIGN_OPPOSITE
                    else -> Layout.Alignment.ALIGN_NORMAL
                },
                fontSize = fontSize,
            )
        }

        private const val OPAQUE = -0x1000000
    }
}
