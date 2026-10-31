import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/app_backup_sections.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/sync/data/sync_engine.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_webdav_server.dart';
import '../helpers/memory_section.dart';

const _filePath = '/dav/Mozhi/${SyncConfig.fileName}';

/// Syncs everything, the settings too.
final SyncConfig _everything = SyncConfig(
  server: Uri.parse('https://cloud.example.org/dav/'),
  username: 'alice',
  excludedSections: const {},
);

/// Syncs what is synced by default (not the settings, which differ here:
/// each device keeps its own).
final SyncConfig _historyOnly = SyncConfig(
  server: Uri.parse('https://cloud.example.org/dav/'),
  username: 'alice',
);

/// A store that, once [hold] is called, keeps a later read of [key]
/// waiting until [release].
class _GatedStore extends MemoryStore {
  new(this.key);

  final String key;
  Completer<void>? _gate;
  Completer<void>? _held;
  int _skip = 0;
  final _reached = StreamController<void>.broadcast();

  /// The read of [key] after the next [skip] waits until [release]; the
  /// returned future completes when it started.
  Future<void> hold({int skip = 0}) {
    _gate = Completer<void>();
    _skip = skip;
    return _reached.stream.first;
  }

  void release() => _held?.complete();

  @override
  Future<String?> read(String key) async {
    final gate = _gate;
    if (key == this.key && gate != null) {
      if (_skip > 0) {
        _skip--;
      } else {
        // What the reader gets is read now; it goes on later.
        _gate = null;
        _held = gate;
        final value = await super.read(key);
        _reached.add(null);
        await gate.future;
        return value;
      }
    }
    return await super.read(key);
  }
}

/// The history as the previous version synced it: without the record of
/// clears (left out when it merges, dropped when it writes), and written to
/// the file as it is (no retention records).
class _PreviousHistorySection implements BackupSection {
  new(this._section);

  final HistoryBackupSection _section;

  @override
  String get id => _section.id;

  @override
  int get version => _section.version;

  @override
  Future<Object?> export({required bool includeSecrets}) async =>
      _withoutClears(await _section.export(includeSecrets: includeSecrets));

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) => _section.restore(_withoutClears(data), version: version, mode: mode);

  static Object? _withoutClears(Object? data) =>
      data is Map ? ({...data}..remove('cleared')) : data;
}

/// One device: the app's own sections (history, presets, glossaries,
/// settings) over its preferences, as the app wires them; with
/// `previousVersion` only the history, as the previous version syncs it.
class _Device {
  new({
    MemoryStore? prefs,
    SyncConfig? config,
    bool previousVersion = false,
    DateTime Function()? clock,
  }) : prefs = prefs ?? MemoryStore(),
       config = config ?? _everything {
    settings = SettingsRepository(prefs: this.prefs, secrets: MemoryStore());
    history = HistoryRepository(
      store: this.prefs,
      keyStore: MemoryStore(),
      clock: clock,
    );
    registry = previousVersion
        ? (BackupRegistry(appVersion: () async => '1.0.0+1')
            ..register(_PreviousHistorySection(HistoryBackupSection(history))))
        : createAppBackupRegistry(
            settings: settings,
            history: history,
            preferences: this.prefs,
            appVersion: () async => '1.0.0+1',
          );
    engine = SyncEngine(registry: registry, codec: testCodec);
  }

  final MemoryStore prefs;

  /// What it syncs.
  final SyncConfig config;
  late final SettingsRepository settings;
  late final HistoryRepository history;
  late final BackupRegistry registry;
  late final SyncEngine engine;
  SyncCursor? cursor;

  Future<SyncRun> sync(
    FakeWebDavServer server,
    BackupKey key, {
    SyncConfig? config,
  }) async {
    final run = await engine.run(
      dav: WebDavClient(
        server: Uri.parse('https://cloud.example.org/dav/'),
        username: 'alice',
        password: 'app-password',
        httpClient: server.client,
        folderPath: 'Mozhi',
      ),
      key: key,
      config: config ?? this.config,
      cursor: cursor,
    );
    cursor = run.cursor;
    return run;
  }

  Future<void> keepHistory(HistoryRetention retention) async {
    final current = await settings.load();
    await settings.save(current.copyWith(historyRetention: retention));
  }

  Future<Set<String>> historyIds() async => {
    for (final entry in (await history.backupData()).entries) entry.id,
  };
}

