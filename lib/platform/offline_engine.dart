// The on-device translation engine of every build (default and Play):
// Mozilla's Firefox Translations models on the open-source Bergamot engine
// (packages/bergamot_translator). The native engine needs dart:io and
// dart:ffi, so the web gets a stub that is never available.
export 'offline_engine_web.dart'
    if (dart.library.io) 'offline_engine_io.dart';
