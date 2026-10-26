package io.github.aimdi.mozhi

import android.annotation.TargetApi
import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Collections
import java.util.WeakHashMap

/**
 * The app lock's platform side (`lib/app_lock/data/app_lock_platform.dart`),
 * method channel [CHANNEL], added to every Flutter engine of the app by
 * [MainActivity.configureFlutterEngine] (so also to the quick translate and
 * screen-translate windows):
 *
 * - `session()` answers the lock state of the app process, which every
 *   window shares ([AppLockSession]): `{secure, unlocked, awayMs, ownTripMs,
 *   currentMs, currentIsOwnTrip, inFront}` (milliseconds, -1 for none).
 *   `secure` is [KeyguardManager.isDeviceSecure] (a PIN, pattern or password
 *   is set): without it there is nothing to unlock with.
 * - `setUnlocked(Boolean)` records whether the app is unlocked and starts
 *   counting absences anew.
 * - `authenticate({title, subtitle, fallback})` shows the system prompt and
 *   answers `success`, `cancelled`, `unavailable` (no secure lock screen),
 *   `busy` (a prompt of this window is showing) or `error`. Android 11+:
 *   [BiometricPrompt] with `BIOMETRIC_WEAK or DEVICE_CREDENTIAL` (a
 *   fingerprint, face or the screen lock); Android 10: [BiometricPrompt] with
 *   the device credential allowed; Android 9: [BiometricPrompt] whose
 *   negative button ([fallback]), or the lack of enrolled biometrics, goes
 *   to the screen lock; Android 7 and 8: the screen lock
 *   ([KeyguardManager.createConfirmDeviceCredentialIntent]). Framework APIs
 *   only (no androidx.biometric); `USE_BIOMETRIC` is declared in the
 *   manifest.
 * - `setProtected(Boolean)` keeps the window out of Recents' previews while
 *   the lock is on: [Activity.setRecentsScreenshotEnabled] on Android 13+,
 *   `FLAG_SECURE` before (which also blocks screenshots), merged with the
 *   "Hide content in recents" setting by [setSecureFlag].
 *
 * Absences are measured here, not in Dart: [AppLockSession] watches every
 * activity of the app ([Application.ActivityLifecycleCallbacks]) with
 * [SystemClock.elapsedRealtime], which keeps counting while the phone sleeps
 * and does not change with the phone's clock. An activity that Mozhi starts
 * for a result to pick or save a file or take a photo ([isOwnTripIntent]:
 * a file or photo picker, the camera, saving a file, also through a
 * chooser; and Translate screen's screen-capture consent;
 * [noteActivityStartedForResult], from [MainActivity.startActivityForResult])
 * makes the absence an "own trip", which Dart gives more time. Anything
 * else Mozhi starts for a result is an ordinary absence: above all the
 * share sheet (share_plus starts its chooser for a result too), which hands
 * the text to another app the user stays in.
 */
class AppLockPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null

    /** The pending `authenticate` call. */
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationSignal? = null

    /** Whether the screen lock was already asked for in the pending call. */
    private var credentialRequested = false

    /** Whether Dart asked to keep this window out of Recents. */
    private var protectRequested = false

    override fun onAttachedToEngine(pluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val application = pluginBinding.applicationContext as? Application
        if (application != null) AppLockSession.install(application)
        context = pluginBinding.applicationContext
        channel = MethodChannel(pluginBinding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(pluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(activityBinding: ActivityPluginBinding) {
        attach(activityBinding)
    }

    override fun onReattachedToActivityForConfigChanges(activityBinding: ActivityPluginBinding) {
        attach(activityBinding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    private fun attach(activityBinding: ActivityPluginBinding) {
        binding = activityBinding
        activityBinding.addActivityResultListener(this)
        if (protectRequested) applyProtection(activityBinding.activity, true)
    }

    private fun detach() {
        binding?.removeActivityResultListener(this)
        binding = null
        // A prompt can't outlive its window.
        cancellation?.cancel()
        cancellation = null
        finish(RESULT_CANCELLED)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "session" -> result.success(AppLockSession.snapshot(isDeviceSecure()))
            "setUnlocked" -> {
                val unlocked = call.arguments as? Boolean
                if (unlocked == null) {
                    result.error("invalid_argument", "setUnlocked expects a Boolean", null)
                } else {
                    AppLockSession.setUnlocked(unlocked)
                    result.success(null)
                }
            }
            "setProtected" -> {
                val enabled = call.arguments as? Boolean
                if (enabled == null) {
                    result.error("invalid_argument", "setProtected expects a Boolean", null)
                } else {
                    protectRequested = enabled
                    binding?.activity?.let { applyProtection(it, enabled) }
                    result.success(null)
                }
            }
            "authenticate" -> authenticate(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        // Whatever Mozhi started for a result is back.
        AppLockSession.ownTripRequested = false
        if (requestCode != REQUEST_CONFIRM_CREDENTIAL) return false
        finish(if (resultCode == Activity.RESULT_OK) RESULT_SUCCESS else RESULT_CANCELLED)
        return true
    }

    private fun isDeviceSecure(): Boolean {
        val keyguard = context?.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        return keyguard?.isDeviceSecure == true
    }

    private fun authenticate(call: MethodCall, result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.success(RESULT_ERROR)
            return
        }
        if (pending != null) {
            result.success(RESULT_BUSY)
            return
        }
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard == null || !keyguard.isDeviceSecure) {
            result.success(RESULT_UNAVAILABLE)
            return
        }
        // BiometricPrompt refuses an empty title or negative button.
        val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: DEFAULT_TITLE
        val subtitle = call.argument<String>("subtitle")?.takeIf { it.isNotBlank() }
        val fallback = call.argument<String>("fallback")?.takeIf { it.isNotBlank() }
            ?: DEFAULT_FALLBACK
        pending = result
        credentialRequested = false
        AppLockSession.authenticating = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            showBiometricPrompt(activity, keyguard, title, subtitle, fallback)
        } else {
            confirmCredential(activity, keyguard, title, subtitle)
        }
    }

    /** [BiometricPrompt] (Android 9+), see the class documentation. */
    @TargetApi(Build.VERSION_CODES.P)
    @Suppress("DEPRECATION")
    private fun showBiometricPrompt(
        activity: Activity,
        keyguard: KeyguardManager,
        title: String,
        subtitle: String?,
        fallback: String,
    ) {
        try {
            val executor = activity.mainExecutor
            val builder = BiometricPrompt.Builder(activity).setTitle(title)
            if (subtitle != null) builder.setSubtitle(subtitle)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_WEAK or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setDeviceCredentialAllowed(true)
            } else {
                // Android 9 can't offer the screen lock itself.
                builder.setNegativeButton(fallback, executor) { _, _ ->
                    cancellation = null
                    confirmCredential(activity, keyguard, title, subtitle)
                }
            }
            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult?,
                ) {
                    cancellation = null
                    finish(RESULT_SUCCESS)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    cancellation = null
                    // The screen lock took over (Android 9's negative
                    // button): its result answers.
                    if (credentialRequested) return
                    when {
                        // Android 9: no biometrics (or locked out, or the
                        // negative button): the screen lock instead.
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                            errorCode in FALLBACK_ERRORS ->
                            confirmCredential(activity, keyguard, title, subtitle)
                        errorCode in CANCEL_ERRORS -> finish(RESULT_CANCELLED)
                        else -> finish(RESULT_ERROR)
                    }
                }

                // onAuthenticationFailed: one attempt failed; the prompt stays.
            }
            val signal = CancellationSignal()
            cancellation = signal
            builder.build().authenticate(signal, executor, callback)
        } catch (e: RuntimeException) {
            // E.g. no biometric service on Android 9: the screen lock then.
            cancellation = null
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                confirmCredential(activity, keyguard, title, subtitle)
            } else {
                finish(RESULT_ERROR)
            }
        }
    }

    /** The screen lock's own screen (Android 7 to 9). */
    @Suppress("DEPRECATION")
    private fun confirmCredential(
        activity: Activity,
        keyguard: KeyguardManager,
        title: String,
        subtitle: String?,
    ) {
        if (pending == null || credentialRequested) return
        credentialRequested = true
        val intent = keyguard.createConfirmDeviceCredentialIntent(title, subtitle)
        if (intent == null) {
            // No secure lock screen after all.
            finish(RESULT_UNAVAILABLE)
            return
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CONFIRM_CREDENTIAL)
        } catch (e: ActivityNotFoundException) {
            finish(RESULT_ERROR)
        }
    }

    /** Answers the pending `authenticate` call with [outcome], once. */
    private fun finish(outcome: String) {
        val result = pending ?: return
        pending = null
        credentialRequested = false
        AppLockSession.endAuthentication()
        result.success(outcome)
    }

    private fun applyProtection(activity: Activity, enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(!enabled)
        } else {
            setSecureFlag(activity, SECURE_LOCK, enabled)
        }
    }

    companion object {
        /** See `MethodChannelAppLockPlatform.channelName`. */
        const val CHANNEL = "io.github.aimdi.mozhi/app_lock"

        /** The reason of the "Hide content in recents" setting ([setSecureFlag]). */
        const val SECURE_SETTING = "setting"

        /** The app lock's reason (Android 12 and older) ([setSecureFlag]). */
        private const val SECURE_LOCK = "appLock"

        private const val REQUEST_CONFIRM_CREDENTIAL = 0x4d4c // "ML"
        private const val RESULT_SUCCESS = "success"
        private const val RESULT_CANCELLED = "cancelled"
        private const val RESULT_UNAVAILABLE = "unavailable"
        private const val RESULT_BUSY = "busy"
        private const val RESULT_ERROR = "error"
        private const val DEFAULT_TITLE = "Mozhi"
        private const val DEFAULT_FALLBACK = "PIN"

        // BiometricPrompt.BIOMETRIC_ERROR_* (the values are part of the API).
        private const val ERROR_HW_UNAVAILABLE = 1
        private const val ERROR_TIMEOUT = 3
        private const val ERROR_CANCELED = 5
        private const val ERROR_LOCKOUT = 7
        private const val ERROR_LOCKOUT_PERMANENT = 9
        private const val ERROR_USER_CANCELED = 10
        private const val ERROR_NO_BIOMETRICS = 11
        private const val ERROR_HW_NOT_PRESENT = 12
        private const val ERROR_NEGATIVE_BUTTON = 13

        /** Android 9: errors after which the screen lock is offered instead. */
        private val FALLBACK_ERRORS = setOf(
            ERROR_HW_UNAVAILABLE,
            ERROR_LOCKOUT,
            ERROR_LOCKOUT_PERMANENT,
            ERROR_NO_BIOMETRICS,
            ERROR_HW_NOT_PRESENT,
            ERROR_NEGATIVE_BUTTON,
        )

        /** Errors that mean the user (or the system) closed the prompt. */
        private val CANCEL_ERRORS = setOf(
            ERROR_TIMEOUT,
            ERROR_CANCELED,
            ERROR_USER_CANCELED,
            ERROR_NEGATIVE_BUTTON,
        )

        /** Why each window wants `FLAG_SECURE` ([setSecureFlag]). */
        private val secureReasons = WeakHashMap<Activity, MutableSet<String>>()

        /**
         * Sets or clears one [reason] for `FLAG_SECURE` on [activity]'s window
         * (the "Hide content in recents" setting, [SECURE_SETTING], and the app
         * lock below Android 13): the flag is on while any reason is, so
         * neither turns the other's off.
         */
        fun setSecureFlag(activity: Activity, reason: String, enabled: Boolean) {
            val reasons = secureReasons.getOrPut(activity) { mutableSetOf() }
            if (enabled) reasons.add(reason) else reasons.remove(reason)
            if (reasons.isEmpty()) {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }

        /**
         * A Mozhi activity starts another one for a result. With [ownTrip]
         * (a picker, the camera, saving a file: [isOwnTripIntent]) the
         * absence that follows is part of using the app; otherwise (the
         * share sheet, ...) it is an ordinary one, also when an own trip was
         * asked for just before. Called by [MainActivity.startActivityForResult].
         */
        fun noteActivityStartedForResult(ownTrip: Boolean) {
            AppLockSession.ownTripRequested = ownTrip
        }

        /**
         * The actions of the activities whose trip is part of using Mozhi:
         * picking a file, a folder or a photo, saving a file and taking a
         * photo. The photo picker of image_picker (androidx `PickVisualMedia`)
         * is `MediaStore.ACTION_PICK_IMAGES` (Android 13+, or 11+ with the
         * SDK extension; a literal here, the constant needs API 33) or one
         * of its fallbacks, else `ACTION_OPEN_DOCUMENT`.
         */
        private val OWN_TRIP_ACTIONS = setOf(
            Intent.ACTION_OPEN_DOCUMENT,
            Intent.ACTION_CREATE_DOCUMENT,
            Intent.ACTION_OPEN_DOCUMENT_TREE,
            Intent.ACTION_GET_CONTENT,
            Intent.ACTION_PICK,
            MediaStore.ACTION_IMAGE_CAPTURE,
            "android.provider.action.PICK_IMAGES",
            "androidx.activity.result.contract.action.PICK_IMAGES",
            "com.google.android.gms.provider.action.PICK_IMAGES",
        )

        /**
         * Whether starting [intent] for a result is an own trip: its action
         * is one of [OWN_TRIP_ACTIONS], or it is a chooser
         * ([Intent.createChooser], [Intent.ACTION_CHOOSER]) of such an
         * intent ([Intent.EXTRA_INTENT]). A chooser of `ACTION_SEND` or
         * `ACTION_SEND_MULTIPLE` (sharing) is not, nor is anything else.
         */
        fun isOwnTripIntent(intent: Intent): Boolean {
            val action = intent.action ?: return false
            if (action != Intent.ACTION_CHOOSER) return action in OWN_TRIP_ACTIONS
            val targetAction = chooserTarget(intent)?.action ?: return false
            return targetAction in OWN_TRIP_ACTIONS
        }

        /** The intent a chooser offers apps for; null when it has none. */
        @Suppress("DEPRECATION")
        private fun chooserTarget(chooser: Intent): Intent? = try {
            // The typed getter is unreliable on Android 13 (as IntentCompat
            // knows), so it is used from 14 on.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            }
        } catch (e: RuntimeException) {
            // E.g. a BadParcelableException: not known to be a picker.
            null
        }
    }
}

