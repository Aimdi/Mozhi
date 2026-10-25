package io.github.aimdi.mozhi

import android.animation.ValueAnimator
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.ImageView
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * The opt-in "Translate bubble" (Settings › General › Android integration):
 * a small round button floating over other apps (`SYSTEM_ALERT_WINDOW`,
 * "Display over other apps").
 *
 * - **Tap**: translate the screen ([ScreenTranslateActivity]).
 * - **Long press**: quick-translate the clipboard ([BubbleClipboardActivity]).
 * - **Drag** it anywhere; let go and it snaps to the nearest side. Dropped on
 *   the × target that appears at the bottom while dragging, it is removed
 *   (the service stops).
 *
 * Accessible: a content description, 56 dp (more than 48 dp), the long
 * press and "Remove the bubble" as accessibility actions (no dragging
 * needed). It hides while any Mozhi window is on screen (translating Mozhi
 * itself makes no sense, and the screenshot must not show it) and comes
 * back afterwards.
 *
 * A foreground service of the type `specialUse` (Android 14+; the manifest
 * names the use in `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`) with a quiet
 * notification whose **Stop** action removes the bubble. Its state lives
 * here (running or not, [isRunning]); the settings toggle it through
 * [ScreenTranslatePlugin]. It stays until stopped (sticky); it does not
 * start again after a reboot.
 */
