export 'browser_voices_io.dart'
    if (dart.library.js_interop) 'browser_voices_web.dart';

/// A voice of the browser's `speechSynthesis` (see `browserVoices`): its
/// name, language tag and whether it is synthesised on the device
/// (`SpeechSynthesisVoice.localService`). Chrome's "Google …" voices and
/// Edge's "… Online (Natural)" voices are not: the browser sends the text
/// to its maker's speech service.
typedef BrowserVoice = ({String name, String lang, bool localService});
