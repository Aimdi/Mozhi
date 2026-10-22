import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

/// Preferences that can't be cleared all at once (each key is deleted on
/// its own).
class _Preferences implements KeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  test('deletes the history tombstones and the last backup date', () async {
    final preferences = _Preferences();
    final keys = MemoryStore();
    final repository = HistoryRepository(store: preferences, keyStore: keys);
    await repository.add(
      HistoryEntry(
        id: '1',
        text: 'a',
        translation: 'b',
        source: const Language(code: 'en', name: 'English'),
        target: const Language(code: 'fr', name: 'French'),
        engineId: 'e',
        engineName: 'E',
        createdAt: DateTime(2026),
      ),
    );
    await repository.delete('1');
    await BackupStatusStore(preferences).recordBackup(DateTime(2026));
    expect(
      preferences.values.keys,
      containsAll([
        HistoryRepository.tombstonesStorageKey,
        BackupStatusStore.lastBackupKey,
      ]),
    );

    await LocalDataEraser(
      history: HistoryCubit(repository: repository),
      settings: createSettingsCubit(),
      historyRepository: repository,
      preferences: preferences,
    ).erase();

    expect(preferences.values, isEmpty);
    expect(keys.values, isEmpty);
  });
}
