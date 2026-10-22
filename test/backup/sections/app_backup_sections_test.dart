import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/app_backup_sections.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/backup_fakes.dart';

/// One device: its stores and the app's registry over them.
class _Device {
  new() : prefs = MemoryStore(), secrets = MemoryStore(), keys = MemoryStore() {
    settings = SettingsRepository(prefs: prefs, secrets: secrets);
    history = HistoryRepository(store: prefs, keyStore: keys);
    registry = createAppBackupRegistry(
      settings: settings,
      history: history,
      preferences: prefs,
      appVersion: () async => '1.4.0+12',
    );
  }

  final MemoryStore prefs;
  final MemoryStore secrets;
  final MemoryStore keys;
  late final SettingsRepository settings;
  late final HistoryRepository history;
  late final BackupRegistry registry;
}

final _entry = HistoryEntry(
  id: '1',
  text: 'Guten Abend',
  translation: 'Good evening',
  source: const Language(code: 'de', name: 'German'),
  target: const Language(code: 'en', name: 'English'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026, 10, 20, 19),
  isFavorite: true,
);

const _glossary = Glossary(
  id: 'g',
  name: 'Work',
  terms: [GlossaryTerm(source: 'deck', target: 'Foliensatz')],
);

const _settings = AppSettings(
  onboardingComplete: true,
  providers: [
    AiProviderConfig(
      id: 'p',
      name: 'Local',
      provider: LlmProvider.ollama,
      baseUrl: 'http://localhost:11434',
      model: 'm',
      apiKey: 'secret-key',
    ),
  ],
);

void main() {
  test('registers history, presets, glossaries and settings', () {
    final device = _Device();

    expect(device.registry.sections.map((s) => s.id), [
      'history',
      'presets',
      'glossaries',
      'settings',
    ]);
  });

  test('a backup moves everything to a new device', () async {
    final phone = _Device();
    await phone.history.add(_entry);
    await phone.settings.save(_settings);
    await PresetsRepository(store: phone.prefs).save(
      const PresetCollection(
        presets: [Preset(id: 'x', name: 'Mine')],
      ),
    );
    await GlossaryRepository(store: phone.prefs).save([_glossary]);

    final snapshot = await phone.registry.snapshot(includeSecrets: true);
    final bytes = await testCodec.encrypt(snapshot, 'correct horse battery');
    final newPhone = _Device();
    final report = await newPhone.registry.restore(
      await testCodec.decrypt(bytes, 'correct horse battery'),
      mode: BackupRestoreMode.replace,
    );

    expect(report.restored, ['history', 'presets', 'glossaries', 'settings']);
    expect(
      report.changes['history'],
      const BackupItemChange(before: 0, after: 1),
    );
    expect(await newPhone.history.load(), [_entry]);
    expect(
      (await PresetsRepository(
        store: newPhone.prefs,
      ).load()).presets.single.name,
      'Mine',
    );
    expect(await GlossaryRepository(store: newPhone.prefs).load(), [_glossary]);
    final settings = await newPhone.settings.load();
    expect(settings.providers.single.apiKey, 'secret-key');
    expect(newPhone.secrets.values['apikey.p'], 'secret-key');
  });

  test('without secrets the backup holds no key', () async {
    final phone = _Device();
    await phone.settings.save(_settings);

    final snapshot = await phone.registry.snapshot(includeSecrets: false);
    final newPhone = _Device();
    await newPhone.registry.restore(snapshot, mode: BackupRestoreMode.replace);

    expect((await newPhone.settings.load()).providers.single.apiKey, isNull);
    expect(newPhone.secrets.values, isNot(contains('apikey.p')));
  });
}
