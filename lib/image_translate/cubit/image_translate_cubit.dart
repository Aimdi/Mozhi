import 'dart:async';
import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:mozhi/image_translate/cubit/image_translate_state.dart';
import 'package:mozhi/image_translate/data/data.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

export 'image_translate_state.dart';

/// Drives the image translation screen.
///
/// * [pickImage] / [setImage] load an image. It is translated right away
///   only with on-device recognition (the preferred method when the device
///   has it): a method that sends the photo off the device
///   ([ImageTranslateMethod.uploadsImage], Mozhi / Google Lens, AI vision)
///   waits for the user's explicit [translate].
/// * Changing the method, source or target re-runs the translation the
///   same way (for on-device recognition a target change only
///   re-translates the recognised text); with an uploading method the
///   image waits for [translate] again.
/// * The privacy settings apply (the repository enforces them): a stopped
///   request fails with a `ConsentRequiredException` (nothing was sent).
/// * Every new run (and [cancel]) drops the in-flight one; HTTP requests
///   that cannot be aborted are simply ignored when they complete (but
///   still counted, see below).
/// * Engines/providers/options come from the translator and settings; keep
///   them current with [updateContext].
/// * With a `usageTracker`, every answered request to a bring-your-own-key
///   provider (engines with a `providerId`) is counted once: the vision
///   request (see [visionUsageInput]) and the translation of recognised
///   text. The provider bills what it answered, so this includes answers
///   that arrive after the run was cancelled or replaced, or the cubit
///   closed: a vision request cannot be aborted, and a translation that
///   already streamed its complete result is done. Results served from the
///   translation cache, failed requests and translations aborted before
///   their complete result are not counted.
class ImageTranslateCubit extends Cubit<ImageTranslateState> {
  new({
    required this._repository,
    required ImagePickerService picker,
    required this._encoder,
    required TextRecognitionService recognizer,
    List<TranslationEngine> engines = const [],
    List<AiProviderConfig> providers = const [],
    TranslationEngine? translateEngine,
    Language source = Language.auto,
    Language target = const Language(code: 'en', name: 'English'),
    TranslationOptions options = const TranslationOptions(),
    this.slowThreshold = const Duration(seconds: 12),
    this._usageTracker,
    List<String> preferredLanguages = const [],
  }) : _picker = picker,
       _recognizer = recognizer,
       _preferredLanguages = List.unmodifiable(preferredLanguages),
       super(
         _initialState(
           methods: ImageTranslateMethod.available(
             engines: engines,
             providers: providers,
             onDeviceSupported: recognizer.isSupported,
             translateEngine: translateEngine,
           ),
           translateEngine: translateEngine,
           source: source.isCustom ? Language.auto : source,
           target: target,
           options: options,
           canUseCamera: picker.supportsCamera,
         ),
       );

  static ImageTranslateState _initialState({
    required List<ImageTranslateMethod> methods,
    required TranslationEngine? translateEngine,
    required Language source,
    required Language target,
    required TranslationOptions options,
    required bool canUseCamera,
  }) => ImageTranslateState(
    methods: methods,
    method: ImageTranslateMethod.preferred(
      methods,
      translateEngine: translateEngine,
    ),
    translateEngine: translateEngine,
    source: source,
    target: target,
    options: options,
    canUseCamera: canUseCamera,
  );

  /// After this long the UI tells the user the request is still running.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration slowThreshold;

  final TranslationRepository _repository;
  final ImagePickerService _picker;
  final ImageEncoder _encoder;
  final TextRecognitionService _recognizer;

  /// App language codes "Detect language" reads with first when the
  /// recognizer downloads data per language (see [planTextRecognition]).
  final List<String> _preferredLanguages;

  /// Counts what answered requests send to and receive from a
  /// bring-your-own-key provider; optional.
  final UsageTracker? _usageTracker;

  int _run = 0;
  Timer? _slowTimer;
  StreamSubscription<TranslationResult>? _subscription;
  Completer<void>? _pending;

