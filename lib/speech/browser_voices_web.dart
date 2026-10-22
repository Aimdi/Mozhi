import 'dart:js_interop';

import 'package:mozhi/speech/browser_voices.dart';

@JS('speechSynthesis')
external _SpeechSynthesis? get _speechSynthesis;

extension type _SpeechSynthesis._(JSObject _) implements JSObject {
  external JSArray<_Voice> getVoices();
}

extension type _Voice._(JSObject _) implements JSObject {
  external String get name;
  external String get lang;
  external bool get localService;
}

/// The voices of the browser's `speechSynthesis`, in the browser's order
/// (empty while it is still loading them, or without speech synthesis).
List<BrowserVoice> browserVoices() {
  // coverage:ignore-start
  final synthesis = _speechSynthesis;
  if (synthesis == null) return const [];
  return [
    for (final voice in synthesis.getVoices().toDart)
      (name: voice.name, lang: voice.lang, localService: voice.localService),
  ];
  // coverage:ignore-end
}
