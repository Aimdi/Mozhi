// The browser's screen wake lock on the web; nothing elsewhere.
export 'screen_wake_lock_stub.dart'
    if (dart.library.js_interop) 'screen_wake_lock_web.dart';
