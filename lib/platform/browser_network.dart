// Whether the browser says the connection is metered (the web app's
// "Wi-Fi only" for offline language downloads). dart:js_interop exists
// only in a browser: elsewhere the answer is always "not metered".
export 'browser_network_stub.dart'
    if (dart.library.js_interop) 'browser_network_web.dart';
