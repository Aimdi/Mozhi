import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Whether the browser has the Web Speech API's speech recognition
/// (`SpeechRecognition`, or Chrome's and Safari's `webkitSpeechRecognition`):
/// Firefox and its forks have none.
bool browserHasSpeechRecognition() =>
    // coverage:ignore-start
    globalContext.has('SpeechRecognition') ||
    globalContext.has('webkitSpeechRecognition');
// coverage:ignore-end
