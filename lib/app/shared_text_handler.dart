import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';
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
///
/// In the translucent quick translate window ([quickHost], when it
/// [QuickTranslateHost.isActive]) there is nothing but the quick translate
/// UI: "Open in app" continues in the main window
/// ([QuickTranslateHost.openTextInApp]), and a window started without a
/// selection (e.g. recreated after Android ended the app) closes at once.
/// The window's network activity is handed to the main window's log
/// ([EgressRelay], from [ledger]), and so is that of the screen-translate
/// window ([screenHost], whose page shows no shared text).
class SharedTextHandler {
  new({
    required this.service,
    required this.translateCubit,
    required this.onShowTranslate,
    this.onQuickTranslate,
    this.readClipboard = readClipboardText,
    this.timeout = const Duration(seconds: 20),
    QuickTranslateHost? quickHost,
    ScreenTranslateHost? screenHost,
    this.ledger,
    this.untilUnlocked,
  }) : quickHost = quickHost ?? QuickTranslateHost.instance,
       screenHost = screenHost ?? ScreenTranslateHost.instance;

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

  /// The quick translate window this app may run in.
  final QuickTranslateHost quickHost;

  /// The screen-translate window this app may run in.
  final ScreenTranslateHost screenHost;

  /// Completes once the app lock lets the app show what it got (`AppLock`,
  /// `AppLockController.untilUnlocked`): every text, selection and
  /// clipboard request waits for it before it fills the translator, opens
  /// a screen, translates or is saved; the clipboard is read only then.
  /// Null: nothing to wait for.
  final Future<void> Function()? untilUnlocked;

  /// The network activity log to join (default: the one of
  /// [NetworkSession.current]).
  final EgressLedger? ledger;

  StreamSubscription<SharedText>? _texts;
  void Function()? _stopRelay;
  bool _disposed = false;

  /// Handles the launch text, then texts received while running.
  Future<void> start() async {
    final log = ledger ?? NetworkSession.current.ledger;
    final inWindow = quickHost.isActive;
    // Only the main window receives; the others hand their entries to it.
    _stopRelay = inWindow || screenHost.isActive
        ? EgressRelay.forward(log)
        : EgressRelay.receive(log);
    _texts = service.texts.listen(
      (shared) => unawaited(handle(shared)),
      onError: (Object _) {},
    );
    SharedText? initial;
    try {
      initial = await service.initialText();
    } on Exception {
      // No platform support: nothing was shared.
    }
    if (_disposed) return;
    if (initial != null) {
      await handle(initial);
    } else if (inWindow) {
      // Nothing to show: never leave an invisible window over the app.
      await quickHost.close();
    }
  }

  /// Shows [shared] where it belongs (see the class documentation).
  Future<void> handle(SharedText shared) async {
    if (_disposed) return;
    if (untilUnlocked case final wait?) {
      await wait();
      if (_disposed) return;
    }
    if (shared.isTranslateClipboard) {
      await _translateClipboard();
      return;
    }

    final text = shared.text;
    final inWindow = quickHost.isActive;
    if (text.trim().isEmpty) {
      if (inWindow) await quickHost.close();
      return;
    }
    final quick = onQuickTranslate;
    final offlineOnly = shared.isTranslateOffline;
    if (inWindow && quick == null) {
      await quickHost.close();
      return;
    }
    if ((shared.isProcessText || offlineOnly || inWindow) && quick != null) {
      quick(
        QuickTranslateRequest(
          text: text,
          onOpenInApp: inWindow
              ? () => unawaited(quickHost.openTextInApp(text))
              : () => unawaited(openInApp(text)),
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
    _stopRelay?.call();
    _stopRelay = null;
    await _texts?.cancel();
  }
}
