import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../voice/helpers/fake_speech_recognizer.dart';
import '../helpers.dart';

void main() {
  late MockTranslationRepository repository;
  late FakeScreenAwake awake;

  setUpAll(() {
    registerFallbackValue(deepl);
    registerFallbackValue(
      const TranslationRequest(text: '', source: english, target: german),
    );
  });

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    repository = MockTranslationRepository();
    awake = FakeScreenAwake();
    when(() => repository.privacyMode).thenReturn(PrivacyMode.online);
  });

  test('on the web the default is the browser recogniser', () async {
    final recognizer = FakeSpeechRecognizer()..initResult = false;
    final service = SpeechInputService(
      store: MemoryStore(),
      adapter: recognizer,
      platformSupported: true,
      onDeviceSupported: false,
    );
    final cubit = TranscribeCubit(
      repository: repository,
      engine: () => deepl,
      source: english,
      target: german,
      speechInput: service,
      screenAwake: awake,
      isWeb: true,
    );
    await cubit.load();
    expect(cubit.state.mode, TranscribeMode.system);
    await cubit.start();
    await settle();
    expect(cubit.state.failure, isNotNull);
    await cubit.close();
    await service.dispose();
  });

  test('failed translations are tried again when translation is turned on '
      'again; unknown languages keep their code', () async {
    final transcriber = FakeTranscriber();
    var calls = 0;
    final sources = <String>[];
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      sources.add(request.source.code);
      calls++;
      return calls == 1
          ? Stream.error(Exception('down'))
          : Stream.value(
              const TranslationResult(
                engineId: 'mozhi:deepl',
                engineName: 'DeepL',
                text: 'ok',
              ),
            );
    });
    final offline = MockOfflineSpeech();
    when(() => offline.isAvailable).thenReturn(true);
    final listening = TranscribeCubit(
      repository: repository,
      engine: () => deepl,
      source: Language.auto,
      target: german,
      screenAwake: awake,
      transcriber: (_) => transcriber,
      offline: offline,
    );
    when(offline.isReady).thenAnswer((_) async => true);
    when(() => offline.vadModel).thenReturn(null);
    await listening.load();
    await listening.start();
    listening.setTranslate(enabled: true);
    transcriber.heard('Words.', start: 0, end: 1, language: 'qaa');
    await settle();
    expect(
      listening.state.entries.single.translationStatus,
      TranscriptTranslationStatus.failed,
    );
    listening
      ..setTranslate(enabled: false)
      ..setTranslate(enabled: true);
    await settle();
    expect(listening.state.entries.single.isTranslated, isTrue);
    expect(sources, ['qaa', 'qaa']);
    await listening.close();
  });
}
