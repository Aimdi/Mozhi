import 'package:equatable/equatable.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

enum ImageTranslateStatus {
  /// No image yet.
  initial,

  /// An image is loaded but not translated (no method, or cancelled).
  ready,

  /// Translating; see [ImageTranslateState.phase].
  working,
  success,
  failure,
}

/// What is happening while [ImageTranslateStatus.working].
enum ImageTranslatePhase {
  /// Re-encoding the image for upload.
  preparing,

  /// Waiting for the Mozhi instance / AI provider.
  uploading,

  /// Recognising text on the device.
  recognizing,

  /// Translating the recognised text.
  translatingText,
}

class ImageTranslateState extends Equatable {
  const new({
    this.status = ImageTranslateStatus.initial,
    this.phase = ImageTranslatePhase.preparing,
    this.slow = false,
    this.image,
    this.methods = const [],
    this.method,
    this.source = Language.auto,
    this.target = const Language(code: 'en', name: 'English'),
    this.translateEngine,
    this.options = const TranslationOptions(),
    this.canUseCamera = false,
    this.result,
    this.error,
    this.pickError,
    this.showOriginal = false,
  });

  final ImageTranslateStatus status;
  final ImageTranslatePhase phase;

  /// True once the current request takes longer than usual.
  final bool slow;

  final PickedImage? image;

  /// Methods available with the current engines/providers.
  final List<ImageTranslateMethod> methods;
  final ImageTranslateMethod? method;
  final Language source;
  final Language target;

  /// The translator's engine, used for on-device recognised text.
  final TranslationEngine? translateEngine;

  /// The translator's options (style, formality, ...) for AI engines.
  final TranslationOptions options;

  /// Whether a photo can be taken on this platform.
  final bool canUseCamera;

  /// Latest (or streaming) result for [image].
  final ImageTranslation? result;

  /// Why the last translation failed ([ImageTranslateException],
  /// `MozhiApiException`, `LlmApiException`, ...).
  final Object? error;

  /// Why the last pick failed; shown once as a snackbar.
  final Object? pickError;

  /// Original/Translated toggle of a re-rendered image.
  final bool showOriginal;

  bool get hasImage => image != null;
  bool get isWorking => status == ImageTranslateStatus.working;
  bool get canTranslate => image != null && method != null && !isWorking;

  /// The recognised text is editable (and re-translatable) for on-device
  /// recognition.
  bool get canEditSourceText =>
      method?.kind == ImageTranslateMethodKind.onDevice &&
      (result?.sourceText.isNotEmpty ?? false);

  /// On-device recognition, when it is one of [methods].
  ImageTranslateMethod? get onDeviceMethod => methods
      .where((method) => method.kind == ImageTranslateMethodKind.onDevice)
      .firstOrNull;

  /// The selected method sends the photo off the device and on-device
  /// recognition could translate it instead (offered when it fails).
  bool get offersOnDevice =>
      (method?.uploadsImage ?? false) && onDeviceMethod != null;

  /// On-device recognition read the text for "Detect language" with a low
  /// confidence (below [lowRecognitionConfidence]): the text may be in a
  /// language whose recognition data was not used.
  bool get hasLowRecognitionConfidence {
    final confidence = result?.recognitionConfidence;
    return source.isAuto &&
        method?.kind == ImageTranslateMethodKind.onDevice &&
        confidence != null &&
        confidence < lowRecognitionConfidence &&
        (result?.sourceText.isNotEmpty ?? false);
  }

  /// Recognition confidence (0 to 100) below which "Detect language" asks
  /// whether the language is right.
  static const lowRecognitionConfidence = 50;

  ImageTranslateState copyWith({
    ImageTranslateStatus? status,
    ImageTranslatePhase? phase,
    bool? slow,
    PickedImage? Function()? image,
    List<ImageTranslateMethod>? methods,
    ImageTranslateMethod? Function()? method,
    Language? source,
    Language? target,
    TranslationEngine? Function()? translateEngine,
    TranslationOptions? options,
    bool? canUseCamera,
    ImageTranslation? Function()? result,
    Object? Function()? error,
    Object? Function()? pickError,
    bool? showOriginal,
  }) {
    return ImageTranslateState(
      status: status ?? this.status,
      phase: phase ?? this.phase,
      slow: slow ?? this.slow,
      image: image != null ? image() : this.image,
      methods: methods ?? this.methods,
      method: method != null ? method() : this.method,
      source: source ?? this.source,
      target: target ?? this.target,
      translateEngine: translateEngine != null
          ? translateEngine()
          : this.translateEngine,
      options: options ?? this.options,
      canUseCamera: canUseCamera ?? this.canUseCamera,
      result: result != null ? result() : this.result,
      error: error != null ? error() : this.error,
      pickError: pickError != null ? pickError() : this.pickError,
      showOriginal: showOriginal ?? this.showOriginal,
    );
  }

  @override
  List<Object?> get props => [
    status,
    phase,
    slow,
    image,
    methods,
    method,
    source,
    target,
    translateEngine,
    options,
    canUseCamera,
    result,
    error,
    pickError,
    showOriginal,
  ];
}
