// The native engine needs dart:ffi, which web builds cannot even import:
// web gets the WebAssembly worker factory (dart:js_interop), other platforms
// without FFI get a stub, so the package can be imported by the whole app.
export 'engine_factory_stub.dart'
    if (dart.library.ffi) 'engine_factory_ffi.dart'
    if (dart.library.js_interop) 'engine_factory_web.dart';
