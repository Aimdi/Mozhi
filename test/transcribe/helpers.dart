import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockOfflineSpeech extends Mock implements OfflineSpeech;

class MockSpeechInputService extends Mock implements SpeechInputService;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');
const french = Language(code: 'fr', name: 'French');

const deepl = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  mozhiEngine: 'deepl',
);

final offlineEngine = TranslationEngine.offline();

/// A [Transcriber] the test drives: [emit] events into the current
/// recording; [stop] ends it (after [stopGate], if set).
class FakeTranscriber implements Transcriber {
  new({this.onDevice = true});

  @override
  final bool onDevice;

  StreamController<TranscriberEvent>? controller;
  final List<String?> languages = [];
  int stops = 0;
  int cancels = 0;
  Completer<void>? stopGate;

  void emit(TranscriberEvent event) => controller!.add(event);

  void heard(
    String text, {
    required int start,
    required int end,
    String? language,
    PhraseStatus status = PhraseStatus.transcribed,
    int pending = 0,
  }) => emit(
    TranscriberHeard(
      TranscribedPhrase(
        index: 0,
        start: Duration(seconds: start),
        end: Duration(seconds: end),
        status: status,
        text: text,
        language: language,
      ),
      pending: pending,
    ),
  );

  @override
  Stream<TranscriberEvent> listen({String? language}) {
    languages.add(language);
    unawaited(controller?.close());
    final events = controller = StreamController<TranscriberEvent>();
    return events.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (stopGate case final gate?) await gate.future;
    await controller?.close();
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await controller?.close();
  }
}

/// Records what [setEnabled] was asked.
class FakeScreenAwake extends ScreenAwake {
  new() : super(isWeb: false);

  final List<bool> calls = [];

  @override
  Future<void> setEnabled({required bool enabled}) async => calls.add(enabled);
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
