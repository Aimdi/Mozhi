package io.github.aimdi.mozhi

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * The bubble's long press ([TranslateBubbleService]): quick-translates the
 * clipboard over the app in front.
 *
 * An invisible window that reads the clipboard once it has input focus
 * (Android 10+ only lets the focused app read it) and hands the text to the
 * quick translate window ([QuickTranslateActivity]) as a read-only text
 * selection (`ACTION_PROCESS_TEXT`), so the sheet opens above the app, as
 * for text selected there. An empty clipboard says so in a toast. Nothing is
 * read before the long press, and nothing is translated by an AI engine
 * without the user's Translate (the sheet's own rule).
 *
 * Not exported: only the bubble starts it.
 */
class BubbleClipboardActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) {
            // Recreated: the long press is long gone.
            finish()
            return
        }
        // Never stay as an invisible window over the app.
        main.postDelayed({ if (!isFinishing) finish() }, FOCUS_TIMEOUT_MILLIS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        val text = clipboardText()?.takeIf { it.isNotBlank() }
        if (text == null) {
            Toast.makeText(this, R.string.bubble_clipboard_empty, Toast.LENGTH_SHORT).show()
        } else {
            val intent = Intent(this, QuickTranslateActivity::class.java)
                .setAction(Intent.ACTION_PROCESS_TEXT)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_PROCESS_TEXT, text.take(MAX_CHARS))
                .putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
            try {
                startActivity(intent)
            } catch (e: ActivityNotFoundException) {
                // Cannot happen for our own activity.
            }
        }
        finish()
        noTransition()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun clipboardText(): String? = try {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clip = clipboard?.primaryClip
        if (clip == null || clip.itemCount == 0) {
            null
        } else {
            clip.getItemAt(0).coerceToText(this)?.toString()
        }
    } catch (e: SecurityException) {
        // Not focused after all (Android 10+).
        null
    }

    private fun noTransition() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    private companion object {
        const val FOCUS_TIMEOUT_MILLIS = 3000L

        /** More than the translator takes; keeps the intent small. */
        const val MAX_CHARS = 50_000
    }
}
