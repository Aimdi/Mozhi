package io.github.aimdi.mozhi

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Whether a Mozhi window is on screen ([inFront]), for the overlays that
 * hide over Mozhi itself: the live caption bar ([LiveCaptionService]) and
 * the translate bubble ([TranslateBubbleService]).
 *
 * Follows the Mozhi activities on screen (started, not stopped) for the
 * whole process from the first Flutter window's creation on ([follow],
 * called by [LiveCaptionsPlugin] when it attaches to the activity, and by
 * the services when they start). An overlay that only started following
 * when it starts would miss the window that turned it on: that window
 * started earlier, and the dialogs in front of it are translucent (it is
 * only paused, never started again). Main thread only.
 */
object AppWindows {
    /** Hears when a Mozhi window comes on screen or goes. */
    fun interface Listener {
        fun onWindowsChanged()
    }

    private val main = Handler(Looper.getMainLooper())
    private val windows = mutableSetOf<Int>()
    private val listeners = linkedSetOf<Listener>()
    private var following = false

    /** A Mozhi window is on screen. */
    val inFront: Boolean
        get() = windows.isNotEmpty()

    /** Follows [application]'s activities from now on (once). */
    fun follow(application: Application) {
        if (following) return
        following = true
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityStarted(activity: Activity) {
                    // At once: Translate screen's screenshot must not show an overlay.
                    if (windows.add(System.identityHashCode(activity))) changed()
                }

                override fun onActivityStopped(activity: Activity) = gone(activity)

                override fun onActivityDestroyed(activity: Activity) = gone(activity)

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
                override fun onActivityResumed(activity: Activity) {}
                override fun onActivityPaused(activity: Activity) {}
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            },
        )
    }

    fun addListener(listener: Listener) {
        listeners.add(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    private fun gone(activity: Activity) {
        if (!windows.remove(System.identityHashCode(activity))) return
        // Posted: a window recreated for a configuration change is started
        // again first, and an overlay does not flash over it.
        main.post { changed() }
    }

    private fun changed() {
        for (listener in listeners.toList()) listener.onWindowsChanged()
    }
}
