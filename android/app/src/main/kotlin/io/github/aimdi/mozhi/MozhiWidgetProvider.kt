package io.github.aimdi.mozhi

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget "Mozhi" (`res/xml/mozhi_widget_info.xml`,
 * `res/layout/widget_mozhi.xml`) with three buttons that open the app through
 * the same intents as the Quick Settings tile and the launcher shortcuts:
 *
 * - **Translate clipboard**: [MainActivity.ACTION_TRANSLATE_CLIPBOARD] (to the
 *   non-exported alias [MainActivity.TRANSLATE_CLIPBOARD_ALIAS]). The
 *   widget never reads the clipboard itself (Android 10+ only lets the
 *   focused app do that); [MainActivity] reads it once its window has focus.
 * - **Type**: the deep link `mozhi://translate` (the translator).
 * - **Camera**: the deep link `mozhi://image?source=camera` (camera
 *   translate, opening the camera on arrival). Hidden when the widget is
 *   resized too narrow for three buttons.
 *
 * The buttons are static, so there is nothing to refresh periodically; the
 * layout is only rebuilt when the widget is added or resized.
 */
class MozhiWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context, options))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        appWidgetManager.updateAppWidget(appWidgetId, buildViews(context, newOptions))
    }

    private fun buildViews(context: Context, options: Bundle?): RemoteViews {
        // Portrait width; 0 while the launcher has not reported a size yet,
        // in which case the default (full) layout is used.
        val widthDp = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
        val known = widthDp > 0
        val showCamera = !known || widthDp >= MIN_WIDTH_CAMERA_DP
        val buttons = if (showCamera) 3 else 2
        val showLabels = !known || widthDp / buttons >= MIN_BUTTON_WIDTH_FOR_LABEL_DP

        val views = RemoteViews(context.packageName, R.layout.widget_mozhi)
        views.setOnClickPendingIntent(
            R.id.widget_clipboard,
            activityIntent(context, REQUEST_CLIPBOARD, MainActivity.translateClipboardIntent(context)),
        )
        views.setOnClickPendingIntent(
            R.id.widget_type,
            activityIntent(context, REQUEST_TYPE, deepLinkIntent(context, TYPE_LINK)),
        )
        views.setOnClickPendingIntent(
            R.id.widget_camera,
            activityIntent(context, REQUEST_CAMERA, deepLinkIntent(context, CAMERA_LINK)),
        )
        views.setViewVisibility(R.id.widget_camera, visibleIf(showCamera))
        val labelVisibility = visibleIf(showLabels)
        views.setViewVisibility(R.id.widget_clipboard_label, labelVisibility)
        views.setViewVisibility(R.id.widget_type_label, labelVisibility)
        views.setViewVisibility(R.id.widget_camera_label, labelVisibility)
        return views
    }

    private fun visibleIf(visible: Boolean): Int = if (visible) View.VISIBLE else View.GONE

    /** Explicit `ACTION_VIEW` intent for a `mozhi://` [link] to [MainActivity]. */
    private fun deepLinkIntent(context: Context, link: String): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(link), context, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )

    private fun activityIntent(context: Context, requestCode: Int, intent: Intent): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private companion object {
        const val TYPE_LINK = "mozhi://translate"
        const val CAMERA_LINK = "mozhi://image?source=camera"

        // Distinct request codes so the three PendingIntents never replace
        // each other (their intents also differ in action/data).
        const val REQUEST_CLIPBOARD = 1
        const val REQUEST_TYPE = 2
        const val REQUEST_CAMERA = 3

        /** Narrower widgets (about 2 cells) show Clipboard and Type only. */
        const val MIN_WIDTH_CAMERA_DP = 160

        /** Labels are shown when each button gets at least this much width. */
        const val MIN_BUTTON_WIDTH_FOR_LABEL_DP = 100
    }
}
