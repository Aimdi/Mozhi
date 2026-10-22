import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tesseract_ocr/src/engine/ffi/bindings.dart';
import 'package:tesseract_ocr/src/engine/ocr_engine.dart';
import 'package:tesseract_ocr/src/engine/ocr_layout.dart';

/// Synchronous access to the native engine with a small cache of loaded
/// language sets. Blocks the calling isolate: only used inside the OCR
/// isolate (see `IsolateTesseractEngine`).
final class NativeTesseractEngine {
  new(this._bindings, {this.maxLoaded = 2})
    : assert(maxLoaded >= 1, 'At least one engine must stay loaded');

  /// Opens the library ([TesseractBindings.open]) and checks its ABI.
  factory open({String? libraryPath, int maxLoaded = 2}) {
    final TesseractBindings bindings;
    try {
      bindings = TesseractBindings(TesseractBindings.open(libraryPath));
    } on Object catch (error) {
      throw TesseractEngineException('Cannot load the native engine: $error');
    }
    final abi = bindings.abiVersion();
    if (abi != TesseractBindings.expectedAbiVersion) {
      throw TesseractEngineException(
        'Native engine ABI $abi, expected '
        '${TesseractBindings.expectedAbiVersion}',
      );
    }
    return NativeTesseractEngine(bindings, maxLoaded: maxLoaded);
  }

  final TesseractBindings _bindings;

  /// Language sets kept loaded (each is a Tesseract engine with its data
  /// in memory, a few to some tens of MB).
  final int maxLoaded;

  /// Loaded engines by `<dataPath>|<languages>`, least recently used first.
  final LinkedHashMap<String, Pointer<NativeTesseract>> _engines =
      LinkedHashMap();

  /// Engine version, e.g. `tesseract 5.5.3, leptonica-1.87.0`.
  String get version => _bindings.version().toDartString();

  /// Keys of the loaded engines, least recently used first.
  List<String> get loaded => List.unmodifiable(_engines.keys);

  /// Recognises the text in [pixels] (see [OcrImage] for the layout), and
  /// with [layout] where it is ([OcrResult.layout], words included).
  OcrResult recognize(
    Uint8List pixels, {
    required int width,
    required int height,
    required int bytesPerPixel,
    required int bytesPerLine,
    required String dataPath,
    required List<String> languages,
    bool layout = false,
  }) {
    if (languages.isEmpty) {
      throw ArgumentError.value(languages, 'languages', 'Must not be empty');
    }
    final engine = _load(dataPath, languages.join('+'));
    return using((arena) {
      final native = arena<Uint8>(pixels.length);
      native.asTypedList(pixels.length).setAll(0, pixels);
      if (layout) {
        final output = _bindings.recognizeLayout(
          engine,
          native,
          width,
          height,
          bytesPerPixel,
          bytesPerLine,
          TesseractBindings.layoutWords,
        );
        if (output == nullptr) _fail('recognize');
        try {
          return parseLayoutResult(output.toDartString());
        } finally {
          _bindings.freeString(output);
        }
      }
      final confidence = arena<Int32>();
      final output = _bindings.recognize(
        engine,
        native,
        width,
        height,
        bytesPerPixel,
        bytesPerLine,
        confidence,
      );
      if (output == nullptr) _fail('recognize');
      try {
        return OcrResult(
          text: output.toDartString().trim(),
          meanConfidence: confidence.value,
        );
      } finally {
        _bindings.freeString(output);
      }
    });
  }

  /// The [OcrResult] of `mozhi_tesseract_recognize_layout`'s [json]. Throws
  /// [TesseractEngineException] when it is not that JSON.
  static OcrResult parseLayoutResult(String json) {
    try {
      final map = jsonDecode(json) as Map<String, Object?>;
      return OcrResult(
        text: (map['text']! as String).trim(),
        meanConfidence: (map['confidence'] as num?)?.toInt() ?? 0,
        layout: OcrLayout.fromJson(map),
      );
    } on Object catch (error) {
      throw TesseractEngineException(
        'Unexpected layout from the engine: $error',
      );
    }
  }

  /// Unloads every engine.
  void release() {
    _engines.values.forEach(_bindings.destroy);
    _engines.clear();
  }

  Pointer<NativeTesseract> _load(String dataPath, String languages) {
    final key = '$dataPath|$languages';
    final cached = _engines.remove(key);
    if (cached != null) return _engines[key] = cached;
    final engine = using(
      (arena) => _bindings.create(
        dataPath.toNativeUtf8(allocator: arena),
        languages.toNativeUtf8(allocator: arena),
      ),
    );
    if (engine == nullptr) _fail('load $languages');
    _engines[key] = engine;
    while (_engines.length > maxLoaded) {
      _bindings.destroy(_engines.remove(_engines.keys.first)!);
    }
    return engine;
  }

  Never _fail(String operation) {
    final error = _bindings.lastError();
    final message = error == nullptr ? 'unknown error' : error.toDartString();
    throw TesseractEngineException('$operation: $message');
  }
}
