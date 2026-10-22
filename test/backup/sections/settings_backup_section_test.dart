import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

AiProviderConfig _provider(
  String id, {
  String? apiKey,
  Map<String, String> headers = const {},
}) => AiProviderConfig(
  id: id,
  name: 'Provider $id',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://api.example.com/v1',
  model: 'model-$id',
  apiKey: apiKey,
  headers: headers,
);

const _german = Language(code: 'de', name: 'German');
const _japanese = Language(code: 'ja', name: 'Japanese');

/// A store whose reads fail.
class _BrokenStore extends MemoryStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('broken'));
}

void main() {
  late MemoryStore prefs;
  late MemoryStore secrets;
  late SettingsRepository repository;
  late SettingsBackupSection section;

  final mine = AppSettings(
    onboardingComplete: true,
    themeMode: ThemeMode.dark,
    privacyMode: PrivacyMode.offlineOnly,
    providers: [
      _provider('a', apiKey: 'key-a', headers: const {'X-Org': 'org'}),
      _provider('b'),
    ],
    instances: const [
      MozhiInstance(url: 'https://user:pw@mozhi.example.com', label: 'Mine'),
    ],
    pinnedLanguages: const [_german],
  );

  setUp(() async {
    prefs = MemoryStore();
    secrets = MemoryStore();
    repository = SettingsRepository(prefs: prefs, secrets: secrets);
    section = SettingsBackupSection(repository);
    await repository.save(mine);
  });

  /// [data] through JSON, as a backup file carries it.
  Object? throughJson(Object? data) => jsonDecode(jsonEncode(data));

  test('has the id and version of the contract', () {
    expect(section.id, 'settings');
    expect(section.version, 1);
  });

  group('export', () {
    test('without secrets has none', () async {
      final data = await section.export(includeSecrets: false);
      final text = jsonEncode(data);

      expect(data, {'settings': mine.toJson()});
      expect(text, isNot(contains('key-a')));
      expect(text, isNot(contains('pw@')));
      expect(text, isNot(contains('X-Org')));
      expect(SettingsBackupSection.hasSecrets(data), isFalse);
    });

    test('with secrets has the keys, headers and instance '
        'credentials', () async {
      final data = (await section.export(includeSecrets: true))! as Map;

      expect(data['secrets'], {
        'apiKeys': {'a': 'key-a'},
        'headers': {
          'a': {'X-Org': 'org'},
        },
        'instanceCredentials': {'https://mozhi.example.com': 'user:pw'},
      });
      expect(SettingsBackupSection.hasSecrets(data), isTrue);
    });

    test('with secrets but none stored has no secrets entry', () async {
      await repository.save(const AppSettings(onboardingComplete: true));

      final data = (await section.export(includeSecrets: true))! as Map;

      expect(data, isNot(contains('secrets')));
    });

    test('refuses settings that could not be read', () async {
      final broken = SettingsBackupSection(
        SettingsRepository(prefs: _BrokenStore(), secrets: MemoryStore()),
      );

      await expectLater(
        broken.export(includeSecrets: false),
        throwsA(isA<SettingsUnavailableException>()),
      );
    });
  });

  group('restore', () {
    final theirs = AppSettings(
      onboardingComplete: true,
      themeMode: ThemeMode.light,
      privacyMode: PrivacyMode.online,
      providers: [_provider('a'), _provider('c')],
      instances: const [
        MozhiInstance(url: 'https://mozhi.example.com', label: 'Theirs'),
        MozhiInstance(url: 'https://other.example.org'),
      ],
      pinnedLanguages: const [_japanese, _german],
    );

    Map<String, Object?> backup({Map<String, Object?>? secrets}) => {
      'settings': theirs.toJson(),
      'secrets': ?secrets,
    };

    group('replace', () {
      test("makes the backup the settings, keeping this device's keys "
          'where the backup has none', () async {
        await section.restore(
          throughJson(backup()),
          version: 1,
          mode: BackupRestoreMode.replace,
        );

        final restored = await repository.load();
        expect(restored.themeMode, ThemeMode.light);
        expect(restored.privacyMode, PrivacyMode.online);
        expect(restored.pinnedLanguages, [_japanese, _german]);
        expect(restored.providers.map((p) => (p.id, p.apiKey)), [
          ('a', 'key-a'),
          ('c', null),
        ]);
        expect(restored.providers.first.headers, {'X-Org': 'org'});
        expect(restored.instances.map((i) => (i.url, i.label)), [
          ('https://user:pw@mozhi.example.com', 'Theirs'),
          ('https://other.example.org', null),
        ]);
        // Provider b is gone, and its key with it.
        expect(secrets.values.keys, isNot(contains('apikey.b')));
      });

      test("writes the backup's secrets to secure storage, never to the "
          'plain settings', () async {
        await section.restore(
          throughJson(
            backup(
              secrets: {
                'apiKeys': {'a': 'new-a', 'c': 'key-c'},
                'headers': {
                  'c': {'X-C': 'c'},
                  'broken': 1,
                },
                'instanceCredentials': {
                  'https://other.example.org': 'me:secret',
                },
              },
            ),
          ),
          version: 1,
          mode: BackupRestoreMode.replace,
        );

        expect(secrets.values['apikey.a'], 'new-a');
        expect(secrets.values['apikey.c'], 'key-c');
        expect(jsonDecode(secrets.values['apiheaders.c']!), {'X-C': 'c'});
        expect(
          jsonDecode(secrets.values['instancecreds']!),
          containsPair('https://other.example.org', 'me:secret'),
        );
        final plain = prefs.values[SettingsRepository.settingsKey]!;
        expect(plain, isNot(contains('key-c')));
        expect(plain, isNot(contains('secret')));
        final restored = await repository.load();
        expect(restored.providers.last.apiKey, 'key-c');
        expect(
          restored.instances.last.url,
          'https://me:secret@other.example.org',
        );
      });

      test('keeps setup finished', () async {
        await section.restore(
          throughJson({'settings': const AppSettings().toJson()}),
          version: 1,
          mode: BackupRestoreMode.replace,
        );

        expect((await repository.load()).onboardingComplete, isTrue);
      });
    });

    group('merge', () {
      test("keeps this device's settings and adds what is only in the "
          'backup', () async {
        await section.restore(
          throughJson(
            backup(
              secrets: {
                'apiKeys': {'a': 'theirs-a', 'b': 'key-b', 'c': 'key-c'},
              },
            ),
          ),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.themeMode, ThemeMode.dark);
        expect(merged.privacyMode, PrivacyMode.offlineOnly);
        expect(merged.providers.map((p) => (p.id, p.apiKey)), [
          ('a', 'key-a'),
          ('b', 'key-b'),
          ('c', 'key-c'),
        ]);
        expect(merged.instances.map((i) => i.url), [
          'https://user:pw@mozhi.example.com',
          'https://other.example.org',
        ]);
        expect(merged.instances.first.label, 'Mine');
        expect(merged.pinnedLanguages, [_german, _japanese]);
      });

      test('a provider only in the backup comes without secrets unless '
          'the backup has them', () async {
        await section.restore(
          throughJson(backup()),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.providers.last.id, 'c');
        expect(merged.providers.last.apiKey, isNull);
        expect(merged.providers.last.headers, isEmpty);
      });
    });

    test('refuses a newer version and invalid data', () async {
      await expectLater(
        section.restore(backup(), version: 2, mode: BackupRestoreMode.merge),
        throwsFormatException,
      );
      for (final data in [
        null,
        'settings',
        {'settings': 1},
      ]) {
        await expectLater(
          section.restore(data, version: 1, mode: BackupRestoreMode.merge),
          throwsFormatException,
          reason: '$data',
        );
      }
      expect(await repository.load(), mine);
    });

    test('ignores invalid secrets', () async {
      await section.restore(
        throughJson({...backup(), 'secrets': 'nope'}),
        version: 1,
        mode: BackupRestoreMode.replace,
      );

      expect((await repository.load()).providers.last.apiKey, isNull);
    });
  });

  group('hasSecrets', () {
    test('only for a non-empty secrets map', () {
      expect(SettingsBackupSection.hasSecrets(null), isFalse);
      expect(
        SettingsBackupSection.hasSecrets({'secrets': <String, Object?>{}}),
        isFalse,
      );
      expect(SettingsBackupSection.hasSecrets({'secrets': 'x'}), isFalse);
      expect(
        SettingsBackupSection.hasSecrets({
          'secrets': {'apiKeys': <String, String>{}},
        }),
        isTrue,
      );
    });
  });
}
