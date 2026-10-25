// What the browser's storage quota leaves the web app (the Storage API).
// dart:js_interop exists only in a browser: elsewhere it is unknown.
export 'free_space_browser_stub.dart'
    if (dart.library.js_interop) 'free_space_browser_web.dart';
