import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/bindings.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';
import 'package:ffi/ffi.dart';

/// [NativeLanguageIdentifier] running CLD2 (`mozhi_bergamot_detect`) in a
/// short-lived background isolate per call ([Isolate.run]).
///
/// Not in the translation isolate: that one is busy for the whole of a long
/// translation, and CLD2 takes no engine lock, so identification never
/// waits for a translation. CLD2 needs ~0.03 ms for a sentence; starting
/// the isolate costs more, but keeps long texts off the UI isolate.
///
/// When the library cannot be loaded, has another ABI or predates the
/// identifier, [identify] returns null, now and for every later call.
final class IsolateLanguageIdentifier implements NativeLanguageIdentifier {
  new({this.libraryPath});

  /// Explicit path of `libmozhi_bergamot.so` (desktop tests); null uses
  /// `$BERGAMOT_LIBRARY_PATH` or the library bundled with the app.
  final String? libraryPath;

  var _unavailable = false;

  @override
  Future<Cld2Detection?> identify(
    String text, {
    List<String> hints = const [],
  }) async {
    if (_unavailable) return null;
    final detection = await _run(libraryPath, text, hints.join(','));
    if (detection == null) _unavailable = true;
    return detection;
  }

  // Static, so the closure sent to the isolate captures only these values.
  static Future<Cld2Detection?> _run(
    String? libraryPath,
    String text,
    String hints,
  ) => Isolate.run(
    () => identifyWithLibrary(libraryPath, text, hints: hints),
    debugName: 'cld2',
  );
}

/// Opens the library ([BergamotBindings.open]) and runs both CLD2 passes
/// over [text] ([identifyWith]). Null when the library cannot be loaded,
/// reports another ABI or has no identifier. Blocks: call it off the UI
/// isolate.
Cld2Detection? identifyWithLibrary(
  String? libraryPath,
  String text, {
  String hints = '',
}) {
  final BergamotBindings bindings;
  try {
    bindings = BergamotBindings(BergamotBindings.open(libraryPath));
  } on Object {
    return null;
  }
  final detect = bindings.detect;
  if (detect == null ||
      bindings.abiVersion() != BergamotBindings.expectedAbiVersion) {
    return null;
  }
  return identifyWith(detect, bindings.lastError, text, hints: hints);
}

/// CLD2's normal answer and its best-effort guess for [text], with
/// [hints] (comma-separated codes, empty for none). Throws
/// [BergamotEngineException] with [lastError]'s message when [detect]
/// fails.
Cld2Detection identifyWith(
  DetectFunction detect,
  Pointer<Utf8> Function() lastError,
  String text, {
  String hints = '',
}) => using((arena) {
  final bytes = utf8.encode(text);
  final input = arena<Uint8>(bytes.length + 1);
  input.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  final hintsPointer = hints.isEmpty
      ? nullptr
      : hints.toNativeUtf8(allocator: arena);
  final out = arena<NativeDetection>();

  Cld2Result pass(int flags) {
    if (detect(input, bytes.length, hintsPointer, flags, out) == 0) {
      final error = lastError();
      throw BergamotEngineException(
        'detect: ${error == nullptr ? 'unknown error' : error.toDartString()}',
      );
    }
    return readDetection(out.ref);
  }

  return Cld2Detection(
    precise: pass(0),
    bestEffort: pass(BergamotBindings.detectBestEffort),
  );
});

/// Copies a [NativeDetection] into Dart objects; `un` slots are dropped.
Cld2Result readDetection(NativeDetection detection) => Cld2Result(
  language: _code(detection.language),
  languages: [
    for (var i = 0; i < 3; i++)
      if (_code(detection.languages[i].code) case final code
          when code.isNotEmpty && code != 'un')
        Cld2Language(
          code,
          percent: detection.languages[i].percent,
          score: detection.languages[i].score,
        ),
  ],
  textBytes: detection.textBytes,
  reliable: detection.reliable != 0,
);

String _code(Array<Uint8> chars) {
  final codes = <int>[];
  for (var i = 0; i < BergamotBindings.codeLength; i++) {
    final char = chars[i];
    if (char == 0) break;
    codes.add(char);
  }
  return String.fromCharCodes(codes);
}
