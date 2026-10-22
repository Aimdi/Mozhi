import 'package:tesseract_ocr/src/engine/ocr_engine.dart';

/// Whether the native engine can run here: never on the web.
bool get tesseractPlatformSupported => false;

/// An engine that is not available on this platform.
OcrEngine createTesseractEngine({String? libraryPath}) =>
    const UnsupportedOcrEngine();

/// The engine on platforms without `dart:ffi` (web): every call fails.
final class UnsupportedOcrEngine implements OcrEngine {
  const new();

  @override
  Future<OcrResult> recognize(
    OcrImage image, {
    required String dataPath,
    required List<String> languages,
    bool layout = false,
  }) => Future.error(
    UnsupportedError('On-device text recognition is not available here'),
  );

  @override
  Future<void> release() async {}

  @override
  Future<void> dispose() async {}
}
