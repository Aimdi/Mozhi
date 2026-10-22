import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../helpers/fake_models.dart';
import 'fake_bergamot_worker.dart';

void main() {
  late FakeBergamotWorker worker;
  late FakeModelServer server;
  late BergamotTranslator translator;
  late int persistRequests;

  setUp(() {
    worker = FakeBergamotWorker();
    final models = [
      FakeModel('en', 'de'),
      FakeModel('de', 'en'),
      FakeModel('es', 'en'),
      FakeModel('en', 'es'),
    ];
    server = FakeModelServer(models);
    persistRequests = 0;
    translator = createWebBergamotTranslator(
      catalog: catalogOf(models),
      channel: worker,
      httpClient: server.client,
      isAvailable: true,
      requestPersistence: () async {
        persistRequests++;
        return true;
      },
    );
  });

  test('is built from the worker parts', () {
    expect(translator.isAvailable, isTrue);
    expect(translator.models, isA<OpfsModelManager>());
    expect(translator.engine, isA<WorkerBergamotEngine>());
    expect(translator.languageId, isA<WorkerLanguageIdentifier>());
    expect(translator.supportedLanguages, containsAll(['en', 'de', 'es']));
  });

  test('downloads a language, then translates and pivots', () async {
    await translator.downloadLanguage('de');
    expect(await translator.downloadedLanguages(), {'en', 'de'});
    expect(persistRequests, 1);
    expect(
      await translator.translate('Hello', source: 'en', target: 'de'),
      'HELLO',
    );
    await translator.downloadLanguage('es');
    expect(
      await translator.translate('Hola', source: 'es', target: 'de'),
      'HOLA',
    );
    final (_, arguments) = worker.requests.lastWhere(
      (request) => request.$1 == 'translate',
    );
    expect(
      [
        for (final model in arguments['chain']! as List<Object?>)
          (model! as Map<String, Object?>)['key'],
      ],
      ['es-en/run1', 'en-de/run1'],
    );
  });

  test('details carry the low-confidence decision', () async {
    await translator.downloadLanguage('de');
    final result = await translator.translateDetailed(
      'Hello',
      source: 'en',
      target: 'de',
    );
    expect(result.text, 'HELLO');
    expect(result.sentences.single.isLowConfidence, isFalse);
  });

  test('identifies with CLD2 in the worker', () async {
    await translator.downloadLanguage('de');
    expect(await translator.identifyLanguage('Guten Morgen'), 'de');
    expect(worker.ops, contains('identify'));
  });

  test('preload and delete reach the worker', () async {
    await translator.downloadLanguage('de');
    expect(await translator.preload(source: 'en', target: 'de'), isTrue);
    expect(worker.loaded, ['en-de/run1']);
    await translator.deleteLanguage('de');
    expect(worker.loaded, isEmpty);
    expect(await translator.downloadedLanguages(), {'en'});
    expect(worker.files, isEmpty);
  });

  test('a missing model says which language to download', () async {
    await expectLater(
      translator.translate('Hello', source: 'en', target: 'de'),
      throwsA(isA<OfflineModelMissingException>()),
    );
  });
}
