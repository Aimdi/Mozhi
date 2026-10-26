import 'dart:async';
import 'dart:ui' show Size;

import 'package:bloc/bloc.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/live_camera/cubit/live_camera_state.dart';
import 'package:mozhi/live_camera/data/block_tracker.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/data/upright_frame.dart';
import 'package:mozhi/live_camera/models/live_block.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

export 'live_camera_state.dart';

/// How fast the live camera reads (tests shorten it).
class LiveCameraTiming {
  const new({
    this.frameInterval = const Duration(milliseconds: 350),
    this.strainedInterval = const Duration(seconds: 2),
    this.frameTimeout = const Duration(seconds: 6),
    this.stillTimeout = const Duration(seconds: 8),
    this.restartDelay = const Duration(milliseconds: 800),
    this.translationRetry = const Duration(seconds: 8),
  });

  /// The shortest time from one frame to the next (one frame is read at a
  /// time: a slower phone reads less often).
  final Duration frameInterval;

  /// The same while the phone is hot or saving battery.
  final Duration strainedInterval;

  /// A frame that takes longer means the camera stalled.
  final Duration frameTimeout;

  /// The longest a still may take.
  final Duration stillTimeout;

  /// How long to wait before opening a camera that Android closed while
  /// the app stayed in front.
  final Duration restartDelay;

  /// How long to wait after the live engine failed.
  final Duration translationRetry;
}

/// Drives the live camera (contract W7-A): point the camera at text and the
/// translation is drawn over the preview.
///
/// * [start] asks for the camera permission (denied: [retryAccess];
///   blocked: [openSettings], and access is checked again when the app
///   comes back), opens the camera and reads.
/// * The read-translate loop: one frame at a time (the next is asked for
///   once the last one was read, at most every
///   [LiveCameraTiming.frameInterval], [LiveCameraTiming.strainedInterval]
///   while [DeviceConditions] reports heat or battery saver), its grey
///   pixels turned upright and read by on-device text recognition with
///   the source language's data ("Detect language": the installed
///   languages, the preferred ones first, see [planTextRecognition];
///   missing data is offered in [LiveCameraState.ocrMissing]). The
///   paragraphs are tracked across frames ([BlockTracker]) so the boxes
///   hold still, and only new or changed text is translated, by the live
///   engine (`resolveLiveEngine`), in one request per batch, at most one
///   batch at a time. Translations are kept in memory only (never in the
///   history) and reused for text seen again.
/// * Paused (camera closed) while the app is in the background
///   ([setForeground]), while the app lock is locked and while the phone
///   is critically hot; it starts again by itself.
/// * [freeze] takes a still for the photo page; [setTorch], [setZoom].
/// * The privacy settings apply (the repository enforces them): a stopped
///   request shows [LiveCameraState.consent] and nothing more is sent
///   until [consentGranted].
///
/// Frames, stills and recognised text are never logged or stored.
class LiveCameraCubit extends Cubit<LiveCameraState> {
  new({
    required this._camera,
    required TextRecognitionService recognizer,
    required this._repository,
    required TranslationEngine engine,
    required Language source,
    required Language target,
    List<String> preferredLanguages = const [],
    this._lock,
    DeviceConditions? conditions,
    BlockTracker? tracker,
    this._timing = const LiveCameraTiming(),
    Future<void> Function(Duration duration)? delay,
    this.minSightings = 2,
    this.maxCachedTranslations = 300,
    this.maxBatchBlocks = 12,
    this.maxBatchCharacters = 2000,
  }) : _recognizer = recognizer,
       _data = textRecognitionLanguageDataOf(recognizer),
       _pixels = textRecognitionPixelsOf(recognizer),
       _preferred = List.unmodifiable(preferredLanguages),
       _conditions = conditions,
       _tracker = tracker ?? BlockTracker(),
       _delay = delay ?? Future<void>.delayed,
       super(
         LiveCameraState(
           source: source.isCustom ? Language.auto : source,
           target: target,
           engine: engine,
           strain: conditions?.latest.strain,
         ),
       ) {
    final lock = _lock;
    if (lock != null) {
      if (lock.isLocked) _pauses.add(LivePauseReason.locked);
      _subscriptions.add(
        lock.changes.listen(
          (locked) => locked
              ? _pause(LivePauseReason.locked)
              : _resume(LivePauseReason.locked),
        ),
      );
    }
    final conditions = _conditions;
    if (conditions != null) {
      if (_isTooHot(conditions.latest)) _pauses.add(LivePauseReason.heat);
      _subscriptions.add(conditions.changes.listen(_applyConditions));
    }
    final data = _data;
    if (data != null) {
      _subscriptions.add(
        data.ocrLanguagesChanged.listen((_) => unawaited(_plan())),
      );
    }
  }