/**
 * The app lock state of the app process, shared by every window (each has
 * its own Flutter engine and [AppLockPlugin]): whether the app is unlocked,
 * and how long it was away from the screen since. Main thread only.
 *
 * An absence starts when the last started activity of the app stops (not
 * for a configuration change, and not while an unlock prompt shows: the
 * screen lock may be a screen of its own) and ends when one starts again.
 * Activities are counted by identity, so one that started before the
 * callbacks were registered (e.g. the share sheet's receiver) is ignored.
 */
internal object AppLockSession : Application.ActivityLifecycleCallbacks {
    private const val NONE = -1L

    private var installed = false
    private val started: MutableSet<Activity> = Collections.newSetFromMap(WeakHashMap())

    /** Whether the app is unlocked ([setUnlocked]). */
    private var unlockedFlag = false

    /** Whether an unlock prompt shows (absences are not counted then). */
    var authenticating = false

    /**
     * Set when a Mozhi activity started a picker, the camera or a save
     * dialog for a result ([AppLockPlugin.isOwnTripIntent]); the absence
     * that starts next is an own trip. Cleared when that absence ends, when
     * a result arrives, when a Mozhi activity resumes and when it starts
     * anything else for a result (the share sheet).
     */
    var ownTripRequested = false

    private var awaySince = NONE
    private var awayIsOwnTrip = false
    private var longestAway = NONE
    private var longestOwnTrip = NONE

