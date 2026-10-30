import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/live_captions/data/caption_recognizer.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

class MockDeviceConditions extends Mock implements DeviceConditions;

const english = Language(code: 'en', name: 'English');
const spanish = Language(code: 'es', name: 'Spanish');
const german = Language(code: 'de', name: 'German');

const deepl = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  mozhiEngine: 'deepl',
);

final offlineEngine = TranslationEngine.offline();

/// 100 ms of 16 kHz samples of [value] (alternating sign).
Float32List block([double value = 0.3]) => Float32List.fromList([
  for (var i = 0; i < 1600; i++)
    if (i.isEven) value else -value,
]);

/// A [CaptionsHost] the test drives: [startResult] answers [start],
/// [sendAudio] and [sendEvent] play the platform side; what was shown and
/// stopped is recorded.
class FakeCaptionsHost implements CaptionsHost {
  new({this.isSupported = true});

  @override
  final bool isSupported;

  CaptureStart startResult = const CaptureStarted();

  /// Holds [start] until completed.
  Completer<void>? startGate;
  int starts = 0;
  int stops = 0;
  final List<CaptionLine> shown = [];
  final _audio = StreamController<Float32List>.broadcast();
  final _events = StreamController<CaptionBarEvent>.broadcast();

  void sendAudio(Float32List samples) => _audio.add(samples);

  void sendEvent(CaptionBarEvent event) => _events.add(event);

  /// The last line shown on the bar.
  CaptionLine get bar => shown.last;

  @override
  Future<CaptureStart> start() async {
    starts++;
    if (startGate case final gate?) await gate.future;
    return startResult;
  }

  @override
  Stream<Float32List> get audio => _audio.stream;

  @override
  Future<void> show(CaptionLine line) async => shown.add(line);

  @override
  Stream<CaptionBarEvent> get events => _events.stream;

  @override
  Future<void> stop() async => stops++;

  Future<void> dispose() async {
    await _audio.close();
    await _events.close();
  }
}

/// A [CaptionRecognizer] whose recordings the test drives
/// ([FakeCaptionRecording.phrase] hands a phrase to the cubit); the audio
/// added is kept.
class FakeCaptionRecognizer implements CaptionRecognizer {
  bool ready = true;
  Exception? startError;

  /// Holds [start] until completed.
  Completer<void>? startGate;
  final List<String?> languages = [];
  final List<FakeCaptionRecording> recordings = [];

  FakeCaptionRecording get recording => recordings.last;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<CaptionRecording> start({
    required void Function(TranscribedPhrase phrase) onPhrase,
    String? language,
  }) async {
    languages.add(language);
    if (startGate case final gate?) await gate.future;
    if (startError case final error?) throw error;
    final recording = FakeCaptionRecording(onPhrase);
    recordings.add(recording);
    return recording;
  }
}

class FakeCaptionRecording implements CaptionRecording {
  new(this._onPhrase);

  final void Function(TranscribedPhrase phrase) _onPhrase;
  final List<Float32List> added = [];
  bool finished = false;
  bool cancelled = false;

  @override
  int pending = 0;

  /// Hands the phrase [text] (heard in [language]) to the cubit.
  void phrase(
    String text, {
    String? language,
    int index = 0,
    Duration start = Duration.zero,
    Duration end = const Duration(seconds: 2),
    PhraseStatus status = PhraseStatus.transcribed,
  }) => _onPhrase(
    TranscribedPhrase(
      index: index,
      start: start,
      end: end,
      status: status,
      text: text,
      language: language,
    ),
  );

  @override
  void add(Float32List samples) => added.add(samples);

  @override
  Future<void> finish() async => finished = true;

  @override
  Future<void> cancel() async => cancelled = true;
}

/// "Display over other apps" and notifications as the test sets them.
class FakeOverlayControls implements ScreenTranslateControls {
  bool canDrawOverlays = true;
  bool notificationsAllowed = true;
  bool grantOnRequest = true;
  int overlayRequests = 0;
  int notificationRequests = 0;

  @override
  bool get isSupported => true;

  @override
  Future<ScreenTranslateSupport> status() async => ScreenTranslateSupport(
    canDrawOverlays: canDrawOverlays,
    notificationsAllowed: notificationsAllowed,
  );

  @override
  Future<bool> requestOverlayPermission() async {
    overlayRequests++;
    if (grantOnRequest) canDrawOverlays = true;
    return canDrawOverlays;
  }

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests++;
    return notificationsAllowed = true;
  }

  @override
  Future<bool> startBubble() async => false;

  @override
  Future<void> stopBubble() async {}

  @override
  Future<TileRequestResult> requestAddTile() async =>
      TileRequestResult.unsupported;
}

/// A translation result of [text] by DeepL.
TranslationResult resultOf(String text, {String engineName = 'DeepL'}) =>
    TranslationResult(engineId: deepl.id, engineName: engineName, text: text);

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