  /// A new block is translated once it was read in this many frames (or
  /// read with a confidence of at least 80): text read only once is often
  /// a misreading.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int minSightings;

  /// Translations kept in memory (least recently used ones are dropped).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxCachedTranslations;

  /// Most blocks translated in one request.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxBatchBlocks;

  /// Most characters translated in one request.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxBatchCharacters;

  final LiveCameraController _camera;
  final TextRecognitionService _recognizer;
  final TextRecognitionLanguageData? _data;
  final TextRecognitionPixels? _pixels;
  final TranslationRepository _repository;
  final List<String> _preferred;
  final AppLock? _lock;
  final DeviceConditions? _conditions;
  final BlockTracker _tracker;
  final LiveCameraTiming _timing;
  final Future<void> Function(Duration duration) _delay;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Why the camera must stay closed now.
  final _pauses = <LivePauseReason>{};

  bool _started = false;
  bool _accessGranted = false;

  /// The user went to the app's settings to allow the camera.
  bool _awaitingSettings = false;

  /// The camera opening (or open) now; a new one invalidates everything
  /// the old one still delivers.
  int _session = 0;
  bool _opening = false;
  bool _cameraOpen = false;
  bool _looping = false;
  int _restarts = 0;
  Timer? _restartTimer;

  /// The recognition languages; null while there are none to read with.
  List<String>? _codes;
  int _planRun = 0;
  int _recognitionFailures = 0;

  /// Translations by engine, languages and text, least recently used
  /// first.
  final _cache = <String, String>{};
  int _translationRun = 0;
  bool _translating = false;
  Timer? _retryTimer;
  final _requests = <_Request>[];

  // ---------------------------------------------------------------------
  // Starting and access
  // ---------------------------------------------------------------------

  /// Asks for the camera, opens it and starts reading (once paused reasons
  /// are gone). No live camera without a camera or on-device recognition.
  Future<void> start() async {
    if (_started || isClosed) return;
    _started = true;
    if (!_camera.isSupported ||
        !_recognizer.isSupported ||
        _data == null ||
        _pixels == null) {
      emit(state.copyWith(status: LiveCameraStatus.unsupported));
      return;
    }
    unawaited(_plan());
    await _proceed();
  }

  /// Asks for the camera again (after it was refused).
  Future<void> retryAccess() async {
    if (state.status != LiveCameraStatus.denied &&
        state.status != LiveCameraStatus.blocked) {
      return;
    }
    await _proceed();
  }

  /// Opens the app's settings to allow the camera; access is checked again
  /// when the app comes back.
  Future<void> openSettings() async {
    final platform = liveCameraPlatformOf(_camera);
    if (platform == null) return;
    _awaitingSettings = true;
    if (!await platform.openAppSettings()) _awaitingSettings = false;
  }

  /// Opens the camera again after it failed.
  Future<void> retryCamera() async {
    if (state.status != LiveCameraStatus.failed) return;
    _restarts = 0;
    emit(state.copyWith(cameraError: () => null));
    await _proceed();
  }

  /// The next step towards a running camera, unless paused.
  Future<void> _proceed() async {
    if (isClosed || !_started) return;
    if (_pauses.isNotEmpty) {
      _emitPaused();
      return;
    }
    if (!_accessGranted) {
      await _askAccess();
      return;
    }
    await _openCamera();
  }

