import 'dart:async';
import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/cache/persisted_metadata.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

class _MockMetadataStore extends Mock implements MetadataStore;

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockMozhiApiClient> mozhi;
  late MemoryMetadataStore store;
  late DateTime now;
  late TranslationRepository repository;
  late List<void> changes;

  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;
  MockMozhiApiClient c() => mozhi[instanceC.url]!;

  TranslationRepository newRepository({MetadataStore? metadataStore}) {
    final created = TranslationRepository(
      mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
      metadataStore: metadataStore ?? store,
      clock: () => now,
    );
    created.metadataChanged.listen(changes.add);
    return created;
  }

  void configure(
    TranslationRepository target, {
    List<MozhiInstance> instances = const [instanceA, instanceB],
    List<AiProviderConfig> providers = const [],
  }) => target.updateConfiguration(instances: instances, providers: providers);

  /// A new launch: a fresh repository on the same store.
  TranslationRepository relaunch({
    List<MozhiInstance> instances = const [instanceA, instanceB],
    List<AiProviderConfig> providers = const [],
  }) {
    repository.dispose();
    repository = newRepository();
    configure(repository, instances: instances, providers: providers);
    return repository;
  }

  void stubEngines(MockMozhiApiClient client, Map<String, String> engines) =>
      when(client.getEngines).thenAnswer((_) async => engines);

  void stubOffline(MockMozhiApiClient client) {
    when(client.getEngines).thenThrow(const MozhiApiException('offline'));
    when(() => client.getSourceLanguages(any()))
        .thenThrow(const MozhiApiException('offline'));
    when(() => client.getTargetLanguages(any()))
        .thenThrow(const MozhiApiException('offline'));
  }

  String engineKey(MozhiInstance instance) =>
      PersistedMetadata.keyFor(instance.url, 'engines');

  String languagesKey(MozhiInstance instance, String engine, String side) =>
      PersistedMetadata.keyFor(instance.url, '$engine|$side');

  void storeRaw(String key, {required Object? data, DateTime? savedAt}) {
    final url = key.split('|')[1];
    final name = key.split('|').skip(2).join('|');
    store.values[key] = jsonEncode({
      'v': PersistedMetadata.version,
      'url': url,
      'name': name,
      'savedAt': (savedAt ?? now).millisecondsSinceEpoch,
      'data': data,
    });
  }

  void storeEngines(
    MozhiInstance instance,
    Map<String, String> engines, {
    DateTime? savedAt,
  }) => storeRaw(
    engineKey(instance),
    data: [
      for (final MapEntry(:key, :value) in engines.entries)
        {'id': key, 'name': value},
    ],
    savedAt: savedAt,
  );

  Object? storedData(String key) =>
      (jsonDecode(store.values[key]!) as Map<String, Object?>)['data'];

  List<String> ids(List<TranslationEngine> engines) => [
    for (final engine in engines) engine.id,
  ];

  setUp(() {
    mozhi = {
      for (final instance in [instanceA, instanceB, instanceC])
        instance.url: MockMozhiApiClient(),
    };
    store = MemoryMetadataStore();
    now = DateTime(2026, 10, 14, 12);
    changes = [];
    repository = newRepository();
    configure(repository);
  });

  tearDown(() => repository.dispose());

  group('engines', () {
    test('first launch loads from the network and stores the list', () async {
      stubEngines(a(), {'google': 'Google', 'deepl': ''});

      final engines = await repository.getEngines();

      expect(ids(engines), ['mozhi:google', 'mozhi:deepl']);
      expect(engines[1].name, 'deepl');
      await pumpEventQueue();
      expect(storedData(engineKey(instanceA)), [
        {'id': 'google', 'name': 'Google'},
        {'id': 'deepl', 'name': ''},
      ]);
      expect(changes, isEmpty);
    });

    test('next launch serves the stored list without waiting', () async {
      storeEngines(instanceA, {'google': 'Google', 'deepl': 'DeepL'});
      final pending = Completer<Map<String, String>>();
      when(a().getEngines).thenAnswer((_) => pending.future);

      final engines = await repository.getEngines();

      expect(ids(engines), ['mozhi:google', 'mozhi:deepl']);
      expect(engines.first.subtitle, instanceA.displayName);
      expect(engines.first.mozhiEngine, 'google');
      expect(engines.first.kind, EngineKind.mozhi);
      verify(a().getEngines).called(1);
      pending.complete({'google': 'Google', 'deepl': 'DeepL'});
      await pumpEventQueue();
      expect(changes, isEmpty, reason: 'the list did not change');
    });

    test('a changed list replaces the stored one and is announced', () async {
      storeEngines(instanceA, {
        'google': 'Google',
      }, savedAt: now.subtract(const Duration(days: 2)));
      stubEngines(a(), {'google': 'Google', 'libre': 'Libre'});

      final stale = await repository.getEngines();
      expect(ids(stale), ['mozhi:google']);

      await pumpEventQueue();
      expect(changes, hasLength(1));
      final fresh = await repository.getEngines();
      expect(ids(fresh), ['mozhi:google', 'mozhi:libre']);
      verify(a().getEngines).called(1);
      expect(storedData(engineKey(instanceA)), [
        {'id': 'google', 'name': 'Google'},
        {'id': 'libre', 'name': 'Libre'},
      ]);
      final savedAt = (jsonDecode(
        store.values[engineKey(instanceA)]!,
      ) as Map<String, Object?>)['savedAt'];
      expect(savedAt, now.millisecondsSinceEpoch);
    });

    test('concurrent calls share one load', () async {
      storeEngines(instanceA, {'google': 'Google'});
      stubEngines(a(), {'google': 'Google'});

      final results = await Future.wait([
        repository.getEngines(),
        repository.getEngines(),
      ]);

      expect(ids(results[0]), ids(results[1]));
      await pumpEventQueue();
      verify(a().getEngines).called(1);
    });

    test(
      'offline serves the stored list and retries on the next call',
      () async {
        storeEngines(instanceA, {'google': 'Google'});
        stubOffline(a());
        stubOffline(b());

        expect(ids(await repository.getEngines()), ['mozhi:google']);
        await pumpEventQueue();
        expect(ids(await repository.getEngines()), ['mozhi:google']);
        await pumpEventQueue();

        verify(a().getEngines).called(2);
        verify(b().getEngines).called(2);
        expect(changes, isEmpty);
        expect(storedData(engineKey(instanceA)), [
          {'id': 'google', 'name': 'Google'},
        ]);
      },
    );

    test('lists older than the maximum age are not served', () async {
      storeEngines(instanceA, {
        'google': 'Google',
      }, savedAt: now.subtract(TranslationRepository.defaultMetadataMaxAge));
      stubOffline(a());
      stubOffline(b());

      await expectLater(
        repository.getEngines(),
        throwsA(isA<MozhiApiException>()),
      );
    });

    test('expired lists are replaced from the network', () async {
      storeEngines(instanceA, {
        'google': 'Google',
      }, savedAt: now.subtract(const Duration(days: 30)));
      stubEngines(a(), {'deepl': 'DeepL'});

      expect(ids(await repository.getEngines()), ['mozhi:deepl']);
      await pumpEventQueue();
      expect(changes, isEmpty);
      expect(storedData(engineKey(instanceA)), [
        {'id': 'deepl', 'name': 'DeepL'},
      ]);
    });

    test('a custom maximum age applies', () async {
      repository.dispose();
      repository = TranslationRepository(
        mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
        metadataStore: store,
        metadataMaxAge: const Duration(hours: 1),
        clock: () => now,
      );
      configure(repository);
      storeEngines(instanceA, {
        'google': 'Google',
      }, savedAt: now.subtract(const Duration(hours: 2)));
      stubEngines(a(), {'deepl': 'DeepL'});

      expect(ids(await repository.getEngines()), ['mozhi:deepl']);
    });

    test('errors are never stored', () async {
      stubOffline(a());
      stubOffline(b());

      await expectLater(
        repository.getEngines(),
        throwsA(isA<MozhiApiException>()),
      );
      await pumpEventQueue();

      expect(store.values, isEmpty);
    });

    test('AI and offline engines are computed, not stored', () async {
      repository.dispose();
      repository = TranslationRepository(
        mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
        metadataStore: store,
        offline: FakeOfflineTranslator(),
        clock: () => now,
      );
      configure(repository, instances: const [], providers: [claudeConfig]);

      final engines = await repository.getEngines();

      expect(ids(engines), ['ai:claude', 'offline:mlkit']);
      await pumpEventQueue();
      expect(store.values, isEmpty);
    });

    test('stored Mozhi engines come before the computed ones', () async {
      relaunch(providers: [claudeConfig]);
      storeEngines(instanceA, {'google': 'Google'});
      stubOffline(a());
      stubOffline(b());

      expect(ids(await repository.getEngines()), ['mozhi:google', 'ai:claude']);
    });

    group('corrupt data is ignored', () {
      final cases = <String, Object? Function()>{
        'data that is not a list': () => {'google': 'Google'},
        'an engine without a name': () => [
          {'id': 'google'},
        ],
        'an engine with a numeric id': () => [
          {'id': 1, 'name': 'One'},
        ],
        'an item that is not an object': () => ['google'],
      };
      for (final MapEntry(key: description, value: data) in cases.entries) {
        test(description, () async {
          storeRaw(engineKey(instanceA), data: data());
          stubEngines(a(), {'deepl': 'DeepL'});

          expect(ids(await repository.getEngines()), ['mozhi:deepl']);
          await pumpEventQueue();
          expect(storedData(engineKey(instanceA)), [
            {'id': 'deepl', 'name': 'DeepL'},
          ]);
        });
      }

      test('invalid JSON', () async {
        store.values[engineKey(instanceA)] = '{"v":1,"url":';
        stubEngines(a(), {'deepl': 'DeepL'});

        expect(ids(await repository.getEngines()), ['mozhi:deepl']);
      });
    });

    group('refresh', () {
      test('loads from the network first', () async {
        storeEngines(instanceA, {'google': 'Google'});
        stubEngines(a(), {'deepl': 'DeepL'});

        expect(ids(await repository.getEngines(refresh: true)), [
          'mozhi:deepl',
        ]);
        await pumpEventQueue();
        expect(changes, isEmpty);
        expect(storedData(engineKey(instanceA)), [
          {'id': 'deepl', 'name': 'DeepL'},
        ]);
        expect(ids(await repository.getEngines()), ['mozhi:deepl']);
        verify(a().getEngines).called(1);
      });

      test('falls back to the stored list when offline', () async {
        storeEngines(instanceA, {'google': 'Google'});
        stubOffline(a());
        stubOffline(b());

        expect(ids(await repository.getEngines(refresh: true)), [
          'mozhi:google',
        ]);
      });

      test('without a stored list fails as before', () async {
        stubOffline(a());
        stubOffline(b());

        await expectLater(
          repository.getEngines(refresh: true),
          throwsA(isA<MozhiApiException>()),
        );
      });

      test('drops a revalidation that is still running', () async {
        storeEngines(instanceA, {'google': 'Google'});
        final pending = Completer<Map<String, String>>();
        when(a().getEngines).thenAnswer((_) => pending.future);
        expect(ids(await repository.getEngines()), ['mozhi:google']);

        stubEngines(a(), {'deepl': 'DeepL'});
        expect(ids(await repository.getEngines(refresh: true)), [
          'mozhi:deepl',
        ]);
        pending.complete({'libre': 'Libre'});
        await pumpEventQueue();

        expect(changes, isEmpty);
        expect(ids(await repository.getEngines()), ['mozhi:deepl']);
        expect(storedData(engineKey(instanceA)), [
          {'id': 'deepl', 'name': 'DeepL'},
        ]);
      });
    });

    group('instances', () {
      test('another instance does not get the stored list', () async {
        storeEngines(instanceA, {'google': 'Google'});
        configure(repository, instances: const [instanceC]);
        stubOffline(c());

        await expectLater(
          repository.getEngines(),
          throwsA(isA<MozhiApiException>()),
        );
        verifyNever(a().getEngines);
      });

      test('a changed instance list drops the served lists', () async {
        storeEngines(instanceA, {'google': 'Google'});
        storeEngines(instanceC, {'deepl': 'DeepL'});
        final pending = Completer<Map<String, String>>();
        when(a().getEngines).thenAnswer((_) => pending.future);
        stubOffline(c());
        expect(ids(await repository.getEngines()), ['mozhi:google']);

        configure(repository, instances: const [instanceC]);
        final engines = await repository.getEngines();
        pending.complete({'libre': 'Libre'});
        await pumpEventQueue();

        expect(ids(engines), ['mozhi:deepl']);
        expect(engines.single.subtitle, instanceC.displayName);
        expect(changes, isEmpty);
        expect(ids(await repository.getEngines()), ['mozhi:deepl']);
      });

      test('a new label is used for stored engines', () async {
        storeEngines(instanceA, {'google': 'Google'});
        stubOffline(a());
        stubOffline(b());
        const renamed = MozhiInstance(url: 'https://a.example', label: 'Mine');
        configure(repository, instances: const [renamed, instanceB]);

        final engines = await repository.getEngines();

        expect(engines.single.subtitle, 'Mine');
      });

      test('falls back to another configured instance', () async {
        storeEngines(instanceB, {'deepl': 'DeepL'});
        stubOffline(a());
        stubOffline(b());

        final engines = await repository.getEngines();

        expect(ids(engines), ['mozhi:deepl']);
        expect(engines.single.subtitle, instanceB.displayName);
      });

      test('a list from another instance is announced', () async {
        storeEngines(instanceB, {'deepl': 'DeepL'});
        stubEngines(a(), {'deepl': 'DeepL'});

        await repository.getEngines();
        await pumpEventQueue();

        expect(changes, hasLength(1));
        final engines = await repository.getEngines();
        expect(engines.single.subtitle, instanceA.displayName);
        expect(store.values.keys, contains(engineKey(instanceA)));
      });

      test('stores the list under the instance that answered', () async {
        stubOffline(a());
        stubEngines(b(), {'deepl': 'DeepL'});

        await repository.getEngines();
        await pumpEventQueue();

        expect(store.values.keys, [engineKey(instanceB)]);
        expect(repository.activeInstance, instanceB);

        relaunch();
        stubOffline(a());
        stubOffline(b());
        expect(ids(await repository.getEngines()), ['mozhi:deepl']);
      });

      test('revalidation by a failover instance moves the entry', () async {
        storeEngines(instanceA, {'google': 'Google'});
        stubOffline(a());
        stubEngines(b(), {'google': 'Google'});

        await repository.getEngines();
        await pumpEventQueue();

        expect(changes, hasLength(1), reason: 'the subtitle changed');
        expect(repository.activeInstance, instanceB);
        final engines = await repository.getEngines();
        expect(engines.single.subtitle, instanceB.displayName);
        verify(b().getEngines).called(1);
      });
    });
  });

  group('languages', () {
    test('are stored per instance, engine and direction', () async {
      when(() => a().getSourceLanguages('google')).thenAnswer(
        (_) async => const [
          MozhiLanguage(id: 'auto', name: 'Detect'),
          MozhiLanguage(id: 'de', name: 'German'),
        ],
      );
      when(() => a().getTargetLanguages('deepl')).thenAnswer(
        (_) async => const [
          MozhiLanguage(id: 'en-us', name: 'English (US)'),
          MozhiLanguage(id: 'zh-hant', name: 'Chinese (Traditional)'),
        ],
      );

      await repository.getSourceLanguages(googleEngine);
      final targets = await repository.getTargetLanguages(deeplEngine);
      await pumpEventQueue();

      expect(storedData(languagesKey(instanceA, 'google', 'source')), [
        Language.auto.toJson(),
        {
          'code': 'de',
          'name': 'German',
          'nativeName': LanguageCatalog.byCode('de')?.nativeName,
        },
      ]);
      expect(storedData(languagesKey(instanceA, 'deepl', 'target')), [
        for (final language in targets) language.toJson(),
      ]);
    });

    test('next launch serves the stored lists', () async {
      storeRaw(
        languagesKey(instanceA, 'google', 'source'),
        data: [
          Language.auto.toJson(),
          {'code': 'de', 'name': 'German', 'nativeName': 'Deutsch'},
          {'code': 'Pirate', 'name': 'Pirate', 'isCustom': true},
        ],
      );
      storeRaw(
        languagesKey(instanceA, 'google', 'target'),
        data: [english.toJson()],
      );
      stubOffline(a());
      stubOffline(b());

      final sources = await repository.getSourceLanguages(googleEngine);
      final targets = await repository.getTargetLanguages(googleEngine);

      expect(sources, [Language.auto, german, const Language.custom('Pirate')]);
      expect(identical(sources.first, Language.auto), isTrue);
      expect(sources[1].nativeName, 'Deutsch');
      expect(targets, [english]);
      expect(targets.single.name, 'English');
      expect(targets.single.nativeName, isNull);
    });

    test('a changed list is announced and then served', () async {
      storeRaw(
        languagesKey(instanceA, 'google', 'target'),
        data: [english.toJson()],
      );
      when(() => a().getTargetLanguages('google')).thenAnswer(
        (_) async => const [
          MozhiLanguage(id: 'en', name: 'English'),
          MozhiLanguage(id: 'de', name: 'German'),
        ],
      );

      expect(await repository.getTargetLanguages(googleEngine), [english]);
      await pumpEventQueue();

      expect(changes, hasLength(1));
      expect(await repository.getTargetLanguages(googleEngine), [
        english,
        german,
      ]);
      verify(() => a().getTargetLanguages('google')).called(1);
    });

    test('corrupt language data is ignored', () async {
      storeRaw(
        languagesKey(instanceA, 'google', 'target'),
        data: [
          {'code': 'en', 'name': 'English', 'isCustom': 'no'},
        ],
      );
      storeRaw(
        languagesKey(instanceA, 'google', 'source'),
        data: {'code': 'en'},
      );
      stubOffline(a());
      stubOffline(b());

      await expectLater(
        repository.getTargetLanguages(googleEngine),
        throwsA(isA<MozhiApiException>()),
      );
      await expectLater(
        repository.getSourceLanguages(googleEngine),
        throwsA(isA<MozhiApiException>()),
      );
    });

    test('a non-string native name is corrupt', () async {
      storeRaw(
        languagesKey(instanceA, 'google', 'target'),
        data: [
          {'code': 'de', 'name': 'German', 'nativeName': 3},
        ],
      );
      when(() => a().getTargetLanguages('google'))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'en', name: 'En')]);

      expect(await repository.getTargetLanguages(googleEngine), [english]);
    });
  });

  group('store failures', () {
    test('behave like an empty store', () async {
      final failing = _MockMetadataStore();
      when(() => failing.read(any())).thenThrow(StateError('read'));
      when(() => failing.write(any(), any())).thenThrow(StateError('write'));
      repository.dispose();
      repository = newRepository(metadataStore: failing);
      configure(repository);
      stubEngines(a(), {'google': 'Google'});

      expect(ids(await repository.getEngines()), ['mozhi:google']);
      await pumpEventQueue();
      verify(() => failing.write(engineKey(instanceA), any())).called(1);
    });
  });

  group('without a store', () {
    test('nothing is persisted and nothing is announced', () async {
      repository.dispose();
      repository = TranslationRepository(
        mozhiClientFactory: (uri) => mozhi[uri.toString()]!,
      );
      repository.metadataChanged.listen(changes.add);
      configure(repository);
      stubEngines(a(), {'google': 'Google'});

      expect(ids(await repository.getEngines()), ['mozhi:google']);
      stubOffline(a());
      stubOffline(b());
      await expectLater(
        repository.getEngines(refresh: true),
        throwsA(isA<MozhiApiException>()),
      );
      expect(changes, isEmpty);
    });
  });

  test('dispose closes metadataChanged', () async {
    final done = expectLater(repository.metadataChanged, emitsDone);
    repository.dispose();
    await done;
  });

  test('a revalidation finishing after dispose is dropped', () async {
    storeEngines(instanceA, {'google': 'Google'});
    final pending = Completer<Map<String, String>>();
    when(a().getEngines).thenAnswer((_) => pending.future);
    await repository.getEngines();

    repository.dispose();
    pending.complete({'deepl': 'DeepL'});
    await pumpEventQueue();

    expect(changes, isEmpty);
    expect(storedData(engineKey(instanceA)), [
      {'id': 'google', 'name': 'Google'},
    ]);
  });
}
