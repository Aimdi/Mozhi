package io.github.aimdi.mozhi

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile "Translate": collapses the shade and opens Mozhi to
 * translate the clipboard ([MainActivity.ACTION_TRANSLATE_CLIPBOARD], sent to
 * the non-exported alias [MainActivity.TRANSLATE_CLIPBOARD_ALIAS]).
 *
 * It is a plain action tile (always inactive, nothing to toggle). The
 * clipboard is read by [MainActivity] once its window has focus, because
 * Android 10+ only lets the focused app read the clipboard.
 */
class TranslateTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_translate_label)
        tile.contentDescription = getString(R.string.tile_translate_description)
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            // Ask for the PIN/pattern first; the clipboard is private.
            unlockAndRun { openTranslateClipboard() }
        } else {
            openTranslateClipboard()
        }
    }

    private fun openTranslateClipboard() {
        val intent = MainActivity.translateClipboardIntent(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34+ requires a PendingIntent (the Intent overload throws for
            // apps targeting 34+).
            val pendingIntent = PendingIntent.getActivity(
                this,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private companion object {
        const val REQUEST_CODE = 0
    }
}