class TranslateBubbleService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var windowManager: WindowManager? = null
    private var windowContext: Context? = null
    private var bubble: ImageView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleAttached = false
    private var target: ImageView? = null
    private var targetParams: WindowManager.LayoutParams? = null
    private var targetAttached = false
    private var overTarget = false
    private var snap: ValueAnimator? = null

    /** The Mozhi activities on screen (started, not stopped). */
    private val visibleActivities = mutableSetOf<Int>()

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            visibleActivities.add(System.identityHashCode(activity))
            updateBubbleVisibility()
        }

        override fun onActivityStopped(activity: Activity) {
            visibleActivities.remove(System.identityHashCode(activity))
            updateBubbleVisibility()
        }

        override fun onActivityDestroyed(activity: Activity) {
            visibleActivities.remove(System.identityHashCode(activity))
            updateBubbleVisibility()
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        application.registerActivityLifecycleCallbacks(activityCallbacks)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopBubble()
            return START_NOT_STICKY
        }
        if (intent == null) {
            // Restarted after Android ended the process: the overlay first
            // (Android 15 lets an app with a visible overlay start a
            // foreground service from the background), then the foreground.
            if (!Settings.canDrawOverlays(this) || !showBubble() || !startInForeground()) {
                stopBubble()
                return START_NOT_STICKY
            }
            return START_STICKY
        }
        // Started by the app (startForegroundService): the foreground first.
        if (!startInForeground() || !Settings.canDrawOverlays(this) || !showBubble()) {
            stopBubble()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // A rotation or a new screen size: back onto the screen, at a side.
        main.post { snapToSide(animate = false) }
    }

    override fun onDestroy() {
        isRunning = false
        application.unregisterActivityLifecycleCallbacks(activityCallbacks)
        snap?.cancel()
        hideTarget()
        detachBubble()
        bubble = null
        target = null
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun stopBubble() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ---------------------------------------------------------------------
    // Foreground
    // ---------------------------------------------------------------------

    private fun startInForeground(): Boolean {
        ScreenTranslateNotifications.ensureChannel(
            this,
            ScreenTranslateNotifications.BUBBLE,
            R.string.notification_channel_bubble,
            R.string.notification_channel_bubble_description,
        )
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
            true
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (Android 12+).
            false
        }
    }

    /** "Translate bubble is on" with Stop; a tap opens the setting. */
    private fun notification(): Notification {
        val stop = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, TranslateBubbleService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val settings = PendingIntent.getActivity(
            this,
            REQUEST_SETTINGS,
            Intent(this, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse(SETTINGS_LINK))
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopAction = Notification.Action.Builder(
            Icon.createWithResource(this, R.drawable.ic_bubble_remove),
            getString(R.string.notification_bubble_stop),
            stop,
        ).build()
        return ScreenTranslateNotifications
            .builder(this, ScreenTranslateNotifications.BUBBLE)
            .setSmallIcon(R.drawable.ic_tile_translate_screen)
            .setContentTitle(getString(R.string.notification_bubble_title))
            .setContentText(getString(R.string.notification_bubble_text))
            .setStyle(Notification.BigTextStyle().bigText(getString(R.string.notification_bubble_text)))
            .setContentIntent(settings)
            .addAction(stopAction)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    // ---------------------------------------------------------------------
    // The bubble
    // ---------------------------------------------------------------------

    /** A context for overlay windows (a window context on Android 11+). */
    private fun overlayContext(): Context {
        windowContext?.let { return it }
        val context = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val display = getSystemService(DisplayManager::class.java)
                ?.getDisplay(Display.DEFAULT_DISPLAY)
            if (display == null) {
                this
            } else {
                createDisplayContext(display)
                    .createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
            }
        } else {
            this
        }
        windowContext = context
        return context
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    /** Adds the bubble (once); false when the system refuses the overlay. */
    private fun showBubble(): Boolean {
        if (bubble != null) return true
        val context = overlayContext()
        val manager = context.getSystemService(WindowManager::class.java) ?: return false
        windowManager = manager
        val size = dp(BUBBLE_DP)
        val view = ImageView(context).apply {
            setImageResource(R.drawable.ic_bubble_translate)
            setBackgroundResource(R.drawable.bubble_background)
            scaleType = ImageView.ScaleType.CENTER
            contentDescription = getString(R.string.bubble_description)
            isClickable = true
            isLongClickable = true
            isHapticFeedbackEnabled = true
            setOnClickListener { translateScreen() }
            setOnLongClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                translateClipboard()
                true
            }
            setOnTouchListener(DragHandler())
            accessibilityDelegate = BubbleAccessibility()
        }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val params = WindowManager.LayoutParams(
            size,
            size,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val screen = screenBounds()
            x = if (prefs.getBoolean(KEY_LEFT, false)) screen.left else screen.right - size
            y = screen.top + ((screen.height() - size) * prefs.getFloat(KEY_Y, DEFAULT_Y)).roundToInt()
        }
        bubble = view
        bubbleParams = params
        if (!attachBubble()) {
            bubble = null
            bubbleParams = null
            return false
        }
        snapToSide(animate = false)
        return true
    }

    private fun attachBubble(): Boolean {
        val view = bubble ?: return false
        if (bubbleAttached) return true
        return try {
            windowManager?.addView(view, bubbleParams)
            bubbleAttached = true
            true
        } catch (e: WindowManager.BadTokenException) {
            false
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalStateException) {
            false
        }
    }

    private fun detachBubble() {
        val view = bubble ?: return
        if (!bubbleAttached) return
        bubbleAttached = false
        try {
            windowManager?.removeViewImmediate(view)
        } catch (e: IllegalArgumentException) {
            // Already gone.
        }
    }

    /** Hidden while a Mozhi window is on screen, shown otherwise. */
    private fun updateBubbleVisibility() {
        if (bubble == null) return
        if (visibleActivities.isEmpty()) {
            if (!bubbleAttached && attachBubble()) snapToSide(animate = false)
        } else {
            snap?.cancel()
            hideTarget()
            detachBubble()
        }
    }

    private fun translateScreen() {
        try {
            startActivity(ScreenTranslateActivity.launchIntent(this))
        } catch (e: ActivityNotFoundException) {
            return
        }
        // Out of the screenshot at once (the window hides it too).
        detachBubble()
    }

    private fun translateClipboard() {
        try {
            startActivity(
                Intent(this, BubbleClipboardActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        } catch (e: ActivityNotFoundException) {
            // Cannot happen for our own activity.
        }
    }

    /** Dismissed: the bubble goes and the service stops. */
    private fun remove() {
        hideTarget()
        detachBubble()
        stopBubble()
    }

    // ---------------------------------------------------------------------
    // Position
    // ---------------------------------------------------------------------

    /**
     * Where the bubble may be: the screen without the system bars and the
     * cutout, minus a margin; `right`/`bottom` are the farthest edges.
     */
    private fun screenBounds(): Rect {
        val manager = windowManager ?: overlayContext().getSystemService(WindowManager::class.java)
        val margin = dp(MARGIN_DP)
        val bounds: Rect
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && manager != null) {
            val metrics = manager.currentWindowMetrics
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            val full = metrics.bounds
            bounds = Rect(
                insets.left,
                insets.top,
                full.width() - insets.right,
                full.height() - insets.bottom,
            )
        } else {
            val metrics = DisplayMetrics()
            if (manager != null) {
                @Suppress("DEPRECATION")
                manager.defaultDisplay.getRealMetrics(metrics)
            } else {
                metrics.setTo(resources.displayMetrics)
            }
            bounds = Rect(0, dp(LEGACY_TOP_DP), metrics.widthPixels, metrics.heightPixels - dp(LEGACY_BOTTOM_DP))
        }
        bounds.inset(margin, margin)
        if (bounds.width() < 0 || bounds.height() < 0) bounds.set(0, 0, dp(BUBBLE_DP), dp(BUBBLE_DP))
        return bounds
    }

    /** To the nearest side, within the screen; remembers where. */
    private fun snapToSide(animate: Boolean) {
        val view = bubble ?: return
        val params = bubbleParams ?: return
        if (!bubbleAttached) return
        val size = dp(BUBBLE_DP)
        val screen = screenBounds()
        val left = params.x + size / 2 < screen.centerX()
        val toX = if (left) screen.left else maxOf(screen.left, screen.right - size)
        val toY = params.y.coerceIn(screen.top, maxOf(screen.top, screen.bottom - size))
        val travel = screen.height() - size
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_LEFT, left)
            .putFloat(KEY_Y, if (travel > 0) (toY - screen.top).toFloat() / travel else DEFAULT_Y)
            .apply()
        snap?.cancel()
        if (!animate) {
            params.x = toX
            params.y = toY
            updateLayout(view, params)
            return
        }
        val fromX = params.x
        val fromY = params.y
        snap = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = SNAP_MILLIS
            addUpdateListener { animator ->
                val f = animator.animatedValue as Float
                params.x = (fromX + (toX - fromX) * f).roundToInt()
                params.y = (fromY + (toY - fromY) * f).roundToInt()
                updateLayout(view, params)
            }
            start()
        }
    }

    private fun updateLayout(view: View, params: WindowManager.LayoutParams) {
        if (!bubbleAttached) return
        try {
            windowManager?.updateViewLayout(view, params)
        } catch (e: IllegalArgumentException) {
            // Not attached any more.
        }
    }

    // ---------------------------------------------------------------------
    // Remove target
    // ---------------------------------------------------------------------

    private fun showTarget() {
        val manager = windowManager ?: return
        if (targetAttached) return
        val size = dp(TARGET_DP)
        val view = target ?: ImageView(overlayContext()).apply {
            setImageResource(R.drawable.ic_bubble_remove)
            setBackgroundResource(R.drawable.bubble_remove_background)
            scaleType = ImageView.ScaleType.CENTER
            contentDescription = getString(R.string.bubble_remove_target)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }.also { target = it }
        val params = WindowManager.LayoutParams(
            size,
            size,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val screen = screenBounds()
            x = screen.centerX() - size / 2
            y = screen.bottom - size - dp(TARGET_BOTTOM_DP)
        }
        targetParams = params
        try {
            manager.addView(view, params)
            targetAttached = true
        } catch (e: WindowManager.BadTokenException) {
            targetAttached = false
        } catch (e: IllegalStateException) {
            targetAttached = false
        }
        overTarget = false
        view.scaleX = 1f
        view.scaleY = 1f
    }

    private fun hideTarget() {
        val view = target ?: return
        if (!targetAttached) return
        targetAttached = false
        overTarget = false
        try {
            windowManager?.removeViewImmediate(view)
        } catch (e: IllegalArgumentException) {
            // Already gone.
        }
    }

    /** Whether the bubble's centre is over the remove target. */
    private fun isOverTarget(): Boolean {
        val params = bubbleParams ?: return false
        val targetParams = targetParams ?: return false
        if (!targetAttached) return false
        val half = dp(BUBBLE_DP) / 2f
        val targetHalf = dp(TARGET_DP) / 2f
        val distance = hypot(
            (params.x + half) - (targetParams.x + targetHalf),
            (params.y + half) - (targetParams.y + targetHalf),
        )
        return distance < dp(TARGET_RADIUS_DP)
    }

    private fun updateTargetHighlight() {
        val view = target ?: return
        val over = isOverTarget()
        if (over == overTarget) return
        overTarget = over
        val scale = if (over) TARGET_ACTIVE_SCALE else 1f
        view.animate().scaleX(scale).scaleY(scale).setDuration(TARGET_ANIMATION_MILLIS).start()
        if (over) bubble?.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
    }

    // ---------------------------------------------------------------------
    // Touch and accessibility
    // ---------------------------------------------------------------------

    /**
     * Tap, long press and drag on one view: a movement beyond the touch
     * slop starts a drag (and cancels the long press); a tap and a long
     * press go through [View.performClick] / [View.performLongClick], so
     * screen readers trigger the same actions.
     */
    private inner class DragHandler : View.OnTouchListener {
        private val slop = ViewConfiguration.get(overlayContext()).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var longPressed = false
        private var view: View? = null
        private val longPress = Runnable {
            if (!dragging) {
                longPressed = true
                view?.isPressed = false
                view?.performLongClick()
            }
        }

        override fun onTouch(v: View, event: MotionEvent): Boolean {
            val params = bubbleParams ?: return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    snap?.cancel()
                    view = v
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    longPressed = false
                    v.isPressed = true
                    main.postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragging && !longPressed && hypot(dx, dy) > slop) {
                        dragging = true
                        main.removeCallbacks(longPress)
                        v.isPressed = false
                        showTarget()
                    }
                    if (dragging) {
                        params.x = startX + dx.roundToInt()
                        params.y = startY + dy.roundToInt()
                        updateLayout(v, params)
                        updateTargetHighlight()
                    }
                }
                MotionEvent.ACTION_UP -> {
                    main.removeCallbacks(longPress)
                    v.isPressed = false
                    when {
                        dragging && isOverTarget() -> remove()
                        dragging -> {
                            hideTarget()
                            snapToSide(animate = true)
                        }
                        !longPressed -> v.performClick()
                    }
                    dragging = false
                }
                MotionEvent.ACTION_CANCEL -> {
                    main.removeCallbacks(longPress)
                    v.isPressed = false
                    if (dragging) {
                        hideTarget()
                        snapToSide(animate = true)
                    }
                    dragging = false
                }
            }
            return true
        }
    }

    /** Names the long press and adds "Remove the bubble" for screen readers. */
    private inner class BubbleAccessibility : View.AccessibilityDelegate() {
        override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(host, info)
            info.addAction(
                AccessibilityNodeInfo.AccessibilityAction(
                    AccessibilityNodeInfo.ACTION_LONG_CLICK,
                    getString(R.string.bubble_long_press_action),
                ),
            )
            info.addAction(
                AccessibilityNodeInfo.AccessibilityAction(
                    R.id.bubble_action_remove,
                    getString(R.string.bubble_remove_action),
                ),
            )
        }

        override fun performAccessibilityAction(host: View, action: Int, args: Bundle?): Boolean {
            if (action == R.id.bubble_action_remove) {
                remove()
                return true
            }
            return super.performAccessibilityAction(host, action, args)
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    companion object {
        /** Stops the bubble (the notification's Stop action). */
        const val ACTION_STOP = "io.github.aimdi.mozhi.action.STOP_BUBBLE"

        /** The bubble's row in the settings (General › Android integration). */
        const val SETTINGS_LINK = "mozhi://settings/general?row=translate_bubble"

        /** Whether the bubble is on (the service runs in the app's process). */
        @Volatile
        var isRunning = false
            private set

        private const val NOTIFICATION_ID = 0x5c7f
        private const val REQUEST_STOP = 1
        private const val REQUEST_SETTINGS = 2
        private const val PREFS = "translate_bubble"
        private const val KEY_LEFT = "left"
        private const val KEY_Y = "y"
        private const val DEFAULT_Y = 0.4f
        private const val BUBBLE_DP = 56
        private const val MARGIN_DP = 4
        private const val LEGACY_TOP_DP = 24
        private const val LEGACY_BOTTOM_DP = 48
        private const val TARGET_DP = 64
        private const val TARGET_BOTTOM_DP = 32
        private const val TARGET_RADIUS_DP = 72
        private const val TARGET_ACTIVE_SCALE = 1.25f
        private const val TARGET_ANIMATION_MILLIS = 120L
        private const val SNAP_MILLIS = 220L

        /** Starts the bubble; the caller checked "Display over other apps". */
        fun start(context: Context) {
            val intent = Intent(context, TranslateBubbleService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TranslateBubbleService::class.java))
        }
    }
}
