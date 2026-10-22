// On-device AI (llama.cpp, packages/llama_engine) in every build. The
// engine needs dart:io and dart:ffi, so the web gets a stub without
// on-device AI.
export 'on_device_ai_web.dart' if (dart.library.io) 'on_device_ai_io.dart';
