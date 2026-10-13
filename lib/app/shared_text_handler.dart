import 'dart:async';

import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Routes text shared by the OS (Android share sheet / "Translate with
/// Mozhi" selection action) to the translate screen.
///
/// For a writable `PROCESS_TEXT` request, [onReplaceAvailable] is called
/// once the translation completes so the UI can offer [replaceSelection].
class SharedTextHandler {
  new({
    required this.service,
    required this.translateCubit,
    required this.onShowTranslate,
    required this.onReplaceAvailable,
    this.timeout = const Duration(minutes: 2),
  });

  final SharedTextService service;
  final TranslateCubit translateCubit;

  /// Brings the translate screen to the front.
  final void Function() onShowTranslate;

  /// The calling app accepts the translation as a replacement.
  final void Function() onReplaceAvailable;

  /// How long to wait for engines / the translation.
  final Duration timeout;

  StreamSubscription<SharedText>? _texts;
  StreamSubscription<TranslateState>? _completion;
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

  /// Shows and translates [shared].
  Future<void> handle(SharedText shared) async {
    if (_disposed || shared.text.trim().isEmpty) return;
    await _completion?.cancel();
    _completion = null;
    onShowTranslate();
    await TranslateLink(text: shared.text)
        .applyTo(translateCubit, timeout: timeout);
    if (_disposed || !shared.isProcessText || shared.readOnly) return;

    final current = translateCubit.state;
    if (_isDone(current) && current.input.trim() == shared.text.trim()) {
      _onDone(current);
      return;
    }
    _completion = translateCubit.stream
        .where(_isDone)
        .take(1)
        .timeout(timeout, onTimeout: (sink) => sink.close())
        .listen(_onDone);
  }

  /// Answers the pending `PROCESS_TEXT` request with the current output
  /// (Android then closes Mozhi and replaces the selection).
  Future<void> replaceSelection() async {
    final output = translateCubit.state.output;
    if (output.trim().isEmpty) return;
    await service.returnResult(output);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _texts?.cancel();
    await _completion?.cancel();
  }

  static bool _isDone(TranslateState s) =>
      s.status == TranslateStatus.failure ||
      (s.status == TranslateStatus.success && (s.result?.isComplete ?? true));

  void _onDone(TranslateState state) {
    if (_disposed ||
        state.status != TranslateStatus.success ||
        state.output.trim().isEmpty) {
      return;
    }
    onReplaceAvailable();
  }
}
