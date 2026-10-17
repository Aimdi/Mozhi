import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

AiProviderConfig _provider(String id, {String? apiKey}) => AiProviderConfig(
  id: id,
  name: 'Provider $id',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://api.example.com/v1',
  model: 'model-$id',
  apiKey: apiKey,
);

/// A store whose every operation fails.
class _FailingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('read'));

  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('write'));

  @override
  Future<void> delete(String key) => Future.error(StateError('delete'));
}

/// A [MemoryStore] whose next [failingReads] reads fail, and that counts
/// its writes.
class _FlakyStore extends MemoryStore {
  new([super.initial]);

  int failingReads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) {
    if (failingReads > 0) {
      failingReads--;
      return Future.error(StateError('read'));
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    writes++;
    return super.write(key, value);
  }
}

/// A [MemoryStore] whose writes wait for [gate], can fail once and record
/// the order in which they complete.
class _GatedStore extends MemoryStore {
  Completer<void> gate = Completer<void>()..complete();
  bool failNextWrite = false;
  final List<String> writes = [];

  @override
  Future<void> write(String key, String value) async {
    await gate.future;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('write');
    }
    writes.add(value);
    await super.write(key, value);
  }
}

void main() {
  group(SettingsRepository, () {
    late MemoryStore prefs;
    late MemoryStore secrets;
    late SettingsRepository repository;

    setUp(() {
      prefs = MemoryStore();
      secrets = MemoryStore();
      repository = SettingsRepository(prefs: prefs, secrets: secrets);
    });

    test('defaults to the platform stores', () {
      final repository = SettingsRepository();

      expect(repository.prefs, isA<PreferencesStore>());
      expect(repository.secrets, isA<SecureStore>());
    });

    test('apiKeyKey namespaces provider ids', () {
      expect(SettingsRepository.apiKeyKey('abc'), 'apikey.abc');
    });

    group('load', () {
      test('returns defaults when nothing is stored', () async {
        expect(await repository.load(), equals(const AppSettings()));
      });

      test('returns defaults for corrupt JSON', () async {
        prefs.values[SettingsRepository.settingsKey] = '{not json';

        expect(await repository.load(), equals(const AppSettings()));
      });

      test('returns defaults when the JSON is not an object', () async {
        prefs.values[SettingsRepository.settingsKey] = '[1, 2]';

        expect(await repository.load(), equals(const AppSettings()));
      });

      test('returns defaults when the preferences fail', () async {
        final repository = SettingsRepository(
          prefs: _FailingStore(),
          secrets: secrets,
        );

        expect(await repository.load(), equals(const AppSettings()));
        expect(repository.loadFailed, isTrue);
      });

      test('does not report a failure for missing or corrupt JSON', () async {
        expect(repository.loadFailed, isFalse);
        await repository.load();
        expect(repository.loadFailed, isFalse);

        prefs.values[SettingsRepository.settingsKey] = '{not json';
        await repository.load();
        expect(repository.loadFailed, isFalse);
      });

      test('reads the stored settings', () async {
        const settings = AppSettings(
          themeMode: ThemeMode.light,
          engineId: 'mozhi:deepl',
        );
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          settings.toJson(),
        );

        expect(await repository.load(), equals(settings));
      });

      test(
        'marks onboarding done for settings saved before it existed',
        () async {
          final json = const AppSettings(engineId: 'mozhi:deepl').toJson()
            ..remove('onboardingComplete');
          prefs.values[SettingsRepository.settingsKey] = jsonEncode(json);

          final loaded = await repository.load();
          expect(loaded.onboardingComplete, isTrue);
          expect(loaded.engineId, 'mozhi:deepl');
        },
      );

      test(
        'keeps settings saved before privacy modes existed online',
        () async {
          final json = const AppSettings(engineId: 'mozhi:deepl').toJson()
            ..remove('privacyMode');
          prefs.values[SettingsRepository.settingsKey] = jsonEncode(json);

          final loaded = await repository.load();
          expect(loaded.privacyMode, PrivacyMode.online);
          expect(loaded.engineId, 'mozhi:deepl');
        },
      );

      test('reads a stored privacy mode as is', () async {
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          const AppSettings(privacyMode: PrivacyMode.offlineOnly).toJson(),
        );

        expect((await repository.load()).privacyMode, PrivacyMode.offlineOnly);
      });

      test('injects API keys from the secret store', () async {
        final settings = AppSettings(
          providers: [_provider('a'), _provider('b'), _provider('c')],
        );
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          settings.toJson(),
        );
        secrets.values
          ..['apikey.a'] = 'key-a'
          ..['apikey.c'] = '';

        final loaded = await repository.load();

        expect(loaded.providers, [
          _provider('a', apiKey: 'key-a'),
          _provider('b'),
          _provider('c'),
        ]);
      });

      test('loads providers without keys when secrets fail', () async {
        final repository = SettingsRepository(
          prefs: prefs,
          secrets: _FailingStore(),
        );
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          AppSettings(providers: [_provider('a')]).toJson(),
        );

        final loaded = await repository.load();

        expect(loaded.providers, [_provider('a')]);
      });
    });

    group('save', () {
      test('writes the settings JSON without API keys', () async {
        final settings = AppSettings(
          seedColor: 0xFF123456,
          providers: [_provider('a', apiKey: 'key-a')],
        );

        await repository.save(settings);

        final raw = prefs.values[SettingsRepository.settingsKey]!;
        expect(raw, isNot(contains('key-a')));
        expect(
          AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          equals(settings.copyWith(providers: [_provider('a')])),
        );
      });

      test('stores API keys and deletes cleared ones', () async {
        secrets.values['apikey.b'] = 'old-key';

        await repository.save(
          AppSettings(
            providers: [
              _provider('a', apiKey: 'key-a'),
              _provider('b'),
              _provider('c', apiKey: ''),
            ],
          ),
        );

        expect(secrets.values, {'apikey.a': 'key-a'});
      });

      test('round-trips with load', () async {
        final settings = AppSettings(
          providers: [
            _provider('a', apiKey: 'key-a'),
            _provider('b'),
          ],
          target: const Language(code: 'de', name: 'German'),
        );

        await repository.save(settings);
        final loaded = await SettingsRepository(
          prefs: prefs,
          secrets: secrets,
        ).load();

        expect(loaded, equals(settings));
      });

      test('deletes keys of providers that were removed', () async {
        await repository.save(
          AppSettings(
            providers: [
              _provider('a', apiKey: 'key-a'),
              _provider('b', apiKey: 'key-b'),
            ],
          ),
        );

        await repository.save(
          AppSettings(providers: [_provider('b', apiKey: 'key-b')]),
        );

        expect(secrets.values, {'apikey.b': 'key-b'});
      });

      test('finds orphan keys from previously stored settings', () async {
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          AppSettings(providers: [_provider('old')]).toJson(),
        );
        secrets.values['apikey.old'] = 'old-key';

        await repository.save(const AppSettings());

        expect(secrets.values, isEmpty);
      });

      test('finds orphan keys from a previous load when the stored JSON '
          'became unreadable', () async {
        prefs.values[SettingsRepository.settingsKey] = jsonEncode(
          AppSettings(providers: [_provider('old')]).toJson(),
        );
        secrets.values['apikey.old'] = 'old-key';
        await repository.load();
        prefs.values[SettingsRepository.settingsKey] = 'garbage';

        await repository.save(const AppSettings());

        expect(secrets.values, isEmpty);
      });

      group('after a failed load (regression)', () {
        late _FlakyStore prefs;
        late SettingsRepository repository;
        final stored = AppSettings(
          onboardingComplete: true,
          providers: [_provider('a')],
        );

        setUp(() {
          prefs = _FlakyStore({
            SettingsRepository.settingsKey: jsonEncode(stored.toJson()),
          })..failingReads = 1;
          secrets.values['apikey.a'] = 'key-a';
          repository = SettingsRepository(prefs: prefs, secrets: secrets);
        });

        test('does not overwrite settings it could not read, nor delete '
            'their API keys', () async {
          final loaded = await repository.load();
          expect(loaded, equals(const AppSettings()));
          expect(repository.loadFailed, isTrue);

          await expectLater(
            repository.save(const AppSettings(seedColor: 1)),
            throwsA(isA<SettingsUnavailableException>()),
          );

          expect(prefs.writes, 0);
          expect(
            prefs.values[SettingsRepository.settingsKey],
            jsonEncode(stored.toJson()),
          );
          expect(secrets.values, {'apikey.a': 'key-a'});
        });

        test('rethrows when the storage is still unreadable', () async {
          prefs.failingReads = 2;
          await repository.load();

          await expectLater(
            repository.save(const AppSettings(seedColor: 1)),
            throwsStateError,
          );

          expect(prefs.writes, 0);
          expect(secrets.values, {'apikey.a': 'key-a'});
        });

        test('keeps refusing until a load succeeds', () async {
          await repository.load();
          await expectLater(
            repository.save(const AppSettings(seedColor: 1)),
            throwsA(isA<SettingsUnavailableException>()),
          );

          final loaded = await repository.load();
          expect(repository.loadFailed, isFalse);
          expect(loaded.providers, [_provider('a', apiKey: 'key-a')]);
          await repository.save(loaded.copyWith(seedColor: 2));

          expect((await repository.load()).seedColor, 2);
          expect(secrets.values, {'apikey.a': 'key-a'});
        });

        test('saves when nothing turns out to be stored', () async {
          prefs.values.clear();
          await repository.load();
          expect(repository.loadFailed, isTrue);

          await repository.save(const AppSettings(seedColor: 1));

          expect(repository.loadFailed, isFalse);
          expect(prefs.writes, 1);
          expect(
            await SettingsRepository(prefs: prefs, secrets: secrets).load(),
            equals(const AppSettings(seedColor: 1)),
          );
        });
      });

      test('does not write when reading the previous settings fails '
          '(regression)', () async {
        final prefs = _FlakyStore({
          SettingsRepository.settingsKey: jsonEncode(
            AppSettings(providers: [_provider('a')]).toJson(),
          ),
        });
        secrets.values['apikey.a'] = 'key-a';
        final repository = SettingsRepository(prefs: prefs, secrets: secrets);
        prefs.failingReads = 1;

        await expectLater(
          repository.save(const AppSettings()),
          throwsStateError,
        );

        expect(prefs.writes, 0);
        expect(secrets.values, {'apikey.a': 'key-a'});
      });

      test('propagates storage errors', () async {
        final repository = SettingsRepository(
          prefs: _FailingStore(),
          secrets: secrets,
        );

        await expectLater(
          repository.save(const AppSettings()),
          throwsStateError,
        );
      });

      test('serialises concurrent saves so the last one wins', () async {
        final prefs = _GatedStore()..gate = Completer<void>();
        final repository = SettingsRepository(prefs: prefs, secrets: secrets);
        const first = AppSettings(seedColor: 1);
        const second = AppSettings(seedColor: 2);

        final saves = [repository.save(first), repository.save(second)];
        prefs.gate.complete();
        await Future.wait(saves);

        expect(prefs.writes, [
          jsonEncode(first.toJson()),
          jsonEncode(second.toJson()),
        ]);
        expect(await repository.load(), equals(second));
      });

      test('keeps saving after a failed save', () async {
        final prefs = _GatedStore()..failNextWrite = true;
        final repository = SettingsRepository(prefs: prefs, secrets: secrets);
        const next = AppSettings(seedColor: 2);

        final failed = repository.save(const AppSettings(seedColor: 1));
        final succeeded = repository.save(next);

        await expectLater(failed, throwsStateError);
        await succeeded;
        expect(await repository.load(), equals(next));
      });
    });
  });

  group(SettingsUnavailableException, () {
    test('has a readable toString', () {
      expect(
        const SettingsUnavailableException().toString(),
        startsWith('SettingsUnavailableException'),
      );
    });
  });
}
