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
  String baseUrl = 'https://api.example.com/v1',
  LlmProvider provider = LlmProvider.openAiCompatible,
  MtService service = MtService.llm,
}) => AiProviderConfig(
  id: id,
  name: 'Provider $id',
  provider: provider,
  baseUrl: baseUrl,
  model: 'model-$id',
  apiKey: apiKey,
  headers: headers,
  service: service,
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

      test("never gives this device's key or headers to a provider of the "
          'same id on another server', () async {
        // A crafted backup: the id of this device's provider (ids show in
        // history exports), another server, no key.
        await section.restore(
          throughJson({
            'settings': {
              'providers': [
                {
                  'id': 'a',
                  'name': 'Provider a',
                  'provider': 'openAiCompatible',
                  'baseUrl': 'https://evil.example/v1',
                  'model': 'gpt',
                },
              ],
            },
          }),
          version: 1,
          mode: BackupRestoreMode.replace,
        );

        final provider = (await repository.load()).providers.single;
        expect(provider.baseUrl, 'https://evil.example/v1');
        expect(provider.apiKey, isNull);
        expect(provider.headers, isEmpty);
        expect(secrets.values.values, isNot(contains('key-a')));
      });

      test('keeps the key only for the same service, provider type and '
          'server', () async {
        await repository.save(
          mine.copyWith(
            providers: [
              _provider('same', apiKey: 'k1'),
              _provider('type', apiKey: 'k2'),
              _provider('service', apiKey: 'k3'),
              _provider('local', apiKey: 'k4', baseUrl: 'localhost:11434'),
            ],
          ),
        );

        await section.restore(
          throughJson({
            'settings': AppSettings(
              providers: [
                _provider('same', baseUrl: 'HTTPS://api.example.com:443/v1//'),
                _provider('type', provider: LlmProvider.anthropic),
                _provider('service', service: MtService.deepl),
                _provider('local', baseUrl: 'http://localhost:11434/'),
              ],
            ).toJson(),
          }),
          version: 1,
          mode: BackupRestoreMode.replace,
        );

        expect(
          (await repository.load()).providers.map((p) => (p.id, p.apiKey)),
          [('same', 'k1'), ('type', null), ('service', null), ('local', 'k4')],
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
      test("keeps this device's settings and adds the providers and pinned "
          'languages only in the backup', () async {
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
        // b is not in the backup's providers: its key there could be for
        // any server, so it stays without one.
        expect(merged.providers.map((p) => (p.id, p.apiKey)), [
          ('a', 'key-a'),
          ('b', null),
          ('c', 'key-c'),
        ]);
        expect(merged.instances.map((i) => i.url), [
          'https://user:pw@mozhi.example.com',
        ]);
        expect(merged.instances.first.label, 'Mine');
        expect(merged.pinnedLanguages, [_german, _japanese]);
      });

      test('never adds Mozhi instances: the failover would send text to '
          'them without asking', () async {
        // What a crafted backup (or a phone sending one) would carry.
        final data = {
          'settings': {
            'instances': [
              {'url': 'https://evil.example', 'label': 'Mirror'},
            ],
          },
        };
        final registry = BackupRegistry(appVersion: () async => '1')
          ..register(section);

        await registry.restore(
          BackupSnapshot(
            createdAt: DateTime.utc(2026, 10, 22),
            appVersion: '1',
            sections: {'settings': BackupSectionData(version: 1, data: data)},
          ),
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.instances.map((i) => i.url), [
          'https://user:pw@mozhi.example.com',
        ]);
      });

      test('a backup without instances adds no public ones either', () async {
        await repository.save(mine.copyWith(instances: const []));

        await section.restore(
          throughJson({'settings': <String, Object?>{}}),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        expect((await repository.load()).instances, isEmpty);
      });

      test("fills in the passwords of this device's instances by "
          'address', () async {
        await repository.save(
          mine.copyWith(
            instances: const [MozhiInstance(url: 'https://other.example.org')],
          ),
        );

        await section.restore(
          throughJson(
            backup(
              secrets: {
                'instanceCredentials': {
                  'https://other.example.org': 'me:secret',
                  'https://evil.example': 'x:y',
                },
              },
            ),
          ),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        expect((await repository.load()).instances.map((i) => i.url), [
          'https://me:secret@other.example.org',
        ]);
      });

      test("fills in keys and headers of this device's providers only from "
          'the same provider on the same server', () async {
        await repository.save(
          mine.copyWith(
            providers: [
              _provider('same', baseUrl: 'https://API.example.com/v1/'),
              _provider('moved'),
              _provider('type', provider: LlmProvider.anthropic),
              _provider('service', service: MtService.libreTranslate),
              _provider('absent'),
            ],
          ),
        );
        final keys = {
          for (final id in ['same', 'moved', 'type', 'service', 'absent'])
            id: 'theirs-$id',
        };

        await section.restore(
          throughJson({
            'settings': AppSettings(
              providers: [
                _provider('same', baseUrl: 'api.example.com/v1'),
                _provider('moved', baseUrl: 'https://evil.example/v1'),
                _provider('type'),
                _provider('service', service: MtService.deepl),
              ],
            ).toJson(),
            'secrets': {
              'apiKeys': keys,
              'headers': {
                for (final id in keys.keys)
                  id: {'Authorization': 'Bearer theirs'},
              },
            },
          }),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.providers.map((p) => (p.id, p.apiKey)), [
          ('same', 'theirs-same'),
          ('moved', null),
          ('type', null),
          ('service', null),
          ('absent', null),
        ]);
        expect(merged.providers.map((p) => p.headers).toList(), [
          {'Authorization': 'Bearer theirs'},
          isEmpty,
          isEmpty,
          isEmpty,
          isEmpty,
        ]);
      });

      test('a provider it adds is only used once chosen: consents and engine '
          'choices left behind for its id are dropped', () async {
        await repository.save(
          mine.copyWith(
            engineId: () => 'ai:c',
            assistEngineId: () => 'ai:c',
            fastEngineId: () => 'mt:c',
            bestEngineId: () => 'ai:a',
            compareEngineIds: const ['ai:c', 'ai:a', 'mozhi:google'],
            consentedProviders: const ['c', 'a'],
          ),
        );

        await section.restore(
          throughJson(backup()),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.providers.map((p) => p.id), ['a', 'b', 'c']);
        expect(merged.engineId, isNull);
        expect(merged.assistEngineId, isNull);
        expect(merged.fastEngineId, isNull);
        expect(merged.bestEngineId, 'ai:a');
        expect(merged.compareEngineIds, ['ai:a', 'mozhi:google']);
        expect(merged.consentedProviders, ['a']);
      });

      test('adds a provider the backup repeats once', () async {
        await section.restore(
          throughJson({
            'settings': AppSettings(
              providers: [
                _provider('c'),
                _provider('c', baseUrl: 'https://evil.example/v1'),
              ],
            ).toJson(),
          }),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        final merged = await repository.load();
        expect(merged.providers.map((p) => (p.id, p.baseUrl)), [
          ('a', 'https://api.example.com/v1'),
          ('b', 'https://api.example.com/v1'),
          ('c', 'https://api.example.com/v1'),
        ]);
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

  group('additions', () {
    final data = {
      'settings': AppSettings(
        providers: [
          _provider('a'),
          _provider('b', baseUrl: 'https://evil.example/v1'),
          _provider('c', baseUrl: 'http://ollama.lan:11434'),
        ],
        instances: const [
          MozhiInstance(url: 'https://mozhi.example.com'),
          MozhiInstance(url: 'https://new.example.org', label: 'Fast'),
          MozhiInstance(url: 'https://new.example.org'),
        ],
      ).toJson(),
      'secrets': {
        'apiKeys': {'c': 'key-c'},
        'instanceCredentials': {'https://new.example.org': 'me:pw'},
      },
    };

    test('lists the providers and instances each mode adds, without '
        'secrets, and changes nothing', () async {
      final additions = await section.additions(throughJson(data), version: 1);

      final merge = additions[BackupRestoreMode.merge]!;
      expect(merge.providers.map((p) => p.id), ['c']);
      expect(merge.instances, isEmpty);
      final replace = additions[BackupRestoreMode.replace]!;
      // b moves to another server.
      expect(replace.providers.map((p) => p.id), ['b', 'c']);
      expect(replace.instances.map((i) => (i.url, i.label)), [
        ('https://new.example.org', 'Fast'),
      ]);
      for (final provider in [...merge.providers, ...replace.providers]) {
        expect(provider.apiKey, isNull);
        expect(provider.headers, isEmpty);
      }
      expect(replace.providers.map(SettingsBackupAdditions.hostOf), [
        'evil.example',
        'ollama.lan',
      ]);
      expect(replace.instances.map(SettingsBackupAdditions.instanceHostOf), [
        'new.example.org',
      ]);
      expect(merge.isEmpty, isFalse);
      expect(await repository.load(), mine);
    });

    test('match what a restore then adds', () async {
      for (final mode in BackupRestoreMode.values) {
        await repository.save(mine);
        final additions = await section.additions(
          throughJson(data),
          version: 1,
        );
        await section.restore(throughJson(data), version: 1, mode: mode);

        expect(
          SettingsBackupAdditions.between(mine, await repository.load()),
          additions[mode],
          reason: mode.name,
        );
      }
    });

    test('nothing for a backup of these settings', () async {
      final additions = await section.additions(
        throughJson(await section.export(includeSecrets: true)),
        version: 1,
      );

      expect(additions.values.every((a) => a.isEmpty), isTrue);
    });

    test('refuses what restore refuses', () async {
      await expectLater(
        section.additions(data, version: 2),
        throwsFormatException,
      );
      await expectLater(
        section.additions({'settings': 1}, version: 1),
        throwsFormatException,
      );
    });

    test('hosts of providers without one and odd addresses', () {
      expect(SettingsBackupAdditions.hostOf(_provider('d', baseUrl: '')), '');
      expect(
        SettingsBackupAdditions.hostOf(_provider('d', baseUrl: 'Example.ORG')),
        'example.org',
      );
      expect(
        SettingsBackupAdditions.instanceHostOf(
          const MozhiInstance(url: 'not a url'),
        ),
        'not a url',
      );
    });
  });

  group('sameServer', () {
    test('compares service, provider type and normalised base URL', () {
      final a = _provider('a');
      expect(SettingsBackupSection.sameServer(a, _provider('x')), isTrue);
      for (final other in [
        _provider('a', baseUrl: 'https://api.example.com/v2'),
        _provider('a', baseUrl: 'http://api.example.com/v1'),
        _provider('a', baseUrl: 'https://api.example.com:8443/v1'),
        _provider('a', baseUrl: 'https://api.example.com/v1?key=1'),
        _provider('a', provider: LlmProvider.ollama),
        _provider('a', service: MtService.deepl),
      ]) {
        expect(
          SettingsBackupSection.sameServer(a, other),
          isFalse,
          reason: '$other',
        );
      }
    });

    test('normalises base URLs like the clients', () {
      for (final (url, normalized) in [
        ('', ''),
        ('  /// ', ''),
        ('https://api.example.com/v1', 'https://api.example.com/v1'),
        (' HTTPS://API.Example.com:443/v1/ ', 'https://api.example.com/v1'),
        ('api.example.com/v1', 'https://api.example.com/v1'),
        ('localhost:11434', 'http://localhost:11434'),
        ('192.168.1.5:1234/v1/', 'http://192.168.1.5:1234/v1'),
        ('http://host.example:80', 'http://host.example'),
        (
          'https://h.example/openai?api-version=1',
          'https://h.example/openai?api-version=1',
        ),
        ('https://h.example/v1#frag', 'https://h.example/v1'),
        // Not a valid address: compared as written.
        ('host.example:port', 'https://host.example:port'),
      ]) {
        expect(
          SettingsBackupSection.normalizedBaseUrl(url),
          normalized,
          reason: url,
        );
      }
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
