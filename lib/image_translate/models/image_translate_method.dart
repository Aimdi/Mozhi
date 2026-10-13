import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The ways an image can be translated.
enum ImageTranslateMethodKind {
  /// Mozhi `/api/image` (Google Lens): returns a re-rendered image.
  mozhiLens,

  /// A vision-capable AI model reads and translates the image.
  aiVision,

  /// ML Kit text recognition on the device, then a text translation.
  onDevice,
}

/// One selectable image translation method.
class ImageTranslateMethod extends Equatable {
  const new mozhiLens(TranslationEngine this.engine)
    : kind = ImageTranslateMethodKind.mozhiLens;

  const new aiVision(TranslationEngine this.engine)
    : kind = ImageTranslateMethodKind.aiVision;

  /// The text is translated with the translator's current engine.
  const new onDevice()
    : kind = ImageTranslateMethodKind.onDevice,
      engine = null;

  /// Id of the Mozhi engine that powers [ImageTranslateMethodKind.mozhiLens].
  static const mozhiGoogleEngineId = 'mozhi:google';

  final ImageTranslateMethodKind kind;

  /// The engine sending the image (null for on-device recognition).
  final TranslationEngine? engine;

  /// Stable id, e.g. `aiVision:ai:claude`.
  String get id => engine == null ? kind.name : '${kind.name}:${engine!.id}';

  /// Whether the result can contain a re-rendered image.
  bool get rendersImage => kind == ImageTranslateMethodKind.mozhiLens;

  /// The methods available for [engines]:
  ///
  /// * Mozhi (Google Lens) when an engine with id `mozhi:google` exists.
  /// * One AI vision method per AI engine whose provider (matched by
  ///   [TranslationEngine.providerId]) has
  ///   [AiProviderConfig.supportsVision].
  /// * On-device recognition when [onDeviceSupported] and a
  ///   [translateEngine] can translate the recognised text.
  static List<ImageTranslateMethod> available({
    required List<TranslationEngine> engines,
    required List<AiProviderConfig> providers,
    required bool onDeviceSupported,
    TranslationEngine? translateEngine,
  }) {
    final google = engines
        .where((engine) => engine.id == mozhiGoogleEngineId)
        .firstOrNull;
    bool hasVision(TranslationEngine engine) {
      final id =
          engine.providerId ??
          (engine.id.startsWith('ai:') ? engine.id.substring(3) : engine.id);
      return providers.any(
        (provider) => provider.id == id && provider.supportsVision,
      );
    }

    return List.unmodifiable([
      if (google != null) ImageTranslateMethod.mozhiLens(google),
      for (final engine in engines)
        if (engine.isAi && hasVision(engine))
          ImageTranslateMethod.aiVision(engine),
      if (onDeviceSupported && translateEngine != null)
        const ImageTranslateMethod.onDevice(),
    ]);
  }

  /// The method to start with: the AI vision method of [translateEngine]
  /// when it has one, else Mozhi (Google Lens), else the first one.
  static ImageTranslateMethod? preferred(
    List<ImageTranslateMethod> methods, {
    TranslationEngine? translateEngine,
  }) =>
      methods
          .where(
            (method) =>
                method.kind == ImageTranslateMethodKind.aiVision &&
                method.engine?.id == translateEngine?.id,
          )
          .firstOrNull ??
      methods
          .where((method) => method.kind == ImageTranslateMethodKind.mozhiLens)
          .firstOrNull ??
      methods.firstOrNull;

  @override
  List<Object?> get props => [kind, engine];

  @override
  String toString() => 'ImageTranslateMethod($id)';
}
