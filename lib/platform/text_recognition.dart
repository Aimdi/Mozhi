// On-device text recognition of the default build: Tesseract with
// tessdata_fast language data (packages/tesseract_ocr, no Google code),
// used by lib/platform/mlkit_bindings.dart. The engine needs dart:io and
// dart:ffi, so the web gets a recognizer that is never available.
export 'text_recognition_web.dart'
    if (dart.library.io) 'text_recognition_io.dart';
