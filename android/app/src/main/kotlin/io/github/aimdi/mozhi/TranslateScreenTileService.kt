package io.github.aimdi.mozhi

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile "Translate screen": collapses the shade and opens
 * [ScreenTranslateActivity], which asks for the screen-capture consent
 * (every time) and translates what is on the screen.
 *
 * A plain action tile (always inactive, nothing to toggle). On a locked
 * phone it asks for the PIN/pattern first: the screen may be private.
 */
class TranslateScreenTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_translate_screen_label)
        tile.contentDescription = getString(R.string.tile_translate_screen_description)
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            unlockAndRun { openTranslateScreen() }
        } else {
            openTranslateScreen()
        }
    }

    private fun openTranslateScreen() {
        val intent = ScreenTranslateActivity.launchIntent(this)
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
        const val REQUEST_CODE = 1
    }
}
