// What another tab of the web app changed in the browser's storage (its
// `storage` events). dart:js_interop exists only in a browser: elsewhere
// nothing ever changes.
export 'web_storage_changes_stub.dart'
    if (dart.library.js_interop) 'web_storage_changes_web.dart';