  Future<void> _askAccess() async {
    emit(state.copyWith(status: LiveCameraStatus.requestingAccess));
    final access = await _camera.requestAccess();
    if (isClosed) return;
    switch (access) {
      case CameraAccess.granted:
        _accessGranted = true;
        await _proceed();
      case CameraAccess.denied:
        emit(state.copyWith(status: LiveCameraStatus.denied));
      case CameraAccess.blocked:
        emit(state.copyWith(status: LiveCameraStatus.blocked));
    }
  }

  Future<void> _openCamera() async {
    if (_opening || _cameraOpen || isClosed) return;
    _opening = true;
    final session = ++_session;
    emit(
      state.copyWith(
        status: LiveCameraStatus.starting,
        cameraError: () => null,
        pauseReason: () => null,
      ),
    );
    final LivePreview preview;
    try {
      preview = await _camera.start();
    } on Object catch (error) {
      if (session == _session) _opening = false;
      if (isClosed || session != _session) return;
      final kind = error is LiveCameraException
          ? error.kind
          : LiveCameraErrorKind.failed;
      _cameraFailed(kind);
      return;
    }
    if (session == _session) _opening = false;
    // Paused (or closed) meanwhile: the stop sent then closes this camera
    // (the platform takes the calls in order).
    if (isClosed || session != _session) return;
    _cameraOpen = true;
    final rotation = await _displayRotation();
    if (isClosed || session != _session) return;
    emit(
      state.copyWith(
        status: LiveCameraStatus.running,
        preview: () => preview,
        displayRotation: rotation ?? state.displayRotation,
        frameSize: () => null,
        blocks: const [],
        torchOn: false,
        zoom: preview.minZoom,
        still: () => null,
      ),
    );
    _ensureLoop();
  }

  Future<int?> _displayRotation() async {
    final platform = liveCameraPlatformOf(_camera);
    if (platform == null) return null;
    try {
      return await platform.displayRotation();
    } on Object {
      return null;
    }
  }

  /// Asks the display's rotation again (the window was turned), to turn
  /// the preview at once.
  Future<void> refreshRotation() async {
    final rotation = await _displayRotation();
    if (rotation == null || isClosed || rotation == state.displayRotation) {
      return;
    }
    emit(state.copyWith(displayRotation: rotation));
  }

  void _cameraFailed(LiveCameraErrorKind kind) {
    _stopCamera();
    switch (kind) {
      case LiveCameraErrorKind.permission:
        // Taken away in the settings while the app ran.
        _accessGranted = false;
        emit(
          state.copyWith(
            status: LiveCameraStatus.denied,
            blocks: const [],
            preview: () => null,
          ),
        );
      case LiveCameraErrorKind.background:
        // Android refused because the app went away: it starts again when
        // it is back (or soon, if nothing says it went).
        _scheduleRestart();
      case _:
        emit(
          state.copyWith(
            status: LiveCameraStatus.failed,
            cameraError: () => kind,
            blocks: const [],
            preview: () => null,
            torchOn: false,
          ),
        );
    }
  }

