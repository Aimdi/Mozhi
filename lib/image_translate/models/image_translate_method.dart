import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The ways an image can be translated, in the order they are offered
/// (the recommended one first).
enum ImageTranslateMethodKind {
  /// Text recognition on the device (Tesseract in the default build, ML
  /// Kit in the Play variant), then a text translation with the
  /// translator's engine. Recommended: the photo stays on the device and
  /// nothing depends on Google.
  onDevice,

  /// A vision-capable AI model reads and translates the image.
  aiVision,

  /// Mozhi `/api/image`, experimental: the instance passes the photo on to
  /// Google Translate's image translation (an unofficial interface that
  /// often refuses such requests) and returns a re-rendered image.
  mozhiLens,
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

  /// Id of the Mozhi engine that powers [ImageTranslateMethodKind.mozhiLens]
  /// (Mozhi relays images to Google Translate whatever engine is used).
  static const mozhiGoogleEngineId = 'mozhi:google';

  final ImageTranslateMethodKind kind;

  /// The engine sending the image (null for on-device recognition).
  final TranslationEngine? engine;

  /// Stable id, e.g. `aiVision:ai:claude`.
  String get id => engine == null ? kind.name : '${kind.name}:${engine!.id}';

  /// Whether the result can contain a re-rendered image.
  bool get rendersImage => kind == ImageTranslateMethodKind.mozhiLens;

  /// Whether the photo itself is sent off the device (Mozhi via Google
  /// Translate, AI vision): only on the user's explicit Translate.
  bool get uploadsImage => kind != ImageTranslateMethodKind.onDevice;

  /// The methods available for [engines], recommended first:
  ///
  /// * On-device recognition when [onDeviceSupported] and a
  ///   [translateEngine] can translate the recognised text.
  /// * One AI vision method per AI engine whose provider (matched by
  ///   [TranslationEngine.providerId]) has
  ///   [AiProviderConfig.supportsVision].
  /// * Mozhi via Google Translate (experimental) when an engine with id
  ///   `mozhi:google` exists.
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
      if (onDeviceSupported && translateEngine != null)
        const ImageTranslateMethod.onDevice(),
      for (final engine in engines)
        if (engine.isAi && hasVision(engine))
          ImageTranslateMethod.aiVision(engine),
      if (google != null) ImageTranslateMethod.mozhiLens(google),
    ]);
  }

  /// The method to start with: on-device recognition when available (the
  /// photo never leaves the device; only the recognised text is translated,
  /// with the translator's engine), else the AI vision method of
  /// [translateEngine] when it has one, else another AI vision method, else
  /// Mozhi via Google Translate (experimental).
  static ImageTranslateMethod? preferred(
    List<ImageTranslateMethod> methods, {
    TranslationEngine? translateEngine,
  }) =>
      methods
          .where((method) => method.kind == ImageTranslateMethodKind.onDevice)
          .firstOrNull ??
      methods
          .where(
            (method) =>
                method.kind == ImageTranslateMethodKind.aiVision &&
                method.engine?.id == translateEngine?.id,
          )
          .firstOrNull ??
      methods
          .where((method) => method.kind == ImageTranslateMethodKind.aiVision)
          .firstOrNull ??
      methods.firstOrNull;

  /// The method of [methods] whose [id] is [id], or null.
  static ImageTranslateMethod? withId(
    List<ImageTranslateMethod> methods,
    String? id,
  ) => id == null
      ? null
      : methods.where((method) => method.id == id).firstOrNull;

  @override
  List<Object?> get props => [kind, engine];

  @override
  String toString() => 'ImageTranslateMethod($id)';
}
