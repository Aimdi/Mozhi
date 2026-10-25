import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/cubit/starter_phrasebooks_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/platform/free_space.dart';

import '../starter_fixtures.dart';

void main() {
  final bytes = starterPackBytes(starterPackJson());
  final info = starterInfo(bytes);

  StarterPhrasebooks packs(
    MemoryStore store,
    Future<http.Response> Function(http.Request request) answer,
  ) => StarterPhrasebooks(
    catalog: StarterPhrasebookCatalog([info]),
    store: store,
    httpClient: MockClient(answer),
  );

  test('lists the catalogue with what is installed', () async {
    final store = MemoryStore();
    await installStarterPack(store, bytes);
    final cubit = StarterPhrasebooksCubit(
      packs(store, (_) async => http.Response('', 500)),
    );
    expect(cubit.state.loading, isTrue);
    await cubit.load();
    final item = cubit.state.items.single;
    expect(cubit.state.loading, isFalse);
    expect(item.isInstalled, isTrue);
    expect(item.hasUpdate, isFalse);
    expect(item.isDownloading, isFalse);
    await cubit.close();
  });

  test('installs with progress, then deletes', () async {
    final store = MemoryStore();
    final cubit = StarterPhrasebooksCubit(
      packs(store, (_) async => http.Response.bytes(bytes, 200)),
    );
    await cubit.load();
    final states = <StarterPhrasebooksState>[];
    final subscription = cubit.stream.listen(states.add);
    await cubit.install(info);
    expect(states.any((s) => s.items.single.isDownloading), isTrue);
    expect(cubit.state.items.single.isInstalled, isTrue);
    expect(cubit.state.items.single.error, isNull);
    await cubit.delete(info.id);
    expect(cubit.state.items.single.isInstalled, isFalse);
    await subscription.cancel();
    await cubit.close();
  });

  test('says why an install failed', () async {
    final download = StarterPhrasebooksCubit(
      packs(MemoryStore(), (_) async => http.Response('', 404)),
    );
    await download.load();
    await download.install(info);
    expect(download.state.items.single.error, StarterPhrasebookError.download);
    expect(download.state.items.single.isDownloading, isFalse);

    final checksum = StarterPhrasebooksCubit(
      packs(MemoryStore(), (_) async => http.Response.bytes([1, 2, 3], 200)),
    );
    await checksum.load();
    await checksum.install(info);
    expect(checksum.state.items.single.error, StarterPhrasebookError.checksum);

    final other = StarterPhrasebooksCubit(
      packs(_FullStore(), (_) async => http.Response.bytes(bytes, 200)),
    );
    await other.load();
    await other.install(info);
    expect(other.state.items.single.error, StarterPhrasebookError.other);
    await download.close();
    await checksum.close();
    await other.close();
  });

  test('an update is a new version in the catalogue', () async {
    final store = MemoryStore();
    final old = starterPackBytes(starterPackJson(revision: 1));
    await installStarterPack(store, old);
    final cubit = StarterPhrasebooksCubit(
      packs(store, (_) async => http.Response.bytes(bytes, 200)),
    );
    await cubit.load();
    expect(cubit.state.items.single.hasUpdate, isTrue);
    await cubit.install(info);
    expect(cubit.state.items.single.hasUpdate, isFalse);
    await cubit.close();
  });

  test('an unreadable list reads as nothing installed', () async {
    final cubit = StarterPhrasebooksCubit(
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: _BrokenStore(),
      ),
    );
    await cubit.load();
    expect(cubit.state.items.single.isInstalled, isFalse);
    await cubit.close();
    // Closed: nothing more is emitted.
    await cubit.load();
  });

  test('says when the phone has too little free space', () async {
    var requests = 0;
    final cubit = StarterPhrasebooksCubit(
      StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([info]),
        store: MemoryStore(),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response.bytes(bytes, 200);
        }),
        freeSpace: FreeSpace(isWeb: true, browser: () async => 1024),
      ),
    );
    await cubit.load();
    await cubit.install(info);
    final item = cubit.state.items.single;
    expect(item.error, StarterPhrasebookError.space);
    expect(item.space?.availableBytes, 1024);
    expect(item.space?.requiredBytes, requiredFreeSpace(info.size * 2));
    expect(requests, 0);
    // A new attempt clears it.
    expect(item.copyWith(space: () => null).space, isNull);
    await cubit.close();
  });
}

/// A store that is full.
class _FullStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('QuotaExceededError');
}

/// A store that cannot be read.
class _BrokenStore extends MemoryStore {
  @override
  Future<String?> read(String key) async => throw StateError('broken');
}
