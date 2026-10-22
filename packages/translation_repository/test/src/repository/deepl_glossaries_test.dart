import 'package:mocktail/mocktail.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/deepl_glossaries.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  group(DeeplGlossaries, () {
    late MockDeeplClient client;
    late DeeplGlossaries glossaries;
    const entries = {'server': 'Server', 'cloud': 'Wolke'};
    final name = DeeplGlossaries.nameFor(entries, source: 'en', target: 'de');

    DeeplGlossary glossary(String id, String name, {String to = 'de'}) =>
        DeeplGlossary(
          id: id,
          name: name,
          sourceLang: 'en',
          targetLang: to,
          entryCount: 2,
        );

    void stubCreate() => when(
      () => client.createGlossary(
        name: any(named: 'name'),
        sourceLang: any(named: 'sourceLang'),
        targetLang: any(named: 'targetLang'),
        entries: any(named: 'entries'),
      ),
    ).thenAnswer((invocation) async => glossary('new', name));

    setUp(() {
      client = MockDeeplClient();
      glossaries = DeeplGlossaries();
      when(() => client.deleteGlossary(any())).thenAnswer((_) async {});
    });

    Future<String?> idFor({
      String source = 'en',
      String target = 'DE',
      Map<String, String> glossary = entries,
    }) => glossaries.idFor(
      client,
      connection: 'c',
      sourceLanguage: source,
      targetLanguage: target,
      entries: glossary,
    );

    test('names are stable, order-independent and per pair', () {
      expect(name, startsWith('mozhi-'));
      expect(name, endsWith('-en-de'));
      expect(
        DeeplGlossaries.hashOf({'cloud': 'Wolke', 'server': 'Server'}),
        DeeplGlossaries.hashOf(entries),
      );
      expect(
        DeeplGlossaries.hashOf({'server': 'Rechner', 'cloud': 'Wolke'}),
        isNot(DeeplGlossaries.hashOf(entries)),
      );
      expect(DeeplGlossaries.hashOf(entries), hasLength(14));
    });

    test('validEntries trims and drops what DeepL rejects', () {
      expect(
        DeeplGlossaries.validEntries({
          ' server ': ' Server ',
          '': 'x',
          'a': ' ',
          'tab\there': 'x',
          'line': 'a\nb',
        }),
        {'server': 'Server'},
      );
    });

    test('reuses a glossary of the same name', () async {
      when(client.listGlossaries).thenAnswer(
        (_) async => [glossary('old', name), glossary('x', 'other')],
      );
      expect(await idFor(), 'old');
      expect(await idFor(), 'old');
      verify(client.listGlossaries).called(1);
      verifyNever(
        () => client.createGlossary(
          name: any(named: 'name'),
          sourceLang: any(named: 'sourceLang'),
          targetLang: any(named: 'targetLang'),
          entries: any(named: 'entries'),
        ),
      );
    });

    test('creates one and deletes the stale ones of the pair', () async {
      when(client.listGlossaries).thenAnswer(
        (_) async => [
          glossary('stale', 'mozhi-0000-en-de'),
          glossary('other-pair', 'mozhi-0000-en-fr', to: 'fr'),
          glossary('users', 'My glossary'),
        ],
      );
      stubCreate();
      expect(await idFor(), 'new');
      verify(
        () => client.createGlossary(
          name: name,
          sourceLang: 'en',
          targetLang: 'de',
          entries: entries,
        ),
      ).called(1);
      verify(() => client.deleteGlossary('stale')).called(1);
      verifyNever(() => client.deleteGlossary('other-pair'));
      verifyNever(() => client.deleteGlossary('users'));
    });

    test('gives null for failures, the same language and no entries', () async {
      when(client.listGlossaries)
          .thenThrow(const DeeplApiException('nope', kind: MtErrorKind.server));
      expect(await idFor(), isNull);
      // Not tried again this session.
      expect(await idFor(), isNull);
      verify(client.listGlossaries).called(1);
      expect(await idFor(source: 'en-GB', target: 'EN-US'), isNull);
      expect(await idFor(glossary: const {}), isNull);
      glossaries.clear();
      when(client.listGlossaries).thenAnswer((_) async => const []);
      stubCreate();
      expect(await idFor(), 'new');
    });
  });
}
