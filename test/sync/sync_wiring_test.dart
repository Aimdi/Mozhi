import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/bootstrap.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/sync/data/sync_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the app creates a sync service over its registry and stores', () async {
    final prefs = MemoryStore();
    final secrets = MemoryStore();
    final dependencies = await createDependencies(
      prefs: prefs,
      secrets: secrets,
    );
    final sync = dependencies.syncService!;
    expect(sync.sectionIds, containsAll(['history', 'settings', 'phrasebook']));
    expect(
      sync.sectionIds,
      dependencies.backupRegistry!.sections.map((s) => s.id).toList(),
    );
    await sync.load();
    expect(sync.state.isSetUp, isFalse);
    prefs.values[SyncStore.configKey] =
        '{"server": "https://dav.example.org/", "username": "u"}';
    secrets.values[SyncStore.passwordKey] = 'pw';
    final again = await createDependencies(prefs: prefs, secrets: secrets);
    await again.syncService!.load();
    expect(again.syncService!.state.isSetUp, isTrue);
    expect(again.syncService!.state.unlocked, isFalse);
  });
}
