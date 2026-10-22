// The native engine needs dart:ffi, which web builds cannot even import:
// the web gets the WebAssembly engine in a worker (web/engine_factory_web.dart,
// dart:js_interop only), other platforms a stub, so the package can be
// imported by the whole app.
export 'engine_factory_stub.dart'
    if (dart.library.ffi) 'engine_factory_ffi.dart'
    if (dart.library.js_interop) 'web/engine_factory_web.dart';
// The web engine's parts are plain Dart (tests run them with a fake worker).
export 'web/web_bergamot.dart';
