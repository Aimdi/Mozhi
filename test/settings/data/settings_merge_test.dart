import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/provider_identity.dart';
import 'package:mozhi/settings/data/settings_rebase.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

AiProviderConfig _provider(
  String id, {
  String baseUrl = 'https://api.example.com/v1',
  String? apiKey,
  String model = 'model',
}) => AiProviderConfig(
  id: id,
  name: 'Provider $id',
  provider: LlmProvider.openAiCompatible,
  baseUrl: baseUrl,
  model: model,
  apiKey: apiKey,
);

const _german = Language(code: 'de', name: 'German');
const _french = Language(code: 'fr', name: 'French');

/// A store whose reads can be held back (each answered with what the
/// store held when it was asked).
class _SlowStore extends MemoryStore {
  final List<Completer<void>> held = [];
  bool slow = false;

  @override
  Future<String?> read(String key) async {
    final value = await super.read(key);
    if (!slow) return value;
    final gate = Completer<void>();
    held.add(gate);
    await gate.future;
    return value;
  }
}

/// A store whose writes of one key fail.
class _FailingKeyStore extends MemoryStore {
  new(this.failing);

  final String failing;

  @override
  Future<void> write(String key, String value) => key == failing
      ? Future.error(StateError('full'))
      : super.write(key, value);

  @override
  Future<String?> read(String key) =>
      key == failing ? Future.error(StateError('io')) : super.read(key);
}

