import 'dart:async';

import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:translation_repository/translation_repository.dart';

/// Translates incoming Android notifications **exclusively with the on-device
/// [OfflineTranslator]**, never sending notification text over the network
/// regardless of the app's privacy mode.
final class NotificationTranslateRunner {
  new({
    required this.controls,
    required this.offline,
    required this.targetLanguage,
  });

  final NotificationTranslateControls controls;
  final OfflineTranslator offline;

  /// Returns the target language code to translate notifications into (e.g.
  /// `en`, `de`).
  final String Function() targetLanguage;

  StreamSubscription<IncomingNotification>? _subscription;
  var _disposed = false;

  /// Starts listening to incoming notifications if supported.
  void start() {
    if (_disposed || !controls.isSupported || _subscription != null) return;
    _subscription = controls.notifications.listen(
      (notification) => unawaited(handle(notification)),
      onError: (Object _) {},
    );
  }

  /// Translates one [notification] strictly on-device. Skips notifications
  /// already in the target language, empty text, or language pairs whose
  /// offline model is not downloaded.
  Future<bool> handle(IncomingNotification notification) async {
    final text = notification.text.trim();
    if (text.isEmpty) return false;
    final target = targetLanguage().trim().toLowerCase();
    if (target.isEmpty || target == Language.auto.code) return false;

    String? detected;
    try {
      detected = await offline.identifyLanguage(text);
    } on Object {
      return false;
    }
    if (detected == null || detected.isEmpty) return false;
    final source = detected.toLowerCase();
    if (source == target ||
        source.split('-').first == target.split('-').first) {
      return false;
    }

    try {
      final downloaded = await offline.downloadedLanguages();
      if (!downloaded.contains(source) &&
          !downloaded.contains(source.split('-').first)) {
        return false;
      }
      if (!downloaded.contains(target) &&
          !downloaded.contains(target.split('-').first)) {
        return false;
      }
      final translated = await offline.translate(
        text,
        source: source,
        target: target,
      );
      final cleaned = translated.trim();
      if (cleaned.isEmpty || cleaned == text) return false;
      await controls.postTranslation(
        id: notification.id,
        title: notification.title,
        translation: cleaned,
      );
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
  }
}
