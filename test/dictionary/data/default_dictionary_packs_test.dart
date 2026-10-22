import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart';
import 'package:mozhi/dictionary/data/dictionary_catalog_data.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  test('the bundled catalogue parses', () {
    expect(
      bundledDictionaryCatalog().packs,
      DictionaryPackCatalog.parse(dictionaryCatalogJson).packs,
    );
    expect(bundledDictionaryCatalog('not json').isEmpty, isTrue);
  });

  test('defaultDictionaryPacks is shared', () {
    final packs = defaultDictionaryPacks();
    expect(identical(packs, defaultDictionaryPacks()), isTrue);
    expect(packs.isSupported, isTrue);
  });

  group('dictionaryPackUrls', () {
    final pack = DictionaryPackInfo(
      id: 'es',
      language: 'es',
      name: 'Spanish',
      url: Uri.parse(
        'https://github.com/Aimdi/Mozhi/releases/download/r/es.mzd',
      ),
      size: 1,
      sha256: 'a' * 64,
    );

    test('uses the catalogue without a mirror', () {
      expect(dictionaryPackUrls(pack, source: ModelSource.defaultHosts), [
        pack.url,
      ]);
    });

    test('asks a mirror first, then the catalogue when allowed', () {
      expect(
        dictionaryPackUrls(
          pack,
          source: const ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'https://mirror.example/models/',
            fallbackToDefault: true,
          ),
        ),
        [
          Uri.parse('https://mirror.example/models/dictionary/es.mzd'),
          pack.url,
        ],
      );
    });

    test('follows the current model source', () {
      final current = ModelSource.current;
      addTearDown(() => ModelSource.current = current);
      ModelSource.current = const ModelSource(
        kind: ModelSourceKind.custom,
        customUrl: 'https://mirror.example/m/',
      );
      expect(dictionaryPackUrls(pack), [
        Uri.parse('https://mirror.example/m/dictionary/es.mzd'),
      ]);
    });
  });

  test('SessionHttpClient sends with the current session', () async {
    final current = NetworkSession.current;
    addTearDown(() => NetworkSession.current = current);
    final sent = <Uri>[];
    NetworkSession.current = NetworkSession(
      httpClient: MockClient((request) async {
        sent.add(request.url);
        return http.Response('ok', 200);
      }),
    );
    final client = SessionHttpClient();
    final response = await client.get(Uri.parse('https://example.org/es.mzd'));
    expect(response.statusCode, 200);
    expect(sent, [Uri.parse('https://example.org/es.mzd')]);
    client.close();
  });

  test('SessionHttpClient lists pack downloads as model downloads', () async {
    final current = NetworkSession.current;
    addTearDown(() => NetworkSession.current = current);
    final session = NetworkSession(
      httpClient: MockClient((request) async => http.Response('ok', 200)),
    );
    NetworkSession.current = session;
    await SessionHttpClient().get(
      Uri.parse('https://mirror.example/models/dictionary/es.mzd'),
    );
    expect(session.ledger.entries.single.purpose, EgressPurpose.modelDownload);
  });

  testWidgets('maybeDictionaryPacks reads the provided packs', (tester) async {
    final packs = DictionaryPacks(
      catalog: DictionaryPackCatalog(const []),
      storage: MemoryDictionaryPackStorage(),
    );
    DictionaryPacks? found;
    DictionaryPacks? missing;
    await tester.pumpWidget(
      Column(
        children: [
          Builder(
            builder: (context) {
              missing = maybeDictionaryPacks(context);
              return const SizedBox();
            },
          ),
          RepositoryProvider.value(
            value: packs,
            child: Builder(
              builder: (context) {
                found = maybeDictionaryPacks(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(found, same(packs));
    expect(missing, isNull);
  });
}