void main() {
  group('rebaseSettings', () {
    const base = AppSettings(
      themeMode: ThemeMode.light,
      pinnedLanguages: [_german],
    );

    test('takes each setting the app changed from it, the others from the '
        'stored settings', () {
      final result = rebaseSettings(
        base: base,
        mine: base.copyWith(themeMode: ThemeMode.dark),
        theirs: base.copyWith(
          pinnedLanguages: const [_german, _french],
          hapticFeedback: false,
        ),
      );
      expect(result.themeMode, ThemeMode.dark);
      expect(result.pinnedLanguages, const [_german, _french]);
      expect(result.hapticFeedback, isFalse);
    });

    test('providers go by id, with their keys', () {
      final a = _provider('a', apiKey: 'key-a');
      final b = _provider('b');
      final c = _provider('c');
      final withBase = base.copyWith(providers: [a, b, c]);
      final result = rebaseSettings(
        base: withBase,
        // The app edits a, removes c and adds d.
        mine: withBase.copyWith(
          providers: [
            _provider('a', apiKey: 'key-a', model: 'other'),
            b,
            _provider('d'),
          ],
        ),
        // The merge filled b's key and added e.
        theirs: withBase.copyWith(
          providers: [
            a,
            _provider('b', apiKey: 'key-b'),
            c,
            _provider('e'),
          ],
        ),
      );
      expect(result.providers.map((p) => (p.id, p.model, p.apiKey)), [
        ('a', 'other', 'key-a'),
        ('b', 'model', 'key-b'),
        ('e', 'model', null),
        ('d', 'model', null),
      ]);
    });

    test("the app's order of providers when it reordered them", () {
      final a = _provider('a');
      final b = _provider('b');
      final withBase = base.copyWith(providers: [a, b]);
      final result = rebaseSettings(
        base: withBase,
        mine: withBase.copyWith(providers: [b, a]),
        theirs: withBase.copyWith(providers: [a, b, _provider('c')]),
      );
      expect(result.providers.map((p) => p.id), ['b', 'a', 'c']);
    });

    test('instances go by address, with their passwords', () {
      const mine = MozhiInstance(url: 'https://mozhi.example.com');
      final withBase = base.copyWith(instances: const [mine]);
      final result = rebaseSettings(
        base: withBase,
        mine: withBase,
        theirs: withBase.copyWith(
          instances: const [
            MozhiInstance(url: 'https://me:pw@mozhi.example.com'),
          ],
        ),
      );
      expect(result.instances.single.url, 'https://me:pw@mozhi.example.com');
    });
  });

  group('SettingsRepository', () {
    late MemoryStore prefs;
    late MemoryStore secrets;
    late SettingsRepository repository;

    setUp(() {
      prefs = MemoryStore();
      secrets = MemoryStore();
      repository = SettingsRepository(prefs: prefs, secrets: secrets);
    });

    group('update', () {
      test(
        'reads, changes and writes in one step, after earlier saves',
        () async {
          await repository.save(const AppSettings(pinnedLanguages: [_german]));
          final saving = repository.save(
            const AppSettings(
              pinnedLanguages: [_german],
              hapticFeedback: false,
            ),
          );
          final updated = await repository.update(
            (current) => current.copyWith(
              pinnedLanguages: [...current.pinnedLanguages, _french],
            ),
          );
          await saving;

          expect(updated.hapticFeedback, isFalse);
          final stored = await repository.read();
          expect(stored.pinnedLanguages, const [_german, _french]);
          expect(stored.hapticFeedback, isFalse);
        },
      );

      test('writes nothing when nothing changes', () async {
        await repository.save(const AppSettings());
        prefs.values.clear();
        await repository.update((current) => current);
        expect(prefs.values, isEmpty);
      });

      test('refuses settings it could not read', () async {
        final broken = SettingsRepository(
          prefs: _FailingKeyStore(SettingsRepository.settingsKey),
          secrets: MemoryStore(),
        );
        await expectLater(
          broken.update((current) => current),
          throwsA(isA<SettingsUnavailableException>()),
        );
      });

      test("a save from settings read before it applies the app's change "
          'to what it wrote, until the app loads again', () async {
        final loaded = await repository.load();
        await repository.update(
          (current) =>
              current.copyWith(providers: [_provider('merged', apiKey: 'k')]),
        );

        final first = loaded.copyWith(themeMode: ThemeMode.dark);
        await repository.save(first);
        await repository.save(first.copyWith(hapticFeedback: false));

        var stored = await repository.read();
        expect(stored.providers.map((p) => (p.id, p.apiKey)), [
          ('merged', 'k'),
        ]);
        expect(stored.themeMode, ThemeMode.dark);
        expect(stored.hapticFeedback, isFalse);
        expect(secrets.values[SettingsRepository.apiKeyKey('merged')], 'k');

        // Loaded again: the app's settings are written as they are.
        final fresh = await repository.load();
        await repository.save(fresh.copyWith(providers: const []));
        stored = await repository.read();
        expect(stored.providers, isEmpty);
      });

      test('a load that a save overtook leaves the rebase on', () async {
        final slow = _SlowStore();
        final slowRepository = SettingsRepository(
          prefs: slow,
          secrets: MemoryStore(),
        );
        final loaded = await slowRepository.load();
        await slowRepository.update(
          (current) => current.copyWith(pinnedLanguages: const [_french]),
        );
        slow.slow = true;
        final loading = slowRepository.load();
        while (slow.held.isEmpty) {
          await pumpEventQueue();
        }
        final saving = slowRepository.save(
          loaded.copyWith(themeMode: ThemeMode.dark),
        );
        slow.slow = false;
        for (final gate in [...slow.held]) {
          gate.complete();
        }
        await loading;
        await saving;

        final stored = await slowRepository.read();
        expect(stored.pinnedLanguages, const [_french]);
        expect(stored.themeMode, ThemeMode.dark);
      });
    });

    group('removedProviders', () {
      test('remembers a removed provider by id and server, without its '
          'address', () async {
        final a = _provider('a', baseUrl: 'https://user:pw@ai.example.org');
        await repository.save(AppSettings(providers: [a, _provider('b')]));
        expect(await repository.removedProviders(), isEmpty);

        await repository.save(AppSettings(providers: [_provider('b')]));

        expect(await repository.removedProviders(), [
          RemovedProvider(id: 'a', server: ProviderIdentity.serverHash(a)),
        ]);
        final raw = prefs.values[SettingsRepository.removedProvidersKey]!;
        expect(raw, isNot(contains('ai.example.org')));
        expect(raw, isNot(contains('pw')));
        // Read back by another repository over the same stores.
        expect(
          await SettingsRepository(
            prefs: prefs,
            secrets: secrets,
          ).removedProviders(),
          hasLength(1),
        );
      });

      test('forgets one that is back on the same server', () async {
        final a = _provider('a');
        await repository.save(AppSettings(providers: [a]));
        await repository.save(const AppSettings());
        expect(await repository.removedProviders(), hasLength(1));

        await repository.save(AppSettings(providers: [a]));
        expect(await repository.removedProviders(), isEmpty);
        expect(
          prefs.values,
          isNot(contains(SettingsRepository.removedProvidersKey)),
        );
      });

      test('keeps the latest ones only', () async {
        for (var i = 0; i < SettingsRepository.maxRemovedProviders + 2; i++) {
          await repository.save(AppSettings(providers: [_provider('p$i')]));
        }
        await repository.save(const AppSettings());
        final removed = await repository.removedProviders();
        expect(removed, hasLength(SettingsRepository.maxRemovedProviders));
        expect(
          removed.last.id,
          'p${SettingsRepository.maxRemovedProviders + 1}',
        );
      });

      test(
        'none when they cannot be read or are invalid; a save still works',
        () async {
          final failing = SettingsRepository(
            prefs: _FailingKeyStore(SettingsRepository.removedProvidersKey),
            secrets: MemoryStore(),
          );
          await failing.save(AppSettings(providers: [_provider('a')]));
          await failing.save(const AppSettings());
          expect(await failing.removedProviders(), isEmpty);

          prefs.values[SettingsRepository.removedProvidersKey] = jsonEncode([
            {'id': 'a', 'server': 'x'},
            {'id': ''},
            'nonsense',
          ]);
          expect(await repository.removedProviders(), const [
            RemovedProvider(id: 'a', server: 'x'),
          ]);
        },
      );
    });
  });

  test('ProviderIdentity tells servers apart, not ids', () {
    final a = _provider('a', baseUrl: 'https://API.example.com/v1/');
    final b = _provider('b', baseUrl: 'api.example.com/v1');
    final c = _provider('a', baseUrl: 'https://other.example.com/v1');
    expect(ProviderIdentity.sameServer(a, b), isTrue);
    expect(ProviderIdentity.serverHash(a), ProviderIdentity.serverHash(b));
    expect(
      ProviderIdentity.serverHash(a),
      isNot(ProviderIdentity.serverHash(c)),
    );
    expect(RemovedProvider.tryParse({'id': 'a'}), isNull);
    expect(const RemovedProvider(id: 'a', server: 'x').toJson(), {
      'id': 'a',
      'server': 'x',
    });
  });

  test('SettingsCubit reads again when a change overtook a load', () async {
    final slow = _SlowStore();
    final repository = SettingsRepository(prefs: slow, secrets: MemoryStore());
    final cubit = SettingsCubit(
      repository: repository,
      initial: await repository.load(),
    );
    addTearDown(cubit.close);
    slow.slow = true;
    final loading = cubit.load();
    while (slow.held.isEmpty) {
      await pumpEventQueue();
    }
    cubit.setHapticFeedback(enabled: false);
    slow.slow = false;
    for (final gate in [...slow.held]) {
      gate.complete();
    }
    await loading;
    await pumpEventQueue();

    expect(cubit.state.hapticFeedback, isFalse);
  });
}