  // ---------------------------------------------------------------------
  // Context
  // ---------------------------------------------------------------------

  /// Recomputes the available methods (keeping the selected one when it is
  /// still available) after engines, providers or the translator's engine
  /// or options changed. Does not re-run the translation.
  void updateContext({
    required List<TranslationEngine> engines,
    required List<AiProviderConfig> providers,
    TranslationEngine? translateEngine,
    TranslationOptions? options,
  }) {
    final methods = ImageTranslateMethod.available(
      engines: engines,
      providers: providers,
      onDeviceSupported: _recognizer.isSupported,
      translateEngine: translateEngine,
    );
    final selected = state.method;
    final kept = selected == null
        ? null
        : methods.where((method) => method.id == selected.id).firstOrNull;
    emit(
      state.copyWith(
        methods: methods,
        method: () =>
            kept ??
            ImageTranslateMethod.preferred(
              methods,
              translateEngine: translateEngine,
            ),
        translateEngine: () => translateEngine,
        options: options,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Image
  // ---------------------------------------------------------------------

  /// Opens the picker; a picked image is translated right away. Failures
  /// are reported in [ImageTranslateState.pickError].
  Future<void> pickImage(ImagePickSource source) async {
    if (source == ImagePickSource.camera && !state.canUseCamera) return;
    if (state.pickError != null) emit(state.copyWith(pickError: () => null));
    final PickedImage? image;
    try {
      image = await _picker.pick(source);
    } on Object catch (error) {
      if (!isClosed) emit(state.copyWith(pickError: () => error));
      return;
    }
    if (image == null || isClosed) return;
    await setImage(image);
  }

  /// Shows [image]; translates it right away with on-device recognition
  /// (an uploading method waits for [translate]).
  Future<void> setImage(PickedImage image) {
    _cancelRun();
    emit(
      state.copyWith(
        status: ImageTranslateStatus.ready,
        image: () => image,
        result: () => null,
        error: () => null,
        slow: false,
        showOriginal: false,
      ),
    );
    return _translateUnlessUpload();
  }

  /// [translate] unless the selected method sends the photo off the device,
  /// which only the user's explicit [translate] may do.
  Future<void> _translateUnlessUpload() async {
    if (state.method?.uploadsImage ?? true) return;
    await translate();
  }

  /// Back to the empty state.
  void clearImage() {
    _cancelRun();
    emit(
      state.copyWith(
        status: ImageTranslateStatus.initial,
        image: () => null,
        result: () => null,
        error: () => null,
        slow: false,
        showOriginal: false,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Options
  // ---------------------------------------------------------------------

  Future<void> selectMethod(ImageTranslateMethod method) async {
    if (method == state.method || !state.methods.contains(method)) return;
    _cancelRun();
    emit(
      state.copyWith(
        method: () => method,
        status: state.hasImage
            ? ImageTranslateStatus.ready
            : ImageTranslateStatus.initial,
        result: () => null,
        error: () => null,
        slow: false,
        showOriginal: false,
      ),
    );
    await _translateUnlessUpload();
  }

  Future<void> setSource(Language language) async {
    if (language == state.source || language.isCustom) return;
    _cancelRun();
    emit(_awaitingUpload(state.copyWith(source: language)));
    await _translateUnlessUpload();
  }

  /// [next] (after a language change) waiting for the user's Translate
  /// when the selected method uploads the image: ready, without the old
  /// result.
  ImageTranslateState _awaitingUpload(ImageTranslateState next) {
    if (!(next.method?.uploadsImage ?? true) || !next.hasImage) return next;
    return next.copyWith(
      status: ImageTranslateStatus.ready,
      result: () => null,
      error: () => null,
      slow: false,
      showOriginal: false,
    );
  }

  Future<void> setTarget(Language language) async {
    if (language == state.target || language.isAuto) return;
    final recognized = state.canEditSourceText
        ? state.result!.sourceText
        : null;
    _cancelRun();
    if (recognized != null) {
      emit(state.copyWith(target: language));
      await translateText(recognized);
    } else {
      emit(_awaitingUpload(state.copyWith(target: language)));
      await _translateUnlessUpload();
    }
  }

  void setShowOriginal({required bool showOriginal}) =>
      emit(state.copyWith(showOriginal: showOriginal));

  // ---------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------

  /// Translates the current image with the selected method (no-op without
  /// an image or method).
  Future<void> translate() async {
    final image = state.image;
    final method = state.method;
    if (image == null || method == null) return;
    final engine = method.engine;
    final token = _start(switch (method.kind) {
      ImageTranslateMethodKind.onDevice => ImageTranslatePhase.recognizing,
      _ => ImageTranslatePhase.preparing,
    });
    try {
      final result = switch (method.kind) {
        ImageTranslateMethodKind.mozhiLens => await _translateWithMozhi(
          token,
          image,
          engine!,
        ),
        ImageTranslateMethodKind.aiVision => await _translateWithVision(
          token,
          image,
          engine!,
        ),
        ImageTranslateMethodKind.onDevice => await _recognizeAndTranslate(
          token,
          image,
        ),
      };
      if (result != null) _succeed(token, result);
    } on Object catch (error) {
      _fail(token, error, method.kind);
    }
  }

  /// Translates (edited) recognised [text] with the translator's engine,
  /// keeping the image.
  Future<void> translateText(String text) async {
    final trimmed = text.trim();
    if (state.image == null || trimmed.isEmpty) return;
    final token = _start(ImageTranslatePhase.translatingText);
    try {
      final result = await _translateRecognized(token, trimmed);
      if (result != null) _succeed(token, result);
    } on Object catch (error) {
      _fail(token, error, ImageTranslateMethodKind.onDevice);
    }
  }

  /// Stops the running translation.
  void cancel() {
    if (!state.isWorking) return;
    _cancelRun();
    final recognized = state.result?.sourceText ?? '';
    final keepText =
        state.method?.kind == ImageTranslateMethodKind.onDevice &&
        recognized.isNotEmpty;
    emit(
      state.copyWith(
        status: ImageTranslateStatus.ready,
        slow: false,
        result: () =>
            keepText ? ImageTranslation(sourceText: recognized) : null,
      ),
    );
  }

  Future<ImageTranslation?> _translateWithMozhi(
    int token,
    PickedImage image,
    TranslationEngine engine,
  ) async {
    final png = await _encoder.encodePng(image.bytes);
    if (!_isCurrent(token)) return null;
    emit(state.copyWith(phase: ImageTranslatePhase.uploading));
    final result = await _repository.translateImage(
      engine,
      png,
      mimeType: 'image/png',
      source: state.source,
      target: state.target,
    );
    if (!_isCurrent(token)) return null;
    final translated = result.translatedImage;
    if ((translated == null || translated.isEmpty) &&
        result.translatedText.trim().isEmpty) {
      throw const ImageTranslateException(ImageTranslateErrorKind.noText);
    }
    return ImageTranslation(
      translatedImage: translated == null || translated.isEmpty
          ? null
          : translated is Uint8List
          ? translated
          : Uint8List.fromList(translated),
      sourceText: result.sourceText.trim(),
      translatedText: result.translatedText.trim(),
      notes: result.notes.trim(),
      destination: result.destination,
    );
  }

  Future<ImageTranslation?> _translateWithVision(
    int token,
    PickedImage image,
    TranslationEngine engine,
  ) async {
    // Always re-encode, also JPEG/PNG/WebP that vision APIs would accept as
    // they are: decoding and encoding drops EXIF and other metadata (GPS
    // location, time, device), which must not reach a third-party provider
    // (docs/security.md). It also converts HEIC/BMP and caps the size.
    const mimeType = 'image/png';
    final bytes = await _encoder.encodePng(image.bytes);
    if (!_isCurrent(token)) return null;
    emit(state.copyWith(phase: ImageTranslatePhase.uploading));
    final source = state.source;
    final target = state.target;
    final options = state.options;
    final result = await _repository.translateImage(
      engine,
      bytes,
      mimeType: mimeType,
      source: source,
      target: target,
      options: options,
    );
    // The provider answered (and billed) the request even when it found no
    // text in the image, and even when this run was cancelled or replaced
    // meanwhile (the request cannot be aborted).
    _recordUsage(
      engine,
      input: () => visionUsageInput(
        result,
        bytes,
        mimeType: mimeType,
        source: source,
        target: target,
        options: options,
      ),
      output: _visionUsageOutput(result),
    );
    if (!_isCurrent(token)) return null;
    if (result.translatedText.trim().isEmpty) {
      throw const ImageTranslateException(ImageTranslateErrorKind.noText);
    }
    return ImageTranslation(
      sourceText: result.sourceText.trim(),
      translatedText: result.translatedText.trim(),
      notes: result.notes.trim(),
      destination: result.destination,
    );
  }

  Future<ImageTranslation?> _recognizeAndTranslate(
    int token,
    PickedImage image,
  ) async {
    final text = (await _recognize(image)).trim();
    if (!_isCurrent(token)) return null;
    if (text.isEmpty) {
      throw const ImageTranslateException(ImageTranslateErrorKind.noText);
    }
    return await _translateRecognized(token, text);
  }

  /// The text in [image]. A recognizer with downloadable language data
  /// reads with the source's data, or for "Detect language" with the
  /// installed languages (the preferred ones first); missing data fails
  /// with [OcrDataMissingException] (offered for download by the view,
  /// never downloaded here).
  Future<String> _recognize(PickedImage image) async {
    final data = textRecognitionLanguageDataOf(_recognizer);
    if (data == null) {
      return await _recognizer.recognize(image, source: state.source);
    }
    final plan = await planTextRecognition(
      data,
      source: state.source,
      preferred: _preferredLanguages,
    );
    return switch (plan) {
      TextRecognitionReady(:final codes) => await data.recognizeWith(
        image,
        codes,
      ),
      TextRecognitionNeedsData(:final missing) => throw missing,
      TextRecognitionUnsupported() => throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionLanguageUnsupported,
      ),
    };
  }

  /// Streams the translation of [text] into [ImageTranslateState.result].
  Future<ImageTranslation?> _translateRecognized(int token, String text) async {
    var current = ImageTranslation(sourceText: text, isComplete: false);
    emit(
      state.copyWith(
        phase: ImageTranslatePhase.translatingText,
        result: () => current,
      ),
    );
    final engine = state.translateEngine;
    if (engine == null) {
      throw const ImageTranslateException(ImageTranslateErrorKind.noEngine);
    }
    final done = Completer<void>();
    _pending = done;
    TranslationResult? last;
    _subscription = _repository
        .translate(
          engine,
          TranslationRequest(
            text: text,
            source: state.source,
            target: state.target,
            options: state.options,
          ),
        )
        .listen(
          (translation) {
            last = translation;
            if (!_isCurrent(token)) return;
            current = current.copyWith(
              translatedText: translation.text,
              detectedSource: translation.detectedSource,
              destination: translation.destination,
            );
            emit(state.copyWith(result: () => current));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!done.isCompleted) done.completeError(error, stackTrace);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    // Counted even when the run was cancelled right after the complete
    // result arrived: the provider answered it in full. A run cancelled
    // mid-stream aborts the request and has no complete result.
    final answer = last;
    if (answer != null && answer.isComplete && !answer.fromCache) {
      _recordUsage(engine, input: () => text, output: answer.text);
    }
    if (!_isCurrent(token)) return null;
    _subscription = null;
    _pending = null;
    return current.copyWith(isComplete: true);
  }

  /// What a vision request is counted as sending to the provider: the text
  /// the model read from the image when the result reports it (OCR text),
  /// else the text of the prompt (the system and user messages of
  /// [TranslationPrompts.translateImage]).
  ///
  /// The image itself is not estimated: providers bill images by their
  /// size in tiles or pixels, which a character count cannot express, so
  /// usage of vision requests is a lower bound.
  static String visionUsageInput(
    ImageTranslationResult result,
    List<int> imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) {
    final recognized = result.sourceText.trim();
    if (recognized.isNotEmpty) return recognized;
    return TranslationPrompts.translateImage(
      imageBytes,
      mimeType: mimeType,
      source: source,
      target: target,
      options: options,
    ).map((message) => message.content).join('\n');
  }

  /// What a vision request received: the translation and any notes.
  static String _visionUsageOutput(ImageTranslationResult result) => [
    result.translatedText.trim(),
    result.notes.trim(),
  ].where((part) => part.isNotEmpty).join('\n');

  /// Counts an answered request to [engine]'s provider (engines with a
  /// `providerId`) when a usage tracker is set. [input] is only computed
  /// then. Never throws; tracker errors are ignored.
  void _recordUsage(
    TranslationEngine engine, {
    required String Function() input,
    required String output,
  }) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    try {
      unawaited(
        tracker
            .recordText(providerId, input: input(), output: output)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break image translation.
    }
  }

  int _start(ImageTranslatePhase phase) {
    _cancelRun();
    final token = _run;
    emit(
      state.copyWith(
        status: ImageTranslateStatus.working,
        phase: phase,
        slow: false,
        error: () => null,
        // Re-translating text keeps the current result until the new one
        // streams in; a full run starts from scratch.
        result: phase == ImageTranslatePhase.translatingText
            ? null
            : () => null,
        showOriginal: false,
      ),
    );
    _slowTimer = Timer(slowThreshold, () {
      if (_isCurrent(token) && state.isWorking) {
        emit(state.copyWith(slow: true));
      }
    });
    return token;
  }

  void _succeed(int token, ImageTranslation result) {
    if (!_isCurrent(token)) return;
    _slowTimer?.cancel();
    emit(
      state.copyWith(
        status: ImageTranslateStatus.success,
        result: () => result,
        slow: false,
        error: () => null,
      ),
    );
  }

  void _fail(int token, Object error, ImageTranslateMethodKind kind) {
    if (!_isCurrent(token)) return;
    _slowTimer?.cancel();
    _subscription = null;
    _pending = null;
    final result = state.result;
    emit(
      state.copyWith(
        status: ImageTranslateStatus.failure,
        error: () => mapError(error, method: kind),
        slow: false,
        // Keep recognised text so it can be fixed and translated again.
        result: () => result == null || result.sourceText.isEmpty
            ? null
            : ImageTranslation(sourceText: result.sourceText),
      ),
    );
  }

  bool _isCurrent(int token) => !isClosed && token == _run;

  void _cancelRun() {
    _run++;
    _slowTimer?.cancel();
    _slowTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// Maps transport errors to [ImageTranslateException]s where image
  /// translation has a better explanation; other errors pass through.
  static Object mapError(Object error, {ImageTranslateMethodKind? method}) {
    ImageTranslateException wrap(ImageTranslateErrorKind kind) =>
        ImageTranslateException(kind, cause: error);
    return switch (error) {
      ImageTranslateException() => error,
      MozhiApiException(statusCode: 413) || LlmApiException(statusCode: 413) =>
        wrap(ImageTranslateErrorKind.tooLarge),
      MozhiApiException(statusCode: 400 || 415 || 422) => wrap(
        ImageTranslateErrorKind.unsupported,
      ),
      MozhiApiException(statusCode: 504) ||
      TimeoutException() => wrap(ImageTranslateErrorKind.timeout),
      MozhiApiException(statusCode: null, :final message)
          when method == ImageTranslateMethodKind.mozhiLens &&
              message.startsWith('No response within') =>
        wrap(ImageTranslateErrorKind.timeout),
      ArgumentError(name: 'source' || 'target') => wrap(
        ImageTranslateErrorKind.unsupportedLanguage,
      ),
      _ => error,
    };
  }

  @override
  Future<void> close() {
    _cancelRun();
    return super.close();
  }
}
