import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockDeviceConditions extends Mock implements DeviceConditions;

const testPreview = LivePreview(
  textureId: 7,
  previewSize: Size(1280, 720),
  rotation: 90,
  hasTorch: true,
  maxZoom: 8,
);

/// A 4 x 2 frame, upright already.
CameraFrame testFrame({int rotation = 0, int width = 4, int height = 2}) =>
    CameraFrame(
      pixels: Uint8List(width * height),
      width: width,
      height: height,
      bytesPerRow: width,
      rotationDegrees: rotation,
      timestamp: Duration.zero,
    );

/// A paragraph read with [confidence].
TextParagraph paragraph(
  String text, {
  Rect box = const Rect.fromLTWH(10, 10, 100, 20),
  int confidence = 90,
}) => TextParagraph(text: text, box: box, confidence: confidence);

/// A layout of [paragraphs] in a 4 x 2 frame (the boxes are what counts).
TextLayout layoutOf(List<TextParagraph> paragraphs) =>
    TextLayout(width: 4, height: 2, paragraphs: paragraphs);

/// A camera whose frames the test hands out ([push]): [nextFrame] waits
/// for one. Counts every call and how many frames are asked for at once.
class FakeLiveCamera implements LiveCameraController, LiveCameraPlatform {
  new({
    this.isSupported = true,
    List<CameraAccess>? access,
    this.preview = testPreview,
  }) : access = access ?? [CameraAccess.granted];

  @override
  bool isSupported;

  /// The answers of [requestAccess], one per call (the last one repeats).
  List<CameraAccess> access;
  LivePreview preview;

  /// Thrown by the next [start]s, one each (null: started).
  final startErrors = <Exception?>[];

  /// The frames [nextFrame] answers (a [CameraFrame], null, or an error to
  /// throw).
  final _frames = <Object?>[];
  Completer<void>? _waiting;

  int accessRequests = 0;
  int starts = 0;
  int stops = 0;
  int frameRequests = 0;
  int framesInFlight = 0;
  int maxFramesInFlight = 0;
  final torch = <bool>[];
  final zooms = <double>[];
  int pictures = 0;
  PickedImage? picture;
  Completer<PickedImage?>? pictureGate;
  int settingsOpened = 0;
  bool settingsOpen = true;
  int rotation = 0;

  /// Hands out [frame] (a [CameraFrame], null, or an error).
  void push(Object? frame) {
    _frames.add(frame);
    _release();
  }

  void _release() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// Whether a [nextFrame] is waiting for a frame.
  bool get waitingForFrame => _waiting != null;

  @override
  Future<CameraAccess> requestAccess() async {
    final answer = access[math.min(accessRequests, access.length - 1)];
    accessRequests++;
    return answer;
  }

  @override
  Future<LivePreview> start() async {
    starts++;
    if (startErrors.isNotEmpty) {
      final error = startErrors.removeAt(0);
      if (error != null) throw error;
    }
    return preview;
  }

  @override
  Future<CameraFrame?> nextFrame() async {
    frameRequests++;
    framesInFlight++;
    maxFramesInFlight = math.max(maxFramesInFlight, framesInFlight);
    try {
      while (_frames.isEmpty) {
        final waiting = _waiting = Completer<void>();
        await waiting.future;
      }
      final next = _frames.removeAt(0);
      if (next is Exception) throw next;
      return next as CameraFrame?;
    } finally {
      framesInFlight--;
    }
  }

  @override
  Future<void> setTorch({required bool on}) async => torch.add(on);

  @override
  Future<void> setZoom(double ratio) async => zooms.add(ratio);

  @override
  Future<PickedImage?> takePicture() {
    pictures++;
    return pictureGate?.future ?? Future.value(picture);
  }

  @override
  Future<void> stop() async {
    stops++;
    // The platform answers a waiting frame with null.
    if (_waiting != null) push(null);
  }

  @override
  Future<bool> openAppSettings() async {
    settingsOpened++;
    return settingsOpen;
  }

  @override
  Future<int> displayRotation() async => rotation;
}

