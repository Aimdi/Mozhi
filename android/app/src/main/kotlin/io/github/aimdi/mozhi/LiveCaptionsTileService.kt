package io.github.aimdi.mozhi

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile "Live captions": on while [LiveCaptionService] runs.
 *
 * - Off, a tap collapses the shade and opens Mozhi's live captions screen
 *   with a start request ([startIntent]: `mozhi://transcribe/captions?start=<token>`,
 *   which [MainActivity] hands to the router as
 *   `/transcribe/captions?start=<token>`). The screen starts the captions as
 *   its Start button does, so the microphone permission and the system's
 *   capture consent are asked as always: nothing starts silently. On a
 *   locked phone the PIN, pattern or password comes first, and Mozhi's own
 *   app lock asks before the screen opens.
 * - On, a tap stops the captions, as the caption bar's Stop does.
 *
 * The tile reads the service's state each time the shade shows it, and the
 * service asks for an update when it starts and ends ([requestUpdate]).
 * Live captions need Android 10; before, the tile is unavailable.
 */
class LiveCaptionsTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        update()
    }

    override fun onClick() {
        super.onClick()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val service = LiveCaptions.service
        if (service != null && service.isCapturing) {
            service.stopFromTile()
            update()
            return
        }
        if (isLocked) {
            unlockAndRun { openStartFlow() }
        } else {
            openStartFlow()
        }
    }

    private fun update() {
        val tile = qsTile ?: return
        tile.label = getString(R.string.tile_live_captions_label)
        tile.contentDescription = getString(R.string.tile_live_captions_description)
        tile.state = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q -> Tile.STATE_UNAVAILABLE
            LiveCaptions.isRunning -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.updateTile()
    }

    private fun openStartFlow() {
        val intent = startIntent(this)
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

    companion object {
        private const val REQUEST_CODE = 2

        /** `AppRoutes.liveCaptions` in Dart, as a `mozhi://` link. */
        private const val START_LINK = "mozhi://transcribe/captions"

        /** `LiveCaptionsPage.startParameter` in Dart. */
        private const val START_PARAMETER = "start"

        /**
         * Opens [MainActivity] at the live captions screen with a start
         * request. Each one has a new token, so the screen starts the
         * captions once per tap (also when it is open already).
         */
        fun startIntent(context: Context): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(
                    Uri.parse(START_LINK).buildUpon()
                        .appendQueryParameter(START_PARAMETER, SystemClock.elapsedRealtime().toString())
                        .build(),
                )
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )

        /** Asks the system to show the tile's state again (best effort). */
        fun requestUpdate(context: Context) {
            try {
                requestListeningState(
                    context,
                    ComponentName(context, LiveCaptionsTileService::class.java),
                )
            } catch (e: RuntimeException) {
                // Not added, or the system refuses: it reads the state when shown.
            }
        }
    }
}
