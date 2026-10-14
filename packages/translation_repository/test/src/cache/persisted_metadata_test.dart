import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/cache/persisted_metadata.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockMetadataStore extends Mock implements MetadataStore {}

void main() {
  const url = 'https://a.example';
  late MemoryMetadataStore store;
  late DateTime now;
  late PersistedMetadata metadata;

  String keyOf(String name) => PersistedMetadata.keyFor(url, name);

  String envelope({
    Object? version = PersistedMetadata.version,
    Object? storedUrl = url,
    Object? name = 'engines',
    Object? savedAt,
    Object? data = const ['x'],
    bool withData = true,
  }) => jsonEncode({
    'v': version,
    'url': storedUrl,
    'name': name,
    'savedAt': savedAt ?? now.millisecondsSinceEpoch,
    if (withData) 'data': data,
  });

  setUp(() {
    store = MemoryMetadataStore();
    now = DateTime(2026, 10, 14, 12);
    metadata = PersistedMetadata(
      store,
      maxAge: const Duration(days: 7),
      clock: () => now,
    );
  });

  group('MemoryMetadataStore', () {
    test('copies the initial values and reads what was written', () async {
      final initial = {'a': '1'};
      final memory = MemoryMetadataStore(initial);
      initial['a'] = 'changed';
      expect(await memory.read('a'), '1');
      expect(await memory.read('b'), isNull);
      await memory.write('b', '2');
      expect(memory.values, {'a': '1', 'b': '2'});
    });
  });

  group('PersistedMetadata', () {
    test('keys by prefix, URL and name', () {
      expect(
        PersistedMetadata.keyFor(url, 'google|source'),
        'translation_repository.metadata.v1|https://a.example|google|source',
      );
    });

    test('round-trips timestamped JSON', () async {
      await metadata.write(url, 'engines', [
        {'id': 'google', 'name': 'Google'},
      ]);
      final raw = jsonDecode(store.values[keyOf('engines')]!);
      expect(raw, {
        'v': 1,
        'url': url,
        'name': 'engines',
        'savedAt': now.millisecondsSinceEpoch,
        'data': [
          {'id': 'google', 'name': 'Google'},
        ],
      });

      now = now.add(const Duration(days: 3));
      final stored = await metadata.read(url, 'engines');
      expect(stored, isNotNull);
      expect(stored!.url, url);
      expect(stored.data, [
        {'id': 'google', 'name': 'Google'},
      ]);
      expect(stored.encodedData, '[{"id":"google","name":"Google"}]');
      expect(stored.savedAt, DateTime(2026, 10, 14, 12));
    });

    test('returns null when nothing is stored', () async {
      expect(await metadata.read(url, 'engines'), isNull);
    });

    test('ignores entries as old as maxAge', () async {
      await metadata.write(url, 'engines', const ['x']);
      now = now.add(const Duration(days: 7) - const Duration(seconds: 1));
      expect(await metadata.read(url, 'engines'), isNotNull);
      now = now.add(const Duration(seconds: 1));
      expect(await metadata.read(url, 'engines'), isNull);
    });

    test('accepts null data', () async {
      await metadata.write(url, 'engines', null);
      final stored = await metadata.read(url, 'engines');
      expect(stored?.data, isNull);
      expect(stored?.encodedData, 'null');
    });

    group('ignores corrupt entries', () {
      final cases = <String, String Function()>{
        'invalid JSON': () => '{"v": 1, "url":',
        'not an object': () => '[1, 2]',
        'another version': () => envelope(version: 2),
        'another URL': () => envelope(storedUrl: 'https://b.example'),
        'another name': () => envelope(name: 'google|source'),
        'a non-integer timestamp': () => envelope(savedAt: 'yesterday'),
        'no data': () => envelope(withData: false),
      };
      for (final MapEntry(key: description, value: raw) in cases.entries) {
        test(description, () async {
          store.values[keyOf('engines')] = raw();
          expect(await metadata.read(url, 'engines'), isNull);
        });
      }
    });

    test('swallows store failures', () async {
      final failing = _MockMetadataStore();
      when(() => failing.read(any())).thenThrow(StateError('read'));
      when(() => failing.write(any(), any())).thenThrow(StateError('write'));
      final persisted = PersistedMetadata(
        failing,
        maxAge: const Duration(days: 7),
        clock: () => now,
      );
      expect(await persisted.read(url, 'engines'), isNull);
      await expectLater(persisted.write(url, 'engines', const []), completes);
    });

    test('swallows asynchronous store failures', () async {
      final failing = _MockMetadataStore();
      when(() => failing.read(any())).thenAnswer((_) async => throw 'read');
      when(() => failing.write(any(), any()))
          .thenAnswer((_) async => throw 'write');
      final persisted = PersistedMetadata(
        failing,
        maxAge: const Duration(days: 7),
        clock: () => now,
      );
      expect(await persisted.read(url, 'engines'), isNull);
      await expectLater(persisted.write(url, 'engines', const []), completes);
    });
  });
}
