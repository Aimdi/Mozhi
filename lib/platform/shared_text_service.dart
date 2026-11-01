import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text handed to the app by the OS.
@immutable
class SharedText {
  const new(
    this.text, {
    this.readOnly = true,
    this.isProcessText = false,
    this.action,
  });

  /// [action] of the Android quick-settings tile / app shortcut that asks
  /// to translate the clipboard.
  static const translateClipboardAction = 'translateClipboard';

  /// [action] of a selection made with "Translate offline" in Android's
  /// text selection toolbar (PROCESS_TEXT through the
  /// `.TranslateOfflineActivity` alias): it is translated with the
  /// on-device engine only, whatever the privacy mode.
  static const translateOfflineAction = 'translateOffline';

  /// [action] of a selection made with "Improve with Mozhi" in Android's
  /// text selection toolbar (PROCESS_TEXT through the
  /// `.ImproveTextActivity` alias): it is proofread (the quick improve
  /// sheet) instead of translated.
  static const improveAction = 'improve';

  /// The shared text. Empty when the payload only carried an [action].
  final String text;

  /// For Android PROCESS_TEXT: false means the caller accepts a replacement
  /// (see [SharedTextService.returnResult]).
  final bool readOnly;
  final bool isProcessText;

  /// What the OS asked the app to do (e.g. [translateClipboardAction]),
  /// or null for a plain share / selection.
  final String? action;

  /// Whether this asks to translate the clipboard ([text] may be empty).
  bool get isTranslateClipboard => action == translateClipboardAction;

  /// Whether this selection is to be translated on the device only
  /// ([translateOfflineAction]).
  bool get isTranslateOffline => action == translateOfflineAction;

  /// Whether this selection is to be improved (proofread) rather than
  /// translated ([improveAction]).
  bool get isImprove => action == improveAction;

  @override
  bool operator ==(Object other) =>
      other is SharedText &&
      other.text == text &&
      other.readOnly == readOnly &&
      other.isProcessText == isProcessText &&
      other.action == action;

  @override
  int get hashCode => Object.hash(text, readOnly, isProcessText, action);

  @override
  String toString() =>
      'SharedText($text, readOnly: $readOnly, '
      'isProcessText: $isProcessText'
      '${action == null ? '' : ', action: $action'})';
}

/// Bridges Android `ACTION_SEND` (text/plain) and `ACTION_PROCESS_TEXT`
/// intents (and future iOS share extensions) to Dart.
///
/// Platform side (`MainActivity.kt`) exposes:
/// * MethodChannel `io.github.aimdi.mozhi/shared_text`:
///   `getInitialText` -> `{text, readOnly, processText, action}` | null
///   (`action` is optional: `translateClipboard` from the quick-settings
///   tile / app shortcut, which may omit `text`, or `translateOffline` for
///   a PROCESS_TEXT selection made with "Translate offline", which keeps
///   `text`, `readOnly` and `processText: true` and is to be translated on
///   the device only, see [SharedText.isTranslateOffline], or `improve`
///   for one made with "Improve with Mozhi", which keeps the same fields
///   and is to be proofread, see [SharedText.isImprove]),
///   `returnResult(text)` -> finishes a PROCESS_TEXT activity with
///   `EXTRA_PROCESS_TEXT` = text (the argument is the plain string).
/// * EventChannel `io.github.aimdi.mozhi/shared_text_events` streaming the
///   same maps for intents received while running (`onNewIntent`).
/// On platforms without the channel everything is a silent no-op.
///
/// Payloads are parsed defensively: a payload without a non-blank `text`
/// or `action` is ignored (a blank `text` next to an `action` becomes ''),
/// `readOnly` defaults to true, `processText` to false and `action` to
/// null. A plain string payload is accepted as the text.
class SharedTextService {
  new({BinaryMessenger? messenger})
    : _messenger = messenger,
      _methods = MethodChannel(methodChannelName, _codec, messenger),
      _events = EventChannel(eventChannelName, _codec, messenger);

  static const methodChannelName = 'io.github.aimdi.mozhi/shared_text';
  static const eventChannelName = 'io.github.aimdi.mozhi/shared_text_events';
  static const MethodCodec _codec = StandardMethodCodec();

  final BinaryMessenger? _messenger;
  final MethodChannel _methods;
  final EventChannel _events;
  Stream<SharedText>? _texts;

  /// The text the app was launched with, or null.
  Future<SharedText?> initialText() async {
    try {
      return parse(await _methods.invokeMethod<Object?>('getInitialText'));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Texts shared while the app is running (broadcast). Never emits errors;
  /// completes immediately when the platform has no such channel.
  Stream<SharedText> get texts => _texts ??= _eventStream();

  /// Hands [text] back to the app that started a writable PROCESS_TEXT
  /// request (which finishes the activity).
  Future<void> returnResult(String text) async {
    try {
      await _methods.invokeMethod<void>('returnResult', text);
    } on MissingPluginException {
      // Not supported on this platform.
    } on PlatformException {
      // No PROCESS_TEXT request to answer.
    }
  }

  /// Parses a platform payload; null when it carries neither usable text
  /// nor an action.
  static SharedText? parse(Object? payload) {
    return switch (payload) {
      final String text when text.trim().isNotEmpty => SharedText(text),
      final Map<dynamic, dynamic> map => _parseMap(map),
      _ => null,
    };
  }

  static SharedText? _parseMap(Map<dynamic, dynamic> payload) {
    final text = switch (payload['text']) {
      final String text when text.trim().isNotEmpty => text,
      _ => null,
    };
    final action = switch (payload['action']) {
      final String action when action.trim().isNotEmpty => action,
      _ => null,
    };
    if (text == null && action == null) return null;
    return SharedText(
      text ?? '',
      readOnly: switch (payload['readOnly']) {
        final bool readOnly => readOnly,
        _ => true,
      },
      isProcessText: payload['processText'] == true,
      action: action,
    );
  }

  /// Same protocol as [EventChannel.receiveBroadcastStream], but a missing
  /// platform implementation ends the stream silently instead of reporting
  /// a Flutter error.
  Stream<SharedText> _eventStream() {
    final control = MethodChannel(_events.name, _events.codec, _messenger);
    late final StreamController<SharedText> controller;

    void detach() =>
        _events.binaryMessenger.setMessageHandler(_events.name, null);

    controller = StreamController<SharedText>.broadcast(
      onListen: () async {
        _events.binaryMessenger.setMessageHandler(_events.name, (data) async {
          if (data == null || controller.isClosed) return null;
          try {
            final text = parse(_events.codec.decodeEnvelope(data));
            if (text != null) controller.add(text);
          } on PlatformException {
            // Error events carry nothing we could show.
          }
          return null;
        });
        try {
          await control.invokeMethod<void>('listen');
        } on MissingPluginException {
          detach();
          await controller.close();
        } on PlatformException {
          detach();
          await controller.close();
        }
      },
      onCancel: () async {
        detach();
        try {
          await control.invokeMethod<void>('cancel');
        } on MissingPluginException {
          // Nothing to cancel.
        } on PlatformException {
          // Nothing to cancel.
        }
      },
    );
    return controller.stream;
  }
}