/// German, English and French recognition data (German and English
/// installed); [recognizePixels] answers [layout] (or throws [error]).
class FakeLiveRecognizer
    implements
        TextRecognitionService,
        TextRecognitionLanguageData,
        TextRecognitionPixels {
  new({Map<String, int>? installed, this.pixels = true})
    : installed = installed ?? {'deu': 1, 'eng': 1};

  static const deu = OcrLanguage(code: 'deu', appCode: 'de', downloadSize: 1);
  static const eng = OcrLanguage(code: 'eng', appCode: 'en', downloadSize: 1);
  static const fra = OcrLanguage(code: 'fra', appCode: 'fr', downloadSize: 1);

  @override
  bool isSupported = true;

  /// Whether it reads raw pixels (else [textRecognitionPixelsOf] finds
  /// nothing: only [recognizePixels] is there, and throws).
  final bool pixels;
  Map<String, int> installed;
  TextLayout layout = layoutOf(const []);

  /// Thrown by [recognizePixels] while set.
  Exception? error;

  /// The next answers of [recognizePixels], before [layout] (a
  /// [TextLayout] or an error to throw).
  final answers = <Object>[];

  /// When set, [recognizePixels] waits for it.
  Completer<void>? gate;
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final codes = <List<String>>[];
  final sizes = <({int width, int height, int bytesPerPixel})>[];
  final _changes = StreamController<void>.broadcast();

  void changed() => _changes.add(null);

  @override
  Stream<void> get ocrLanguagesChanged => _changes.stream;

  @override
  Future<List<OcrLanguage>> ocrLanguages() async => const [deu, eng, fra];

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) async {
    for (final language in const [deu, eng, fra]) {
      if (language.appCode == code) return language;
    }
    return null;
  }

  @override
  Future<Map<String, int>> installedOcrLanguages() async => installed;

  @override
  Future<TextWithConfidence> recognizePixels(
    Uint8List pixels, {
    required int width,
    required int height,
    required List<String> codes,
    int bytesPerPixel = 4,
    int? bytesPerLine,
  }) async {
    calls++;
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    this.codes.add(codes);
    sizes.add((width: width, height: height, bytesPerPixel: bytesPerPixel));
    try {
      final gate = this.gate;
      if (gate != null) await gate.future;
      final error = this.error;
      if (error != null) throw error;
      final answer = answers.isEmpty ? layout : answers.removeAt(0);
      if (answer is Exception) throw answer;
      answer as TextLayout;
      return TextWithConfidence(answer.text, layout: answer);
    } finally {
      inFlight--;
    }
  }

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      throw UnimplementedError();

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) =>
      throw UnimplementedError();

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    installed[code] = 1;
    changed();
  }

  @override
  Future<void> deleteOcrLanguage(String code) async {
    installed.remove(code);
    changed();
  }

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) async =>
      const OcrImportReport();
}

/// A recognizer that cannot read raw pixels (like ML Kit).
class FilesOnlyRecognizer implements TextRecognitionService {
  @override
  bool get isSupported => true;

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      throw UnimplementedError();
}

/// An app lock the test locks and unlocks.
class FakeAppLock implements AppLock {
  new({this.isLocked = false});

  @override
  bool isLocked;
  final _changes = StreamController<bool>.broadcast();

  void lockNow() {
    isLocked = true;
    _changes.add(true);
  }

  void unlockNow() {
    isLocked = false;
    _changes.add(false);
  }

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> unlock() async {
    unlockNow();
    return true;
  }

  @override
  void noteBackground() {}

  @override
  void noteForeground() {}
}

/// Translates each paragraph of a request as `<paragraph>` (`[target]`).
Stream<TranslationResult> bracketTranslation(Invocation invocation) {
  final engine = invocation.positionalArguments[0] as TranslationEngine;
  final request = invocation.positionalArguments[1] as TranslationRequest;
  final text = TextLayout.splitParagraphs(request.text)
      .map((part) => '<$part>${request.target.code}')
      .join(TextLayout.paragraphSeparator);
  return Stream.value(
    TranslationResult(engineId: engine.id, engineName: engine.name, text: text),
  );
}

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');
const french = Language(code: 'fr', name: 'French');
final offlineEngine = TranslationEngine.offline();
const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);
const onDeviceAiEngine = TranslationEngine(
  id: 'ai:gemma',
  kind: EngineKind.ai,
  name: 'Gemma',
  providerId: 'gemma',
  isLocal: true,
  onDevice: true,
);

void registerLiveCameraFallbacks() {
  registerFallbackValue(offlineEngine);
  registerFallbackValue(
    const TranslationRequest(text: '', source: Language.auto, target: english),
  );
  registerFallbackValue(
    const ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: OnDeviceDestination(),
      engineId: '',
    ),
  );
}
