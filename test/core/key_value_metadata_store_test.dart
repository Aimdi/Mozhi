import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/bootstrap.dart';
import 'package:mozhi/core/key_value_metadata_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(KeyValueMetadataStore, () {
    test('reads and writes through the key-value store', () async {
      final prefs = MemoryStore({'a': '1'});
      final store = KeyValueMetadataStore(prefs);

      expect(await store.read('a'), '1');
      expect(await store.read('b'), isNull);
      await store.write('b', '2');
      expect(prefs.values, {'a': '1', 'b': '2'});
    });

    group('with credentials in the instance URL', () {
      const plainUrl = 'https://mozhi.example.org';
      const securedUrl = 'https://user:pass@mozhi.example.org';
      const prefix = 'translation_repository.metadata.v1';
      String key(String url) => '$prefix|$url|engines';
      String envelope(String url) => jsonEncode({
        'v': 1,
        'url': url,
        'name': 'engines',
        'data': <Object?>[],
      });

      test('stores them in neither the key nor the value', () async {
        final prefs = MemoryStore({key(securedUrl): 'old'});
        final store = KeyValueMetadataStore(prefs);

        await store.write(key(securedUrl), envelope(securedUrl));

        expect(prefs.values, {key(plainUrl): envelope(plainUrl)});
        expect(await store.read(key(securedUrl)), envelope(securedUrl));
      });

      test('reads nothing when nothing is stored', () async {
        final store = KeyValueMetadataStore(MemoryStore());

        expect(await store.read(key(securedUrl)), isNull);
      });

      test('passes other values through', () async {
        final prefs = MemoryStore();
        final store = KeyValueMetadataStore(prefs);

        await store.write(key(securedUrl), 'not json');
        expect(prefs.values, {key(plainUrl): 'not json'});
        expect(await store.read(key(securedUrl)), 'not json');

        await store.write(key(securedUrl), envelope('https://other.example'));
        expect(
          await store.read(key(securedUrl)),
          envelope('https://other.example'),
        );
      });
    });
  });

  group('createDependencies', () {
    test('serves the engine list persisted in the preferences', () async {
      final instance = MozhiInstance.publicInstances.first;
      final prefs = MemoryStore({
        'translation_repository.metadata.v1|${instance.url}|engines':
            jsonEncode({
              'v': 1,
              'url': instance.url,
              'name': 'engines',
              'savedAt': DateTime.now().millisecondsSinceEpoch,
              'data': [
                {'id': 'google', 'name': 'Google'},
              ],
            }),
      });

      final dependencies = await createDependencies(
        prefs: prefs,
        secrets: MemoryStore(),
      );
      final repository = dependencies.translationRepository;
      final engines = await repository.getEngines();
      repository.dispose();

      expect(engines.first.id, 'mozhi:google');
      expect(engines.first.subtitle, instance.displayName);
      await dependencies.speechInputService.dispose();
      await dependencies.usageTracker.dispose();
    });
  });
}