HistoryEntry _entry(String id, Duration age) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: 'translation $id',
  source: const Language(code: 'en', name: 'English'),
  target: const Language(code: 'fr', name: 'French'),
  engineId: 'mozhi:google',
  engineName: 'Engine',
  createdAt: DateTime.now().subtract(age),
);

AiProviderConfig _provider(String id, String baseUrl) => AiProviderConfig(
  id: id,
  name: 'Provider at $baseUrl',
  provider: LlmProvider.openAiCompatible,
  baseUrl: baseUrl,
  model: 'model',
);

FakeWebDavServer _server() =>
    FakeWebDavServer(folders: {'/dav/', '/dav/Mozhi/'});

/// How many `PUT`s the server got.
int _puts(FakeWebDavServer server) =>
    server.requests.where((request) => request.method == 'PUT').length;

/// Syncs [devices] in turn, [rounds] times.
Future<void> _rounds(
  List<_Device> devices,
  FakeWebDavServer server,
  BackupKey key, {
  int rounds = 3,
}) async {
  for (var round = 0; round < rounds; round++) {
    for (final device in devices) {
      await device.sync(server, key);
    }
  }
}

Future<Set<String>> _fileHistoryIds(
  FakeWebDavServer server,
  BackupKey key,
) async {
  final snapshot = await testCodec.decryptWithKey(
    server.files[_filePath]!,
    key,
  );
  final data = snapshot.sections['history']!.data! as Map;
  return {
    for (final entry in data['entries'] as List) (entry as Map)['id'] as String,
  };
}

