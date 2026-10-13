import 'dart:async';

/// Text handed to the app by the OS.
class SharedText {
  const new(this.text, {this.readOnly = true, this.isProcessText = false});

  final String text;

  /// For Android PROCESS_TEXT: false means the caller accepts a replacement
  /// (see [SharedTextService.returnResult]).
  final bool readOnly;
  final bool isProcessText;
}

/// Bridges Android `ACTION_SEND` (text/plain) and `ACTION_PROCESS_TEXT`
/// intents (and future iOS share extensions) to Dart.
///
/// Platform side (`MainActivity.kt`) exposes:
/// * MethodChannel `io.github.aimdi.mozhi/shared_text`:
///   `getInitialText` -> `{text, readOnly, processText}` | null,
///   `returnResult(text)` -> finishes a PROCESS_TEXT activity with
///   `EXTRA_PROCESS_TEXT` = text.
/// * EventChannel `io.github.aimdi.mozhi/shared_text_events` streaming the
///   same maps for intents received while running (`onNewIntent`).
/// On platforms without the channel everything is a silent no-op.
class SharedTextService {
  Future<SharedText?> initialText() => throw UnimplementedError();
  Stream<SharedText> get texts => throw UnimplementedError();
  Future<void> returnResult(String text) => throw UnimplementedError();
}
