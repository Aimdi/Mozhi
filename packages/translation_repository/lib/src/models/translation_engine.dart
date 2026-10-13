import 'package:meta/meta.dart';

enum EngineKind { mozhi, ai }

/// Something that can translate: a Mozhi engine on the active instance, or a
/// configured AI provider.
///
/// Ids are stable across launches: `mozhi:<engine>` (e.g. `mozhi:deepl`) or
/// `ai:<providerId>`.
@immutable
class TranslationEngine {
  const new({
    required this.id,
    required this.kind,
    required this.name,
    this.subtitle,
    this.mozhiEngine,
    this.providerId,
    this.isLocal = false,
  });

  factory mozhi(String engine, String name) =>
      TranslationEngine(
        id: 'mozhi:$engine',
        kind: EngineKind.mozhi,
        name: name,
        mozhiEngine: engine,
      );

  final String id;
  final EngineKind kind;
  final String name;

  /// E.g. the model name for AI engines, or "via mozhi.aryak.me".
  final String? subtitle;
  final String? mozhiEngine;
  final String? providerId;

  /// Runs on-device / on LAN (privacy badge).
  final bool isLocal;

  bool get isAi => kind == EngineKind.ai;
  bool get isMozhi => kind == EngineKind.mozhi;

  /// AI engines accept free-form custom target "languages" and the
  /// style/formality/context options.
  bool get supportsCustomLanguages => isAi;
  bool get supportsOptions => isAi;

  /// Mozhi TTS exists for `google` and `reverso`; AI engines fall back to
  /// whatever TTS the app has (Mozhi google TTS or device TTS).
  bool get supportsTts =>
      isAi || mozhiEngine == 'google' || mozhiEngine == 'reverso';

  @override
  bool operator ==(Object other) =>
      other is TranslationEngine && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'TranslationEngine($id)';
}
