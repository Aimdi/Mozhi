// Temporary reproduction tests for a code review; deleted afterwards.
import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/ai_translation_stream.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockMozhiApiClient> mozhi;
  late TranslationRepository repository;
  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;
  MockMozhiApiClient c() => mozhi[instanceC.url]!;

  setUp(() {
    mozhi = {
      for (final i in [instanceA, instanceB, instanceC])
        i.url: MockMozhiApiClient(),
    };
    repository = TranslationRepository(
      mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
      llmClientFactory: (_) => MockLlmClient(),
      snapshotInterval: Duration.zero,
    );
  });

  When<Future<MozhiTranslation>> whenTranslate(MockMozhiApiClient client) =>
      when(
        () => client.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      );

  When<Future<List<MozhiTranslation>>> whenBatch(MockMozhiApiClient client) =>
      when(
        () => client.translateWithEngines(
          engines: any(named: 'engines'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      );

  const request = TranslationRequest(
    text: 'Hello',
    source: english,
    target: german,
  );

  test('R1 pool: user moving C to the top is ignored', () async {
    final pool = MozhiPool((uri) => mozhi[uri.toString()]!);
    pool.update([instanceA, instanceB, instanceC]);
    await pool.run((client, instance) async => null); // succeeds on A
    pool.update([instanceC, instanceA, instanceB]); // "Prefer C"
    expect(pool.active, instanceC);
  });

  test('R1 repo: Prefer instance still translates on the old one', () async {
    repository.updateConfiguration(
      instances: [instanceA, instanceB],
      providers: const [],
    );
    when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
    when(b().getEngines).thenAnswer((_) async => {'google': 'Google'});
    await repository.getEngines();
    repository.updateConfiguration(
      instances: [instanceB, instanceA],
      providers: const [],
    );
    final engines = await repository.getEngines();
    expect(engines.first.subtitle, instanceB.displayName);
  });

  test('R2 batch: empty 200 from A is not failed over to B', () async {
    repository.updateConfiguration(
      instances: [instanceA, instanceB],
      providers: const [],
    );
    whenBatch(a()).thenAnswer((_) async => const []);
    whenBatch(b()).thenAnswer(
      (_) async => const [
        MozhiTranslation(engine: 'google', translatedText: 'Hallo G'),
        MozhiTranslation(engine: 'deepl', translatedText: 'Hallo D'),
      ],
    );
    whenTranslate(a()).thenThrow(serverError());
    whenTranslate(b()).thenAnswer(
      (_) async => const MozhiTranslation(engine: 'x', translatedText: 'ok'),
    );
    final entries = await repository.compare([
      googleEngine,
      deeplEngine,
    ], request).toList();
    expect(entries.map((e) => e.isSuccess), everyElement(isTrue));
  });

  test('R3 pool: 404/301 from a broken instance does not fail over', () async {
    final pool = MozhiPool((uri) => mozhi[uri.toString()]!);
    pool.update([instanceA, instanceB]);
    final result = await pool.run((client, instance) async {
      if (instance == instanceA) {
        throw const MozhiApiException(
          'Redirected to https://new.example/api/translate',
          statusCode: 301,
        );
      }
      return 'ok';
    });
    expect(result, 'ok');
  });

  test('R4 engines cache returns another instance list', () async {
    repository.updateConfiguration(
      instances: [instanceA, instanceB],
      providers: const [],
    );
    when(a().getEngines).thenThrow(serverError());
    when(b().getEngines).thenAnswer((_) async => {'deepl': 'DeepL'});
    await repository.getEngines(); // cached under key A, content from B
    // B goes down, A comes back; a translation fails back over to A.
    whenTranslate(b()).thenThrow(serverError());
    whenTranslate(a()).thenAnswer(
      (_) async =>
          const MozhiTranslation(engine: 'google', translatedText: 'x'),
    );
    when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
    await repository.translate(googleEngine, request).drain<void>();
    expect(repository.activeInstance, instanceA);
    final engines = await repository.getEngines();
    expect(engines.first.subtitle, instanceA.displayName);
    expect(engines.first.id, 'mozhi:google');
  });

  test('R5 trailing marker leaks into snapshots', () async {
    final results = await aiTranslationStream(
      open: () => Stream.fromIterable(['Hallo', '\n[[lang:', 'en]]']),
      engine: aiEngine(claudeConfig),
      request: const TranslationRequest(
        text: 'Hello',
        source: Language.auto,
        target: german,
      ),
      snapshotInterval: Duration.zero,
    ).toList();
    for (final r in results) {
      expect(r.text, isNot(contains('[[')), reason: r.toString());
    }
  });

  test('R6 compare: unused c', () {
    expect(c(), isNotNull);
  });
}
