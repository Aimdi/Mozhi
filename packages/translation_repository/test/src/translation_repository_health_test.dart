import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockMozhiApiClient> mozhi;
  late MemoryInstanceHealthStore store;
  final now = DateTime.utc(2026, 10, 30, 12);

  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;

  const request = TranslationRequest(
    text: 'Hello',
    source: english,
    target: german,
  );

  Future<TranslationRepository> newRepository() async {
    final health = InstanceHealth(store: store, clock: () => now);
    await health.ready;
    return allowNetwork(
      TranslationRepository(
        mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
        snapshotInterval: Duration.zero,
        instanceHealth: health,
      ),
    )..updateConfiguration(instances: [instanceA, instanceB], providers: []);
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

  void answers(MockMozhiApiClient client) => whenTranslate(client).thenAnswer(
    (_) async =>
        const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
  );

  setUp(() {
    mozhi = {
      for (final instance in [instanceA, instanceB])
        instance.url: MockMozhiApiClient(),
    };
    store = MemoryInstanceHealthStore();
  });

  test('a failed server is asked last, also after a restart', () async {
    whenTranslate(a()).thenThrow(serverError());
    answers(b());
    final first = await newRepository();
    await first.translate(googleEngine, request).drain<void>();
    expect(first.instanceHealth.isCoolingDown(instanceA.url), isTrue);
    await first.instanceHealth.saved;
    expect(store.failures.keys, [instanceA.url]);

    clearInteractions(a());
    final second = await newRepository();
    expect(second.activeInstance, instanceB);
    final result = await second
        .translate(googleEngine, request.copyWith(text: 'Hi'))
        .last;
    expect(result.text, 'Hallo');
    verifyZeroInteractions(a());
  });

  test('every server failing is an AllInstancesFailedException', () async {
    whenTranslate(a()).thenThrow(serverError('a'));
    whenTranslate(b()).thenThrow(serverError('b'));
    final repository = await newRepository();
    await expectLater(
      repository.translate(googleEngine, request),
      emitsError(
        isA<AllInstancesFailedException>()
            .having((e) => e.engine.id, 'engine', googleEngine.id)
            .having((e) => e.instances, 'instances', [instanceA, instanceB])
            .having((e) => e.message, 'message', 'b')
            .having((e) => e.statusCode, 'statusCode', 502),
      ),
    );
  });

  test('resetActiveInstance forgets the failures', () async {
    whenTranslate(a()).thenThrow(serverError());
    answers(b());
    final repository = await newRepository();
    await repository.translate(googleEngine, request).drain<void>();
    repository.resetActiveInstance();
    expect(repository.activeInstance, instanceA);
    await repository.instanceHealth.saved;
    expect(store.failures, isEmpty);
  });

  test('engine lists do not count', () async {
    when(a().getEngines).thenThrow(serverError());
    when(b().getEngines).thenAnswer((_) async => {'google': 'Google'});
    final repository = await newRepository();
    await repository.getEngines();
    expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
  });

  test('a translation that got no answer counts for this session '
      'only', () async {
    whenTranslate(a()).thenThrow(const MozhiApiException('Connection reset'));
    answers(b());
    final first = await newRepository();
    await first.translate(googleEngine, request).drain<void>();
    expect(first.instanceHealth.isCoolingDown(instanceA.url), isTrue);
    await first.instanceHealth.saved;
    expect(store.failures, isEmpty);

    // After a restart the user's first server is asked first again.
    final second = await newRepository();
    expect(second.activeInstance, instanceA);
  });

  test('preferInstance puts the first server first again', () async {
    whenTranslate(a()).thenThrow(serverError());
    answers(b());
    final repository = await newRepository();
    await repository.translate(googleEngine, request).drain<void>();
    expect(repository.activeInstance, instanceB);

    repository.preferInstance(instanceA.url);

    expect(repository.activeInstance, instanceA);
    expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
    await repository.instanceHealth.saved;
    expect(store.failures, isEmpty);
  });

  test('read-aloud does not count', () async {
    when(
      () => a().textToSpeech(
        engine: any(named: 'engine'),
        language: any(named: 'language'),
        text: any(named: 'text'),
      ),
    ).thenThrow(serverError());
    when(
      () => b().textToSpeech(
        engine: any(named: 'engine'),
        language: any(named: 'language'),
        text: any(named: 'text'),
      ),
    ).thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));
    final repository = await newRepository();
    await repository.textToSpeech(text: 'Hallo', languageCode: 'de');
    expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
    expect(repository.instanceHealth.isCoolingDown(instanceB.url), isFalse);
    await repository.instanceHealth.saved;
    expect(store.saves, 0);
  });

  test('language detection does not count', () async {
    whenTranslate(a()).thenThrow(serverError());
    whenTranslate(b()).thenAnswer(
      (_) async => const MozhiTranslation(
        engine: 'google',
        translatedText: 'Hello',
        detectedLanguage: 'de',
      ),
    );
    final repository = await newRepository();
    final detected = await repository.detectLanguage('Hallo');
    expect(detected.code, 'de');
    expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
    await repository.instanceHealth.saved;
    expect(store.saves, 0);
  });

  test('image translation counts like a translation', () async {
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
    whenImage(a()).thenThrow(serverError());
    whenImage(b()).thenAnswer(
      (_) async => const MozhiImageTranslation(
        translatedImageBase64: '',
        translatedText: 'Hello',
      ),
    );
    final repository = await newRepository();
    await repository.translateImage(
      googleEngine,
      Uint8List.fromList([137, 80, 78, 71]),
      mimeType: 'image/png',
      source: Language.auto,
      target: english,
    );
    expect(repository.instanceHealth.isCoolingDown(instanceA.url), isTrue);
    await repository.instanceHealth.saved;
    expect(store.failures.keys, [instanceA.url]);
  });

  group('pingInstance', () {
    test('a translation marks the server working', () async {
      store.failures = {instanceA.url: now};
      answers(a());
      final repository = await newRepository();
      await repository.pingInstance(instanceA);
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
    });

    test('a server that does not translate is marked failed', () async {
      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'Hello'),
      );
      final repository = await newRepository();
      await expectLater(
        repository.pingInstance(instanceA),
        throwsA(isA<InstanceDoesNotTranslateException>()),
      );
      await expectLater(
        repository.pingInstance(instanceB),
        throwsA(isA<InstanceDoesNotTranslateException>()),
      );
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isTrue);
      expect(repository.instanceHealth.isCoolingDown(instanceB.url), isTrue);
    });

    test('a network failure marks the server failed for this session '
        'only', () async {
      whenTranslate(a()).thenThrow(const MozhiApiException('refused'));
      final repository = await newRepository();
      await expectLater(
        repository.pingInstance(instanceA),
        throwsA(isA<MozhiApiException>()),
      );
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isTrue);
      await repository.instanceHealth.saved;
      expect(store.failures, isEmpty);
    });

    test('a server that does not translate is remembered', () async {
      whenTranslate(a()).thenThrow(serverError());
      final repository = await newRepository();
      await expectLater(
        repository.pingInstance(instanceA),
        throwsA(isA<InstanceDoesNotTranslateException>()),
      );
      await repository.instanceHealth.saved;
      expect(store.failures.keys, [instanceA.url]);
    });

    test('a missing engine, a timeout or a bad request do not', () async {
      final repository = await newRepository();
      for (final error in [
        const MozhiApiException(
          'Engine does not exist or has been disabled',
          statusCode: 500,
        ),
        const MozhiApiException('No response within 10000 ms'),
        badRequest(),
      ]) {
        whenTranslate(a()).thenThrow(error);
        await expectLater(
          repository.pingInstance(instanceA),
          throwsA(isA<MozhiApiException>()),
        );
      }
      expect(repository.instanceHealth.isCoolingDown(instanceA.url), isFalse);
    });
  });

  test('without an InstanceHealth, the repository keeps one in memory', () {
    final repository = TranslationRepository();
    expect(repository.instanceHealth.order([instanceA]), [instanceA]);
  });
}