  /// Android closed the camera while it was in use: open it again soon,
  /// unless the app is paused by then (it was sent to the background).
  void _scheduleRestart() {
    _restartTimer?.cancel();
    if (++_restarts > _maxRestarts) {
      emit(
        state.copyWith(
          status: LiveCameraStatus.failed,
          cameraError: () => LiveCameraErrorKind.failed,
          blocks: const [],
          preview: () => null,
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        status: LiveCameraStatus.starting,
        blocks: const [],
        preview: () => null,
      ),
    );
    _restartTimer = Timer(_timing.restartDelay, () {
      if (isClosed || _pauses.isNotEmpty) return;
      if (state.status != LiveCameraStatus.starting) return;
      unawaited(_openCamera());
    });
  }

  static const _maxRestarts = 3;

  void _stopCamera() {
    _session++;
    _opening = false;
    _cameraOpen = false;
    _restartTimer?.cancel();
    unawaited(_quietly(_camera.stop));
  }

  // ---------------------------------------------------------------------
  // Pausing
  // ---------------------------------------------------------------------

  /// The app came to the screen ([visible]) or left it.
  void setForeground({required bool visible}) => visible
      ? _resume(LivePauseReason.background)
      : _pause(LivePauseReason.background);

  void _pause(LivePauseReason reason) {
    if (isClosed || !_pauses.add(reason)) return;
    if (!_started) return;
    switch (state.status) {
      case LiveCameraStatus.starting ||
          LiveCameraStatus.running ||
          LiveCameraStatus.freezing:
        _stopCamera();
        _emitPaused();
      case LiveCameraStatus.paused:
        _emitPaused();
      case _:
        // Nothing open (a message, the frozen still): it stays.
        break;
    }
  }

  void _resume(LivePauseReason reason) {
    if (isClosed || !_pauses.remove(reason)) return;
    if (!_started) return;
    if (_pauses.isNotEmpty) {
      if (state.status == LiveCameraStatus.paused) _emitPaused();
      return;
    }
    if (state.status == LiveCameraStatus.paused) {
      unawaited(_proceed());
    } else if (state.status == LiveCameraStatus.blocked && _awaitingSettings) {
      // Back from the settings: allowed now?
      _awaitingSettings = false;
      unawaited(_askAccess());
    }
  }

  void _emitPaused() {
    final reason = _pauses.contains(LivePauseReason.locked)
        ? LivePauseReason.locked
        : _pauses.contains(LivePauseReason.background)
        ? LivePauseReason.background
        : LivePauseReason.heat;
    emit(
      state.copyWith(
        status: LiveCameraStatus.paused,
        pauseReason: () => reason,
        blocks: const [],
        frameSize: () => null,
        torchOn: false,
      ),
    );
  }

  void _applyConditions(DeviceConditionsSnapshot conditions) {
    if (isClosed) return;
    final strain = conditions.strain;
    if (strain != state.strain) emit(state.copyWith(strain: () => strain));
    if (_isTooHot(conditions)) {
      _pause(LivePauseReason.heat);
    } else {
      _resume(LivePauseReason.heat);
    }
  }

  static bool _isTooHot(DeviceConditionsSnapshot conditions) =>
      conditions.thermal.index >= ThermalStatus.critical.index;

  // ---------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------

  /// Plans which recognition languages read [LiveCameraState.source].
  Future<void> _plan() async {
    final data = _data;
    if (data == null || isClosed) return;
    final run = ++_planRun;
    TextRecognitionPlan plan;
    try {
      plan = await planTextRecognition(
        data,
        source: state.source,
        preferred: _preferred,
      );
    } on Object {
      plan = const TextRecognitionUnsupported();
    }
    if (isClosed || run != _planRun) return;
    switch (plan) {
      case TextRecognitionReady(:final codes):
        _codes = codes;
        emit(
          state.copyWith(
            ocrMissing: () => null,
            ocrUnsupported: false,
            recognitionFailed: false,
          ),
        );
        _ensureLoop();
      case TextRecognitionNeedsData(:final missing):
        _codes = null;
        emit(
          state.copyWith(
            ocrMissing: () => missing,
            ocrUnsupported: false,
            blocks: const [],
          ),
        );
      case TextRecognitionUnsupported():
        _codes = null;
        emit(
          state.copyWith(
            ocrMissing: () => null,
            ocrUnsupported: true,
            blocks: const [],
          ),
        );
    }
  }

  /// The missing recognition data was installed: read again.
  Future<void> ocrInstalled() => _plan();

  bool _canRead(int session) =>
      !isClosed &&
      session == _session &&
      _cameraOpen &&
      state.status == LiveCameraStatus.running &&
      _codes != null;

  void _ensureLoop() {
    if (_looping) return;
    final session = _session;
    if (!_canRead(session)) return;
    _looping = true;
    unawaited(
      _loop(session).whenComplete(() {
        _looping = false;
        _ensureLoop();
      }),
    );
  }

  Future<void> _loop(int session) async {
    while (_canRead(session)) {
      final watch = Stopwatch()..start();
      await _readFrame(session);
      if (!_canRead(session)) return;
      final interval = state.strain == null
          ? _timing.frameInterval
          : _timing.strainedInterval;
      final wait = interval - watch.elapsed;
      if (wait > Duration.zero) await _delay(wait);
    }
  }

  Future<void> _readFrame(int session) async {
    final CameraFrame? frame;
    try {
      frame = await _camera.nextFrame().timeout(_timing.frameTimeout);
    } on TimeoutException {
      if (!isClosed && session == _session) {
        _cameraFailed(LiveCameraErrorKind.stalled);
      }
      return;
    } on Object catch (error) {
      if (!isClosed && session == _session) {
        _cameraFailed(
          error is LiveCameraException
              ? error.kind
              : LiveCameraErrorKind.failed,
        );
      }
      return;
    }
    if (!_canRead(session)) return;
    if (frame == null) {
      // Android closed the camera (the app is going away, or it was
      // recreated).
      _session++;
      _cameraOpen = false;
      _scheduleRestart();
      return;
    }
    _restarts = 0;
    final codes = _codes!;
    final upright = uprightFrame(frame);
    final TextWithConfidence read;
    try {
      read = await _pixels!.recognizePixels(
        upright.pixels,
        width: upright.width,
        height: upright.height,
        codes: codes,
        bytesPerPixel: 1,
        bytesPerLine: upright.bytesPerRow,
      );
    } on OcrDataMissingException catch (missing) {
      if (isClosed) return;
      _codes = null;
      emit(state.copyWith(ocrMissing: () => missing, blocks: const []));
      return;
    } on Object {
      if (isClosed) return;
      if (++_recognitionFailures >= _maxRecognitionFailures &&
          !state.recognitionFailed) {
        emit(state.copyWith(recognitionFailed: true));
      }
      return;
    }
    if (!_canRead(session)) return;
    _recognitionFailures = 0;
    final size = Size(upright.width.toDouble(), upright.height.toDouble());
    final found = [
      for (final paragraph
          in read.layout?.paragraphs ?? const <TextParagraph>[])
        if (isReadableLiveParagraph(paragraph)) paragraph,
    ];
    // Boxes of a frame of another size (the phone was turned) are
    // elsewhere: start over.
    final previous = state.frameSize == size ? state.blocks : <LiveBlock>[];
    final blocks = _tracker.track(previous, found, frame: size);
    final rotation = state.preview?.rotation ?? 0;
    emit(
      state.copyWith(
        blocks: [for (final block in blocks) _withCached(block)],
        frameSize: () => size,
        displayRotation: ((rotation - frame.rotationDegrees) % 360 + 360) % 360,
        recognitionFailed: false,
      ),
    );
    _translatePending();
  }

  static const _maxRecognitionFailures = 3;

  // ---------------------------------------------------------------------
  // Translating
  // ---------------------------------------------------------------------

  String _key(String text) =>
      '${state.engine.id}\u0000${state.source.code}\u0000'
      '${state.target.code}\u0000$text';

  /// [block] with its text's cached translation, when there is one.
  LiveBlock _withCached(LiveBlock block) {
    if (!block.needsTranslation) return block;
    final key = _key(block.text);
    final cached = _cache.remove(key);
    if (cached == null) return block;
    _cache[key] = cached;
    return block.translated(cached);
  }

  void _remember(String text, String translation) {
    final key = _key(text);
    _cache
      ..remove(key)
      ..[key] = translation;
    while (_cache.length > maxCachedTranslations) {
      _cache.remove(_cache.keys.first);
    }
  }

  bool _isReady(LiveBlock block) =>
      block.needsTranslation &&
      block.missed == 0 &&
      (block.seen >= minSightings || (block.paragraph.confidence ?? 0) >= 80);

  /// Translates the blocks waiting for it, in one batch, unless one is
  /// running, the engine needs consent or failed a moment ago.
  void _translatePending() {
    if (isClosed ||
        _translating ||
        state.consent != null ||
        (_retryTimer?.isActive ?? false)) {
      return;
    }
    final batch = <LiveBlock>[];
    var characters = 0;
    for (final block in state.blocks) {
      if (!_isReady(block)) continue;
      if (batch.isNotEmpty &&
          (batch.length >= maxBatchBlocks ||
              characters + block.text.length > maxBatchCharacters)) {
        break;
      }
      batch.add(block);
      characters += block.text.length;
    }
    if (batch.isEmpty) return;
    _translating = true;
    final run = _translationRun;
    unawaited(_translateBatch(run, batch));
  }

  Future<void> _translateBatch(int run, List<LiveBlock> batch) async {
    final engine = state.engine;
    final texts = [for (final block in batch) block.text];
    try {
      final translation = await _request(
        run,
        engine,
        texts.join(TextLayout.paragraphSeparator),
      );
      if (translation == null || !_isCurrent(run)) return;
      var parts = TextLayout.splitParagraphs(translation);
      if (parts.length != texts.length) {
        if (texts.length == 1) {
          parts = [translation.trim()];
        } else if (engine.isOnDevice) {
          // Nothing leaves the device: each block on its own.
          parts = [];
          for (final text in texts) {
            final part = await _request(run, engine, text);
            if (part == null || !_isCurrent(run)) return;
            parts.add(part.trim());
          }
        } else {
          // A network engine gets no more requests: spread the answer.
          parts = TextLayout(
            width: 1,
            height: 1,
            paragraphs: [for (final block in batch) block.paragraph],
          ).alignTranslation(translation);
        }
      }
      for (var i = 0; i < texts.length && i < parts.length; i++) {
        if (parts[i].isNotEmpty) _remember(texts[i], parts[i]);
      }
      emit(
        state.copyWith(
          blocks: [for (final block in state.blocks) _withCached(block)],
          translationError: () => null,
        ),
      );
    } on ConsentRequiredException catch (consent) {
      if (!_isCurrent(run)) return;
      emit(state.copyWith(consent: () => consent));
    } on Object catch (error) {
      if (!_isCurrent(run)) return;
      emit(state.copyWith(translationError: () => error));
      _retryTimer?.cancel();
      _retryTimer = Timer(_timing.translationRetry, _translatePending);
    } finally {
      if (run == _translationRun) _translating = false;
    }
    if (_isCurrent(run)) _translatePending();
  }

  bool _isCurrent(int run) => !isClosed && run == _translationRun;

  /// The translation of [text] by [engine] (null when cancelled).
  Future<String?> _request(int run, TranslationEngine engine, String text) {
    final request = _Request();
    String? last;
    request.subscription = _repository
        .translate(
          engine,
          TranslationRequest(
            text: text,
            source: state.source,
            target: state.target,
          ),
        )
        .listen(
          (result) => last = result.text,
          onError: (Object error, StackTrace stackTrace) {
            _requests.remove(request);
            if (!request.done.isCompleted) {
              request.done.completeError(error, stackTrace);
            }
          },
          onDone: () {
            _requests.remove(request);
            if (!request.done.isCompleted) request.done.complete(last);
          },
          cancelOnError: true,
        );
    _requests.add(request);
    return request.done.future;
  }

  /// Drops the running translation and every translation shown (they are
  /// translated again, the old ones shown meanwhile).
  void _restartTranslations() {
    _translationRun++;
    _translating = false;
    _retryTimer?.cancel();
    for (final request in List.of(_requests)) {
      request.cancel();
    }
    _requests.clear();
    if (isClosed) return;
    emit(
      state.copyWith(
        blocks: [
          for (final block in state.blocks)
            block.copyWith(translatedFrom: () => null),
        ],
        translationError: () => null,
        consent: () => null,
      ),
    );
  }

  /// The live engine changed (`resolveLiveEngine`).
  void setEngine(TranslationEngine engine) {
    if (engine.id == state.engine.id) return;
    emit(state.copyWith(engine: engine));
    _restartTranslations();
    _translatePending();
  }

  /// The language of the text: read with its data, everything anew.
  Future<void> setSource(Language language) async {
    if (language == state.source || language.isCustom) return;
    emit(state.copyWith(source: language, blocks: const []));
    _restartTranslations();
    await _plan();
  }

  Future<void> setTarget(Language language) async {
    if (language == state.target || language.isAuto) return;
    emit(state.copyWith(target: language));
    _restartTranslations();
    _translatePending();
  }

  /// The user allowed the live engine (the consent prompt): translate on.
  void consentGranted() {
    if (state.consent == null || isClosed) return;
    emit(state.copyWith(consent: () => null));
    _translatePending();
  }

  // ---------------------------------------------------------------------
  // Torch, zoom, freeze
  // ---------------------------------------------------------------------

  Future<void> setTorch({required bool on}) async {
    if (!state.isLive || !(state.preview?.hasTorch ?? false)) return;
    if (on == state.torchOn) return;
    emit(state.copyWith(torchOn: on));
    await _quietly(() => _camera.setTorch(on: on));
  }

  Future<void> setZoom(double ratio) async {
    final preview = state.preview;
    if (!state.isLive || preview == null || ratio.isNaN) return;
    final zoom = ratio.clamp(preview.minZoom, preview.maxZoom);
    if ((zoom - state.zoom).abs() < 0.01) return;
    // The boxes are elsewhere now.
    emit(state.copyWith(zoom: zoom, blocks: const [], frameSize: () => null));
    await _quietly(() => _camera.setZoom(zoom));
  }

  /// Takes a still for the photo page and closes the camera; null (and
  /// [LiveCameraState.freezeFailures] counts it) when that failed, and the
  /// camera reads on.
  Future<PickedImage?> freeze() async {
    if (!state.isLive) return null;
    emit(state.copyWith(status: LiveCameraStatus.freezing));
    PickedImage? still;
    try {
      still = await _camera.takePicture().timeout(_timing.stillTimeout);
    } on Object {
      still = null;
    }
    if (isClosed || state.status != LiveCameraStatus.freezing) return null;
    if (still == null) {
      emit(
        state.copyWith(
          status: LiveCameraStatus.running,
          freezeFailures: state.freezeFailures + 1,
        ),
      );
      _ensureLoop();
      return null;
    }
    _stopCamera();
    emit(
      state.copyWith(
        status: LiveCameraStatus.frozen,
        still: () => still,
        blocks: const [],
        torchOn: false,
      ),
    );
    return still;
  }

  static Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } on Object {
      // The camera is gone: nothing to do.
    }
  }

  @override
  Future<void> close() async {
    _session++;
    _cameraOpen = false;
    _restartTimer?.cancel();
    _restartTranslations();
    // The camera first: nothing may keep it open.
    final stopped = _quietly(_camera.stop);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _cache.clear();
    await stopped;
    await super.close();
  }
}

/// A running translation request, cancelled when the live engine or the
/// languages change and when the screen closes.
class _Request {
  final done = Completer<String?>();
  StreamSubscription<TranslationResult>? subscription;

  void cancel() {
    unawaited(subscription?.cancel());
    if (!done.isCompleted) done.complete(null);
  }
}

/// Whether text recognition's [paragraph] is worth showing: at least two
/// letters or digits, read with some confidence (specks, textures and
/// edges read as text are dropped).
bool isReadableLiveParagraph(TextParagraph paragraph) {
  final letters = _letterOrDigit.allMatches(paragraph.text).length;
  if (letters < 2) return false;
  final confidence = paragraph.confidence;
  if (confidence == null) return true;
  return confidence >= 50 || (confidence >= 35 && letters >= 6);
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