    fun install(application: Application) {
        if (installed) return
        installed = true
        application.registerActivityLifecycleCallbacks(this)
    }

    fun setUnlocked(value: Boolean) {
        unlockedFlag = value
        longestAway = NONE
        longestOwnTrip = NONE
    }

    /** The prompt ended; if no window is in front, the absence starts now. */
    fun endAuthentication() {
        authenticating = false
        if (started.isEmpty() && awaySince == NONE) {
            awaySince = SystemClock.elapsedRealtime()
            awayIsOwnTrip = false
        }
    }

    fun snapshot(secure: Boolean): Map<String, Any> {
        val current = if (started.isEmpty() && awaySince != NONE) {
            SystemClock.elapsedRealtime() - awaySince
        } else {
            NONE
        }
        val currentIsOwnTrip = current != NONE && awayIsOwnTrip
        val away = if (current != NONE && !currentIsOwnTrip) maxOf(longestAway, current) else longestAway
        val ownTrip = if (currentIsOwnTrip) maxOf(longestOwnTrip, current) else longestOwnTrip
        return mapOf(
            "secure" to secure,
            "unlocked" to unlockedFlag,
            "awayMs" to away,
            "ownTripMs" to ownTrip,
            "currentMs" to current,
            "currentIsOwnTrip" to currentIsOwnTrip,
            "inFront" to started.isNotEmpty(),
        )
    }

    override fun onActivityStarted(activity: Activity) {
        if (started.isEmpty() && awaySince != NONE) {
            val away = SystemClock.elapsedRealtime() - awaySince
            if (awayIsOwnTrip) {
                longestOwnTrip = maxOf(longestOwnTrip, away)
            } else {
                longestAway = maxOf(longestAway, away)
            }
            awaySince = NONE
            ownTripRequested = false
        }
        started.add(activity)
    }

    override fun onActivityStopped(activity: Activity) {
        if (!started.remove(activity)) return
        if (started.isEmpty() && !authenticating && !activity.isChangingConfigurations) {
            awaySince = SystemClock.elapsedRealtime()
            awayIsOwnTrip = ownTripRequested
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

    override fun onActivityResumed(activity: Activity) {
        // What it started for a result came back without the app leaving
        // the screen (a dialog, a bottom sheet): no trip to remember.
        ownTripRequested = false
    }

    override fun onActivityPaused(activity: Activity) {}

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

    override fun onActivityDestroyed(activity: Activity) {}
}
