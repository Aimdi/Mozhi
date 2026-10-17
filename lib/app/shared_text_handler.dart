import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Text selected in another app (Android `PROCESS_TEXT`, "Translate with
/// Mozhi" or "Translate offline") to show in the quick translate UI.
@immutable
class QuickTranslateRequest {
  const new({
    required this.text,
    required this.onOpenInApp,
    this.onReplace,
    this.offlineOnly = false,
  });

  final String text;

  /// "Translate offline": translate with the on-device engine only, whatever
  /// the privacy mode; the text never goes to a network engine.
  final bool offlineOnly;

  /// Opens [text] in the translate tab ("Open in app").
  final VoidCallback onOpenInApp;

  /// Hands a translation back to the calling app, which replaces the
  /// selection with it; null for read-only selections.
  final ValueChanged<String>? onReplace;

  /// Whether the calling app accepts a replacement.
  bool get canReplace => onReplace != null;
}

/// Reads the clipboard text (null when empty or unavailable).
typedef ClipboardReader = Future<String?> Function();

/// [ClipboardReader] of the platform clipboard.
Future<String?> readClipboardText() async {
  try {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } on PlatformException {
    return null;
  }
}

/// Routes text handed over by the OS to the right screen:
///
/// * a selection in another app (`PROCESS_TEXT`) opens the quick translate
///   UI via [onQuickTranslate], with Replace for writable selections; one
///   made with "Translate offline" ([SharedText.isTranslateOffline]) is
///   marked [QuickTranslateRequest.offlineOnly];
/// * the "translate clipboard" action (quick-settings tile / app shortcut)
///   reads the clipboard ([readClipboard]) and opens it in the translate
///   tab;
/// * anything else (share sheet) opens in the translate tab.
///
/// Text from outside the app goes through
/// [TranslateCubit.setExternalInput]: it is length-capped and never starts
/// a paid AI translation on its own.
class SharedTextHandler {
  new({
    required this.service,
    required this.translateCubit,
    required this.onShowTranslate,
    this.onQuickTranslate,
    this.readClipboard = readClipboardText,
    this.timeout = const Duration(seconds: 20),
  });

  final SharedTextService service;
  final TranslateCubit translateCubit;

  /// Brings the translate screen to the front.
  final VoidCallback onShowTranslate;

  /// Shows the quick translate UI for a `PROCESS_TEXT` selection. Without
  /// it, selections open in the translate tab like shared text, except
  /// "Translate offline" ones: the translate tab could send them to its
  /// (network) engine, so only the translate screen is shown, without the
  /// text.
  final void Function(QuickTranslateRequest request)? onQuickTranslate;

  /// Reads the clipboard for [SharedText.isTranslateClipboard].
  final ClipboardReader readClipboard;

  /// How long to wait for the engines before applying text.
  final Duration timeout;

  StreamSubscription<SharedText>? _texts;
  bool _disposed = false;

  /// Handles the launch text, then texts received while running.
  Future<void> start() async {
    _texts = service.texts.listen(
      (shared) => unawaited(handle(shared)),
      onError: (Object _) {},
    );
    try {
      final initial = await service.initialText();
      if (initial != null && !_disposed) await handle(initial);
    } on Exception {
      // No platform support: nothing was shared.
    }
  }

  /// Shows [shared] where it belongs (see the class documentation).
  Future<void> handle(SharedText shared) async {
    if (_disposed) return;
    if (shared.isTranslateClipboard) {
      await _translateClipboard();
      return;
    }

    final text = shared.text;
    if (text.trim().isEmpty) return;
    final quick = onQuickTranslate;
    final offlineOnly = shared.isTranslateOffline;
    if ((shared.isProcessText || offlineOnly) && quick != null) {
      quick(
        QuickTranslateRequest(
          text: text,
          onOpenInApp: () => unawaited(openInApp(text)),
          onReplace: shared.readOnly
              ? null
              : (translation) => unawaited(replaceSelection(translation)),
          offlineOnly: offlineOnly,
        ),
      );
      return;
    }
    if (offlineOnly) {
      onShowTranslate();
      return;
    }
    await openInApp(text);
  }

  /// Shows the translate tab with [text] as external input.
  Future<void> openInApp(String text) async {
    if (_disposed || text.trim().isEmpty) return;
    onShowTranslate();
    await TranslateLink(text: text).applyTo(translateCubit, timeout: timeout);
  }

  /// Answers the pending `PROCESS_TEXT` request with [translation]
  /// (Android then closes Mozhi and replaces the selection).
  Future<void> replaceSelection(String translation) async {
    if (translation.trim().isEmpty) return;
    await service.returnResult(translation);
  }

  Future<void> _translateClipboard() async {
    String? text;
    try {
      text = await readClipboard();
    } on Object {
      text = null;
    }
    if (_disposed) return;
    if (text == null || text.trim().isEmpty) {
      onShowTranslate();
      return;
    }
    await openInApp(text);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _texts?.cancel();
  }
}
