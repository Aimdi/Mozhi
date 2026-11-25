import 'dart:async';

import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:translation_repository/translation_repository.dart';

/// Translates incoming Android notifications **exclusively with the on-device
/// [OfflineTranslator]**, never sending notification text over the network
/// regardless of the app's privacy mode.
final class NotificationTranslateRunner {
  new({
    required this.controls,
    required this.offline,
    required this.targetLanguage,
    this.isLocked,
  });

  final NotificationTranslateControls controls;
  final OfflineTranslator offline;

  /// Fallback target language code when no dedicated notification target
  /// language is configured (e.g. `en`, `de`, `zh-CN`).
  final String Function() targetLanguage;

  /// Returns true while Mozhi's App Lock is active; notifications are never
  /// translated or posted while locked.
  final bool Function()? isLocked;

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

  /// Translates one [notification] strictly on-device. Skips while locked,
  /// muted packages, notifications already in the target language, empty text,
  /// unsupported directions, or language pairs whose offline model is not
  /// downloaded.
  Future<bool> handle(IncomingNotification notification) async {
    if (isLocked?.call() ?? false) return false;

    final text = notification.text.trim();
    if (text.isEmpty) return false;

    NotificationTranslateStatus status;
    try {
      status = await controls.status();
    } on Object {
      status = const NotificationTranslateStatus();
    }
    if (status.mutedPackages.contains(notification.packageName)) return false;

    final preferredTarget = status.targetLanguage?.trim();
    final rawTarget = (preferredTarget != null && preferredTarget.isNotEmpty)
        ? preferredTarget
        : targetLanguage().trim();
    final targetLower = rawTarget.toLowerCase();
    if (targetLower.isEmpty || targetLower == Language.auto.code) return false;

    String? detected;
    try {
      detected = await offline.identifyLanguage(text);
    } on Object {
      return false;
    }
    if (detected == null || detected.trim().isEmpty) return false;
    final sourceLower = detected.trim().toLowerCase();
    if (sourceLower == targetLower ||
        sourceLower.split('-').first == targetLower.split('-').first) {
      return false;
    }

    try {
      final downloaded = await offline.downloadedLanguages();
      final resolvedSource = _resolveCode(downloaded, detected);
      final resolvedTarget = _resolveCode(downloaded, rawTarget);
      if (resolvedSource == null || resolvedTarget == null) return false;
      if (!_supportsDirection(resolvedSource, resolvedTarget)) return false;

      final translated = await offline.translate(
        text,
        source: resolvedSource,
        target: resolvedTarget,
      );
      if (isLocked?.call() ?? false) return false;
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

  /// Resolves [code] case-insensitively against [available], returning the
  /// canonical code (e.g. `"zh-CN"` for `"zh-cn"` or `"zh"`).
  static String? _resolveCode(Set<String> available, String code) {
    final normalized = code.trim().replaceAll('_', '-').toLowerCase();
    if (normalized.isEmpty) return null;

    final byLower = <String, String>{
      for (final item in available) item.toLowerCase(): item,
    };
    if (byLower[normalized] case final exact?) return exact;

    final primary = normalized.split('-').first;
    if (byLower[primary] case final base?) return base;

    for (final entry in byLower.entries) {
      if (entry.key.split('-').first == primary) return entry.value;
    }
    return null;
  }

  /// Verifies that [offline] supports translating from [source] to [target]
  /// directly or via an English pivot.
  bool _supportsDirection(String source, String target) {
    final supported = offline.supportedLanguages;
    final oneWay = _oneWayDirections();
    final sourceLower = source.toLowerCase();
    final targetLower = target.toLowerCase();

    final canFrom = _canTranslateFrom(sourceLower, supported, oneWay);
    final canTo = _canTranslateTo(targetLower, supported, oneWay);
    if (!canFrom || !canTo) return false;

    final needsPivot =
        sourceLower.split('-').first != 'en' &&
        targetLower.split('-').first != 'en';
    if (needsPivot && supported.isNotEmpty) {
      final hasEnglish = _resolveCode(supported, 'en') != null;
      if (!hasEnglish) return false;
    }
    return true;
  }

  Map<String, OfflineLanguageDirection> _oneWayDirections() {
    final OfflineLanguageDirections? directions;
    if (offline is OfflineLanguageDirections) {
      directions = offline as OfflineLanguageDirections;
    } else {
      final details = offlineModelDetailsOf(offline);
      directions = details is OfflineLanguageDirections
          ? details! as OfflineLanguageDirections
          : null;
    }
    if (directions == null) return const {};
    return {
      for (final MapEntry(:key, :value) in directions.oneWayLanguages.entries)
        key.toLowerCase(): value,
    };
  }

  static bool _canTranslateFrom(
    String codeLower,
    Set<String> supported,
    Map<String, OfflineLanguageDirection> oneWay,
  ) {
    if (_resolveCode(supported, codeLower) != null) return true;
    final dir = oneWay[codeLower] ?? oneWay[codeLower.split('-').first];
    return dir == OfflineLanguageDirection.fromOnly ||
        dir == OfflineLanguageDirection.both;
  }

  static bool _canTranslateTo(
    String codeLower,
    Set<String> supported,
    Map<String, OfflineLanguageDirection> oneWay,
  ) {
    if (_resolveCode(supported, codeLower) != null) return true;
    final dir = oneWay[codeLower] ?? oneWay[codeLower.split('-').first];
    return dir == OfflineLanguageDirection.intoOnly ||
        dir == OfflineLanguageDirection.both;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
  }
}