void main() {
  late BackupKey key;

  setUpAll(() async {
    key = await testCodec.deriveKey('passphrase', salt: BackupCodec.newSalt());
  });

  group('Delete history automatically', () {
    test('devices that keep history for different times agree on one file '
        'and stop writing it; nothing is deleted on the device that keeps '
        'it longer', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('fresh', const Duration(hours: 1)),
        _entry('mid', const Duration(days: 10)),
        _entry('old', const Duration(days: 400)),
      ]);
      await week.history.replaceAll([
        _entry('mine', const Duration(minutes: 5)),
      ]);

      await _rounds([forever, week], server, key, rounds: 2);
      final writes = _puts(server);
      await _rounds([forever, week], server, key);

      expect(_puts(server), writes, reason: 'the file no longer changes');
      expect(await forever.historyIds(), {'fresh', 'mid', 'old', 'mine'});
      expect(await week.historyIds(), {'fresh', 'mine'});
      expect(await _fileHistoryIds(server, key), {
        'fresh',
        'mid',
        'old',
        'mine',
      });
    });

    test('what no device keeps any more leaves the file', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final month = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await month.keepHistory(HistoryRetention.month);
      await month.history.replaceAll([
        _entry('fresh', const Duration(hours: 1)),
        _entry('mid', const Duration(days: 10)),
        _entry('old', const Duration(days: 40)),
      ]);

      await _rounds([month, week], server, key);
      final writes = _puts(server);
      await _rounds([month, week], server, key);

      expect(_puts(server), writes);
      expect(await _fileHistoryIds(server, key), {'fresh', 'mid'});
      expect(await month.historyIds(), {'fresh', 'mid'});
      expect(await week.historyIds(), {'fresh'});
    });

    test('a device that keeps history for ever gets what the file keeps '
        'for the others when it joins', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('old', const Duration(days: 100)),
      ]);
      await _rounds([forever, week], server, key);

      final joining = _Device(config: _historyOnly);
      await joining.sync(server, key);

      expect(await joining.historyIds(), {'old'});
      expect(await week.historyIds(), isEmpty);
    });

    test('an explicit delete still reaches every device', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('fresh', const Duration(hours: 1)),
        _entry('old', const Duration(days: 100)),
      ]);
      await _rounds([forever, week], server, key);

      await forever.history.delete('old');
      await week.history.delete('fresh');
      await _rounds([forever, week], server, key);

      expect(await forever.historyIds(), isEmpty);
      expect(await week.historyIds(), isEmpty);
      expect(await _fileHistoryIds(server, key), isEmpty);
    });
  });

  group('Clear history', () {
    test('reaches what only devices that keep history longer have, and '
        'this device stops writing it back', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('fresh', const Duration(hours: 1)),
        _entry('old', const Duration(days: 20)),
      ]);
      await _rounds([forever, week], server, key);
      expect(await week.historyIds(), {'fresh'});
      expect(await _fileHistoryIds(server, key), {'fresh', 'old'});

      await week.history.clear();
      await _rounds([week, forever], server, key);
      final writes = _puts(server);
      await _rounds([week, forever], server, key);

      expect(_puts(server), writes, reason: 'the file no longer changes');
      expect(await week.historyIds(), isEmpty);
      expect(await forever.historyIds(), isEmpty);
      expect(await _fileHistoryIds(server, key), isEmpty);
    });

    test('keeps the favorites when it kept them, and what another device '
        'adds or changes afterwards', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('old', const Duration(days: 20)),
        _entry('old starred', const Duration(days: 21)),
        _entry('old edited', const Duration(days: 22)),
      ]);
      await forever.history.toggleFavorite('old starred');
      await _rounds([forever, week], server, key);

      await week.history.clear(keepFavorites: true);
      // Before the clear reaches it, the other device adds an entry and
      // stars one (after the clear).
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await forever.history.add(_entry('new', Duration.zero));
      await forever.history.toggleFavorite('old edited');
      await _rounds([week, forever], server, key);

      final kept = {'old starred', 'old edited', 'new'};
      expect(await forever.historyIds(), kept);
      expect(await week.historyIds(), kept);
      expect(await _fileHistoryIds(server, key), kept);
    });

    test('reaches a device that syncs only later (within a month), and one '
        'on the previous version through tombstones', () async {
      final server = _server();
      final week = _Device(config: _historyOnly);
      final forever = _Device(config: _historyOnly);
      await week.keepHistory(HistoryRetention.week);
      await forever.history.replaceAll([
        _entry('old', const Duration(days: 20)),
      ]);
      await _rounds([forever, week], server, key);
      await week.history.clear();
      await week.sync(server, key);

      // A device that had the entry and syncs for the first time since.
      final late = _Device(config: _historyOnly);
      await late.history.replaceAll([_entry('mine', const Duration(days: 30))]);
      await late.sync(server, key);
      expect(await late.historyIds(), isEmpty);

      // The previous version knows no record of clears: it drops it from
      // the file and writes its entries back, and the tombstones the
      // others leave for them delete them there too.
      final previous = _Device(config: _historyOnly, previousVersion: true);
      await previous.history.replaceAll([
        _entry('old', const Duration(days: 20)),
        _entry('never synced', const Duration(days: 25)),
      ]);
      await previous.sync(server, key);
      // The clearing device left a tombstone for what the file held.
      expect(await previous.historyIds(), {'never synced'});
      expect(await _fileHistoryIds(server, key), {'never synced'});
      await week.sync(server, key);
      await previous.sync(server, key);

      expect(await previous.historyIds(), isEmpty);
      expect(await _fileHistoryIds(server, key), isEmpty);
      await forever.sync(server, key);
      expect(await forever.historyIds(), isEmpty);
    });
  });

  group('Clear history and a device that joins later', () {
    /// A device that starts syncing now.
    _Device joining() => _Device(
      config: _historyOnly.copyWith(joinedAt: DateTime.now().toUtc()),
    );

    test('a device that joins after a clear keeps its own history', () async {
      final server = _server();
      final clearing = _Device(config: _historyOnly);
      await clearing.history.replaceAll([
        _entry('old', const Duration(days: 3)),
      ]);
      await clearing.sync(server, key);
      await clearing.history.clear();
      await clearing.sync(server, key);

      await Future<void>.delayed(const Duration(milliseconds: 2));
      final joiner = joining();
      await joiner.history.replaceAll([
        _entry('mine', const Duration(days: 3)),
      ]);
      await _rounds([joiner, clearing], server, key);

      expect(await joiner.historyIds(), {'mine'});
      expect(await clearing.historyIds(), {'mine'});
      expect(await _fileHistoryIds(server, key), {'mine'});
    });

    test('also when the clear reaches the folder only after it joined, '
        'which still takes what the folder held', () async {
      final server = _server();
      final clearing = _Device(config: _historyOnly);
      await clearing.history.replaceAll([
        _entry('old', const Duration(days: 3)),
      ]);
      await clearing.sync(server, key);
      // Cleared without syncing (offline).
      await clearing.history.clear();

      await Future<void>.delayed(const Duration(milliseconds: 2));
      final joiner = joining();
      await joiner.history.replaceAll([
        _entry('mine', const Duration(days: 3)),
      ]);
      await joiner.sync(server, key);
      expect(await joiner.historyIds(), {'old', 'mine'});

      await _rounds([clearing, joiner], server, key);

      expect(await joiner.historyIds(), {'mine'});
      expect(await clearing.historyIds(), {'mine'});
      expect(await _fileHistoryIds(server, key), {'mine'});
    });

    test("a clear made on the joining device before it joined doesn't "
        "take the folder's history", () async {
      final server = _server();
      final member = _Device(config: _historyOnly);
      await member.history.replaceAll([
        _entry('theirs', const Duration(days: 3)),
      ]);
      await member.sync(server, key);
      final joiner = _Device(config: _historyOnly);
      await joiner.history.replaceAll([
        _entry('mine', const Duration(days: 3)),
      ]);
      await joiner.history.clear();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final joined = _historyOnly.copyWith(joinedAt: DateTime.now().toUtc());

      for (var round = 0; round < 3; round++) {
        await joiner.sync(server, key, config: joined);
        await member.sync(server, key);
      }

      expect(await joiner.historyIds(), {'theirs'});
      expect(await member.historyIds(), {'theirs'});
    });
  });

  group('presets and glossaries saved before they had change times', () {
    test('two devices with different copies agree on one and stop writing '
        'the file', () async {
      final server = _server();
      final a = _Device();
      final b = _Device();
      await PresetsRepository(store: a.prefs).replaceAll(
        const PresetCollection(
          presets: [
            Preset(id: 'x', name: 'Copy A'),
            Preset(id: 'y', name: 'Y'),
          ],
          defaultId: 'x',
        ),
      );
      await PresetsRepository(store: b.prefs).replaceAll(
        const PresetCollection(
          presets: [
            Preset(id: 'y', name: 'Y'),
            Preset(id: 'x', name: 'Copy B'),
          ],
          defaultId: 'y',
        ),
      );
      await GlossaryRepository(store: a.prefs)
          .replaceAll(const [Glossary(id: 'g', name: 'Glossary A')]);
      await GlossaryRepository(store: b.prefs)
          .replaceAll(const [Glossary(id: 'g', name: 'Glossary B')]);

      await _rounds([a, b], server, key, rounds: 2);
      final writes = _puts(server);
      await _rounds([a, b], server, key);

      final presetsA = await PresetsRepository(store: a.prefs).load();
      final presetsB = await PresetsRepository(store: b.prefs).load();
      expect(presetsA, presetsB);
      expect(
        presetsA.presets.map((p) => p.id),
        presetsB.presets.map((p) => p.id),
      );
      expect(
        await GlossaryRepository(store: a.prefs).load(),
        await GlossaryRepository(store: b.prefs).load(),
      );
      expect(_puts(server), writes, reason: 'the file no longer changes');
    });
  });

  group('a merge racing a change in the app', () {
    test(
      'a preset edited while a sync merges is kept, with the merge',
      () async {
        final server = _server();
        final other = _Device();
        await PresetsRepository(store: other.prefs).replaceAll(
          PresetCollection(
            presets: [
              Preset(
                id: 'theirs',
                name: 'From the other device',
                updatedAt: DateTime.utc(2026, 10),
              ),
            ],
          ),
        );
        await other.sync(server, key);

        final store = _GatedStore(PresetsRepository.storageKey);
        final device = _Device(prefs: store);
        final cubit = PresetsCubit(repository: PresetsRepository(store: store));
        addTearDown(cubit.close);
        await cubit.add(name: 'Mine', options: const TranslationOptions());
        final mine = cubit.state.presets.last;

        // The export reads the presets first, then the restore counts
        // them, then the merge reads them.
        final merging = store.hold(skip: 2);
        final sync = device.sync(server, key);
        await merging;
        // The merge has read the presets; the app changes one meanwhile.
        final edit = cubit.update(mine.copyWith(name: 'Mine, edited'));
        await pumpEventQueue();
        store.release();
        await sync;
        await edit;

        final stored = await PresetsRepository(store: store).load();
        expect(
          stored.presets.map((p) => p.name),
          containsAll(['From the other device', 'Mine, edited']),
        );
        await cubit.load();
        expect(
          cubit.state.presets.map((p) => p.name),
          containsAll(['From the other device', 'Mine, edited']),
        );
      },
    );

    test('a change made from what the app held before a merge keeps the '
        'merge', () async {
      final server = _server();
      final other = _Device();
      await GlossaryRepository(store: other.prefs).replaceAll([
        Glossary(id: 'theirs', name: 'Theirs', updatedAt: DateTime.utc(2026)),
      ]);
      await other.sync(server, key);

      final device = _Device();
      final cubit = GlossaryCubit(
        repository: GlossaryRepository(store: device.prefs),
      );
      addTearDown(cubit.close);
      await cubit.load();
      await device.sync(server, key);
      // The cubit still holds what it read before the merge.
      expect(cubit.state.glossaries, isEmpty);
      await cubit.create(name: 'Mine');

      final stored = await GlossaryRepository(store: device.prefs).load();
      expect(stored.map((g) => g.name), ['Theirs', 'Mine']);
      await cubit.load();
      expect(cubit.state.glossaries.map((g) => g.name), ['Theirs', 'Mine']);

      // The next sync doesn't lose either.
      await device.sync(server, key);
      await other.sync(server, key);
      expect(
        (await GlossaryRepository(
          store: other.prefs,
        ).load()).map((g) => g.name),
        ['Theirs', 'Mine'],
      );
    });

    test('a settings change made while a merge runs is kept, and a stale '
        'save keeps the merge', () async {
      final server = _server();
      final other = _Device();
      await other.settings.save(
        AppSettings(
          providers: [_provider('theirs', 'https://ai.example.org/v1')],
        ),
      );
      await other.sync(server, key);

      final device = _Device();
      final cubit = SettingsCubit(
        repository: device.settings,
        initial: await device.settings.load(),
      );
      addTearDown(cubit.close);
      final sync = device.sync(server, key);
      cubit.setHapticFeedback(enabled: false);
      await sync;
      await pumpEventQueue();
      // A change made from settings read before the merge.
      cubit.setPureBlack(enabled: false);
      await pumpEventQueue();

      final stored = await device.settings.read();
      expect(stored.hapticFeedback, isFalse);
      expect(stored.pureBlack, isFalse);
      expect(stored.providers.map((p) => p.id), ['theirs']);
      await cubit.load();
      expect(cubit.state.providers.map((p) => p.id), ['theirs']);
      expect(cubit.state.pureBlack, isFalse);
    });
  });

  group('AI provider ids', () {
    test('two devices with different providers of one id each keep theirs '
        'and get the other under an id of its own, once', () async {
      final server = _server();
      final a = _Device();
      final b = _Device();
      final cloud = _provider('p1', 'https://ai.example.org/v1');
      final local = _provider('p1', 'http://ollama.lan:11434/v1');
      await a.settings.save(AppSettings(providers: [cloud], engineId: 'ai:p1'));
      await b.settings.save(AppSettings(providers: [local]));

      await _rounds([a, b], server, key);

      final onA = (await a.settings.read()).providers;
      final onB = (await b.settings.read()).providers;
      expect(onA, hasLength(2));
      expect(onB, hasLength(2));
      expect(onA.first, cloud);
      expect(onB.first, local);
      expect(onA.last.baseUrl, local.baseUrl);
      expect(onB.last.baseUrl, cloud.baseUrl);
      expect(onA.last.id, isNot('p1'));
      expect(onB.last.id, isNot('p1'));
      expect((await a.settings.read()).engineId, 'ai:p1');
    });

    test('a removed provider never comes back, and its id never goes to '
        'another provider', () async {
      final server = _server();
      final a = _Device();
      final b = _Device();
      final cloud = _provider('p1', 'https://ai.example.org/v1');
      final local = _provider('p1', 'http://ollama.lan:11434/v1');
      await a.settings.save(AppSettings(providers: [cloud]));
      await b.settings.save(AppSettings(providers: [cloud]));
      await _rounds([a, b], server, key, rounds: 1);

      // Removed on A, still on B; then B's provider of that id moves to
      // another server.
      await a.settings.save(const AppSettings());
      await _rounds([a, b], server, key);
      expect((await a.settings.read()).providers, isEmpty);

      await b.settings.save(AppSettings(providers: [local]));
      await _rounds([b, a], server, key);
      final onA = (await a.settings.read()).providers;
      expect(onA.map((p) => p.baseUrl), [local.baseUrl]);
      expect(onA.single.id, isNot('p1'));
    });
  });
}
