import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// The Mozhi requests other than text translation (language detection,
/// read-aloud, image translation) fail over like a translation, end in an
/// [AllInstancesFailedException] when every server failed, keep to the
/// privacy settings while failing over, and count for the instance health
/// only when they say something about translating (images).
void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockMozhiApiClient> mozhi;
  late MemoryInstanceHealthStore store;
  late FakeOfflineTranslator? offline;
  final now = DateTime.utc(2026, 10, 30, 12);
  final png = Uint8List.fromList([137, 80, 78, 71]);

  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;
  MockMozhiApiClient c() => mozhi[instanceC.url]!;

  Future<TranslationRepository> newRepository({
    List<MozhiInstance> instances = const [instanceA, instanceB],
    List<AiProviderConfig> providers = const [],
  }) async {
    final health = InstanceHealth(store: store, clock: () => now);
    await health.ready;
    return allowNetwork(
      TranslationRepository(
        mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
        llmClientFactory: (_) => MockLlmClient(),
        offline: offline,
        snapshotInterval: Duration.zero,
        instanceHealth: health,
      ),
    )..updateConfiguration(instances: instances, providers: providers);
  }

  When<Future<MozhiTranslation>> whenTranslate(MockMozhiApiClient client) =>
      when(
        () => client.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      );

  void detects(MockMozhiApiClient client, [String code = 'de']) =>
      whenTranslate(client).thenAnswer(
        (_) async => MozhiTranslation(
          engine: 'google',
          translatedText: 'Hello',
          detectedLanguage: code,
        ),
      );

  When<Future<Uint8List>> whenSpeech(MockMozhiApiClient client) => when(
    () => client.textToSpeech(
      engine: any(named: 'engine'),
      language: any(named: 'language'),
      text: any(named: 'text'),
    ),
  );

  When<Future<MozhiImageTranslation>> whenImage(MockMozhiApiClient client) =>
      when(
        () => client.translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          engine: any(named: 'engine'),
          timeout: any(named: 'timeout'),
        ),
      );

  void translatesImage(MockMozhiApiClient client) =>
      whenImage(client).thenAnswer(
        (_) async => const MozhiImageTranslation(
          translatedImageBase64: '',
          sourceText: 'Hallo',
          translatedText: 'Hello',
        ),
      );

  Future<ImageTranslationResult> translateImage(
    TranslationRepository repository,
  ) => repository.translateImage(
    googleEngine,
    png,
    mimeType: 'image/png',
    source: Language.auto,
    target: english,
  );

  Matcher allFailed({
    required String engine,
    required List<MozhiInstance> instances,
  }) => isA<AllInstancesFailedException>()
      .having((e) => e.engine.id, 'engine', engine)
      .having((e) => e.instances, 'instances', instances)
      .having((e) => e.statusCode, 'statusCode', 502);

  setUp(() {
    mozhi = {
      for (final instance in [instanceA, instanceB, instanceC])
        instance.url: MockMozhiApiClient(),
    };
    store = MemoryInstanceHealthStore();
    offline = null;
  });

  group('language detection', () {
    test('fails over to the next server', () async {
      whenTranslate(a()).thenThrow(serverError());
      detects(b());
      final repository = await newRepository();
      expect((await repository.detectLanguage('Hallo')).code, 'de');
      expect(repository.activeInstance, instanceB);
    });

    test('every server failing is an AllInstancesFailedException '
        'that does not count', () async {
      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenThrow(serverError());
      final repository = await newRepository();
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(
          allFailed(engine: 'mozhi:google', instances: [instanceA, instanceB]),
        ),
      );
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
      expect(repository.instanceHealth.isCoolingDown(instanceB.url), isFalse);
      await repository.instanceHealth.saved;
      expect(store.saves, 0);
    });

    test('an input error is not failed over', () async {
      whenTranslate(a()).thenThrow(
        const MozhiApiException(
          'Target language code invalid',
          statusCode: 500,
        ),
      );
      final repository = await newRepository();
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(
          isA<MozhiApiException>().having(
            (e) => e is AllInstancesFailedException,
            'all servers',
            isFalse,
          ),
        ),
      );
      verifyZeroInteractions(b());
    });

    test('for a translation, the failure is the cause of the '
        'SourceLanguageRequiredException', () async {
      offline = FakeOfflineTranslator();
      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenThrow(serverError());
      final repository = await newRepository(providers: [cloudGemmaConfig]);
      await expectLater(
        repository.translate(
          aiEngine(cloudGemmaConfig),
          const TranslationRequest(
            text: 'Hallo Welt',
            source: Language.auto,
            target: english,
          ),
        ),
        emitsError(
          isA<SourceLanguageRequiredException>().having(
            (e) => e.cause,
            'cause',
            allFailed(
              engine: 'mozhi:google',
              instances: [instanceA, instanceB],
            ),
          ),
        ),
      );
      await repository.instanceHealth.saved;
      expect(store.saves, 0);
    });

    test('stops failing over when offline only is turned on '
        'meanwhile', () async {
      late TranslationRepository repository;
      whenTranslate(a()).thenAnswer((_) async {
        repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
        throw serverError();
      });
      detects(b());
      repository = await newRepository();
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(allFailed(engine: 'mozhi:google', instances: [instanceA])),
      );
      verifyZeroInteractions(b());
    });

    test('asks for consent before anything is sent', () async {
      final repository = await newRepository();
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(isA<ConsentRequiredException>()),
      );
      verifyZeroInteractions(a());
      verifyZeroInteractions(b());
    });
  });

  group('read-aloud', () {
    test('fails over to the next server', () async {
      whenSpeech(a()).thenThrow(serverError());
      whenSpeech(b()).thenAnswer((_) async => Uint8List.fromList([1, 2]));
      final repository = await newRepository();
      expect(await repository.textToSpeech(text: 'Hallo', languageCode: 'de'), [
        1,
        2,
      ]);
      verifyNever(
        () => a().textToSpeech(
          engine: 'reverso',
          language: any(named: 'language'),
          text: any(named: 'text'),
        ),
      );
    });

    test('every server failing is an AllInstancesFailedException for '
        'Google that does not count', () async {
      whenSpeech(a()).thenThrow(serverError());
      whenSpeech(b()).thenThrow(serverError());
      final repository = await newRepository();
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(
          allFailed(engine: 'mozhi:google', instances: [instanceA, instanceB]),
        ),
      );
      // Reverso was asked on every server too, before giving up.
      for (final client in [a(), b()]) {
        verify(
          () => client.textToSpeech(
            engine: 'reverso',
            language: 'de',
            text: 'Hallo',
          ),
        ).called(1);
      }
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
      await repository.instanceHealth.saved;
      expect(store.saves, 0);
    });

    test('names Reverso when it was asked for', () async {
      whenSpeech(a()).thenThrow(serverError());
      whenSpeech(b()).thenThrow(serverError());
      final repository = await newRepository();
      await expectLater(
        repository.textToSpeech(
          text: 'Hallo',
          languageCode: 'de',
          engine: 'reverso',
        ),
        throwsA(
          isA<AllInstancesFailedException>().having(
            (e) => e.engine.name,
            'engine',
            'Reverso',
          ),
        ),
      );
    });

    test('stops failing over when offline only is turned on '
        'meanwhile', () async {
      late TranslationRepository repository;
      whenSpeech(a()).thenAnswer((_) async {
        repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
        throw serverError();
      });
      whenSpeech(b()).thenAnswer((_) async => Uint8List.fromList([1]));
      repository = await newRepository();
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(allFailed(engine: 'mozhi:google', instances: [instanceA])),
      );
      verifyZeroInteractions(b());
    });

    test('asks for consent before anything is sent', () async {
      final repository = await newRepository();
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(isA<ConsentRequiredException>()),
      );
      verifyZeroInteractions(a());
      verifyZeroInteractions(b());
    });
  });

  group('image translation', () {
    test('fails over to the next server', () async {
      whenImage(a()).thenThrow(serverError());
      translatesImage(b());
      final repository = await newRepository();
      final result = await translateImage(repository);
      expect(result.translatedText, 'Hello');
      expect(
        result.destination,
        const PublicInstanceDestination('b.example', engine: 'google'),
      );
    });

    test('every server failing is an AllInstancesFailedException for '
        'Google that counts', () async {
      whenImage(a()).thenThrow(serverError());
      whenImage(b()).thenThrow(serverError());
      final repository = await newRepository();
      await expectLater(
        translateImage(repository),
        throwsA(
          allFailed(engine: 'mozhi:google', instances: [instanceA, instanceB]),
        ),
      );
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isTrue);
      expect(repository.instanceHealth.isCoolingDown(instanceB.url), isTrue);
      await repository.instanceHealth.saved;
      expect(
        store.failures.keys,
        unorderedEquals([instanceA.url, instanceB.url]),
      );
    });

    test('the photo goes to two servers at most', () async {
      whenImage(a()).thenThrow(serverError());
      whenImage(b()).thenThrow(serverError());
      translatesImage(c());
      final repository = await newRepository(
        instances: [instanceA, instanceB, instanceC],
      );
      await expectLater(
        translateImage(repository),
        throwsA(
          allFailed(engine: 'mozhi:google', instances: [instanceA, instanceB]),
        ),
      );
      verifyZeroInteractions(c());
    });

    test('stops failing over when offline only is turned on '
        'meanwhile', () async {
      late TranslationRepository repository;
      whenImage(a()).thenAnswer((_) async {
        repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
        throw serverError();
      });
      translatesImage(b());
      repository = await newRepository();
      await expectLater(
        translateImage(repository),
        throwsA(allFailed(engine: 'mozhi:google', instances: [instanceA])),
      );
      verifyNever(
        () => b().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          engine: any(named: 'engine'),
          timeout: any(named: 'timeout'),
        ),
      );
    });

    test('asks for consent before the photo is sent', () async {
      final repository = await newRepository();
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        translateImage(repository),
        throwsA(isA<ConsentRequiredException>()),
      );
      verifyZeroInteractions(a());
      verifyZeroInteractions(b());
    });
  });
}
