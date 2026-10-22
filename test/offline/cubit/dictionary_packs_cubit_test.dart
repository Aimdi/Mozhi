import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_cubit.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';

void main() {
  late Uint8List spanish;
  late Uint8List english;
  late DictionaryPackInfo es;
  late DictionaryPackInfo en;
  late MemoryDictionaryPackStorage storage;
  late MemoryStore store;
  late Completer<void>? hold;
  late http.Response Function(http.Request request) respond;
  late bool metered;

  setUp(() {
    spanish = spanishPack();
    english = englishPack();
    es = packInfo('es', spanish);
    en = packInfo('en', english, name: 'English');
    storage = MemoryDictionaryPackStorage();
    store = MemoryStore();
    hold = null;
    metered = false;
    respond = (request) => switch (request.url.pathSegments.last) {
      'es.mzd' => http.Response.bytes(spanish, 200),
      'en.mzd' => http.Response.bytes(english, 200),
      _ => http.Response('missing', 404),
    };
  });

  DictionaryPacks packs({DictionaryPackStorage? store}) => DictionaryPacks(
    catalog: DictionaryPackCatalog([es, en]),
    storage: store ?? storage,
    httpClient: MockClient((request) async {
      await hold?.future;
      return respond(request);
    }),
    isMeteredConnection: () async => metered,
  );

  DictionaryPacksCubit build({DictionaryPacks? dictionaries}) =>
      DictionaryPacksCubit(packs: dictionaries ?? packs(), store: store);

  group('DictionaryPacksCubit', () {
    test('lists the catalogue by name with what is installed', () async {
      storage.put(storedPack(es), spanish);
      final cubit = build();
      await cubit.load();
      final state = cubit.state;
      expect(state.status, OfflineModelsStatus.ready);
      expect(state.isAvailable, isTrue);
      expect([for (final item in state.packs) item.id], ['en', 'es']);
      expect(state.packs.last.display.name, 'Spanish');
      expect(state.packs.last.display.nativeName, 'Español');
      expect(state.isInstalled('es'), isTrue);
      expect(state.isOutdated('es'), isFalse);
      expect(state.totalBytes, spanish.length);
      expect([for (final item in state.visibleInstalled) item.id], ['es']);
      expect([for (final item in state.visibleAvailable) item.id], ['en']);
      expect(state.wifiOnly, isTrue);
      expect(state.item('fr'), isNull);
      await cubit.close();
    });

    test('names unknown languages after the catalogue', () async {
      final cubit = DictionaryPacksCubit(
        packs: DictionaryPacks(
          catalog: DictionaryPackCatalog([
            DictionaryPackInfo(
              id: 'xq',
              language: 'xq',
              name: 'Xqish',
              url: Uri.parse('https://example.org/xq.mzd'),
              size: 1,
              sha256: es.sha256,
            ),
          ]),
          storage: storage,
        ),
        store: store,
      );
      await cubit.load();
      expect(cubit.state.packs.single.display.name, 'Xqish');
      await cubit.close();
    });

    test('searches by name, native name or code', () async {
      final cubit = build();
      await cubit.load();
      cubit.search('españ');
      expect([for (final item in cubit.state.visible) item.id], ['es']);
      cubit.search('EN');
      expect([for (final item in cubit.state.visible) item.id], ['en']);
      cubit.search('');
      expect(cubit.state.visible, hasLength(2));
      await cubit.close();
    });

    test('reads the shared Wi-Fi only setting', () async {
      await store.write(OfflineModelsCubit.wifiOnlyKey, 'false');
      final cubit = build();
      await cubit.load();
      expect(cubit.state.wifiOnly, isFalse);
      await cubit.close();
    });

    test('fails to load when the storage cannot be read', () async {
      final cubit = build(dictionaries: packs(store: _BrokenStorage()));
      final errors = <Object>[];
      final subscription = cubit.stream.listen((_) {}, onError: errors.add);
      await cubit.load();
      expect(cubit.state.status, OfflineModelsStatus.failure);
      await subscription.cancel();
      await cubit.close();
    });

    test('downloads with progress and reports the outcome', () async {
      hold = Completer<void>();
      final cubit = build();
      await cubit.load();
      final downloading = cubit.download('es');
      await pumpEventQueue();
      expect(cubit.state.pending, {'es': OfflineModelOperation.download});
      // A second tap while it runs does nothing.
      await cubit.download('es');
      hold!.complete();
      await downloading;
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.isInstalled('es'), isTrue);
      final outcome = cubit.state.outcome!;
      expect(outcome.succeeded, isTrue);
      expect(outcome.operation, OfflineModelOperation.download);
      expect(outcome.language.code, 'es');
      await cubit.close();
    });

    test('updates an outdated pack', () async {
      storage.put(storedPack(packInfo('es', english)), english);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.isOutdated('es'), isTrue);
      await cubit.download('es');
      expect(cubit.state.outcome!.operation, OfflineModelOperation.update);
      expect(cubit.state.isOutdated('es'), isFalse);
      await cubit.close();
    });

    test('asks before downloading on a metered network', () async {
      metered = true;
      final cubit = build();
      await cubit.load();
      await cubit.download('es');
      expect(cubit.state.outcome!.needsMeteredConsent, isTrue);
      expect(cubit.state.isInstalled('es'), isFalse);
      await cubit.download('es', overMeteredNetwork: true);
      expect(cubit.state.isInstalled('es'), isTrue);
      await cubit.close();
    });

    test('reports failures', () async {
      respond = (_) => http.Response('down', 503);
      final cubit = build();
      await cubit.load();
      await cubit.download('es');
      final outcome = cubit.state.outcome!;
      expect(outcome.succeeded, isFalse);
      expect(outcome.error!.kind, OfflineModelErrorKind.server);
      expect(outcome.error!.statusCode, 503);
      await cubit.close();
    });

    test('ignores packs it does not know', () async {
      final cubit = build();
      await cubit.load();
      await cubit.download('fr');
      expect(cubit.state.outcome, isNull);
      await cubit.close();
    });

    test('deletes and follows changes made elsewhere', () async {
      storage.put(storedPack(es), spanish);
      final dictionaries = packs();
      final cubit = build(dictionaries: dictionaries);
      await cubit.load();
      await cubit.delete('es');
      expect(cubit.state.isInstalled('es'), isFalse);
      expect(cubit.state.outcome!.operation, OfflineModelOperation.delete);
      await dictionaries.install(en);
      await pumpEventQueue();
      expect(cubit.state.isInstalled('en'), isTrue);
      await cubit.close();
    });

    test('keeps the list when reading it again fails', () async {
      final broken = _BrokenStorage(failAfter: 1);
      storage.put(storedPack(es), spanish);
      broken.inner = storage;
      final cubit = build(dictionaries: packs(store: broken));
      await cubit.load();
      expect(cubit.state.isInstalled('es'), isTrue);
      await cubit.delete('es');
      expect(cubit.state.isInstalled('es'), isTrue);
      await cubit.close();
    });

    test('progress steps by whole percents', () async {
      final big = Uint8List(300);
      final info = packInfo('es', big);
      final cubit = DictionaryPacksCubit(
        packs: DictionaryPacks(
          catalog: DictionaryPackCatalog([info]),
          storage: storage,
          httpClient: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.fromIterable([
                for (var i = 0; i < 300; i += 1) [0],
              ]),
              200,
            ),
          ),
        ),
        store: store,
      );
      await cubit.load();
      final progress = <double>[];
      final subscription = cubit.stream.listen((state) {
        if (state.progress['es'] case final value?) progress.add(value);
      });
      await cubit.download('es');
      await subscription.cancel();
      expect(progress.length, lessThanOrEqualTo(101));
      expect(progress.toSet().length, progress.length);
      await cubit.close();
    });
  });

  group('dictionaryPackError', () {
    final catalog = Uri.parse('https://github.com/r/es.mzd');

    test('classifies the pack errors', () {
      expect(
        dictionaryPackError(const DictionaryPackMeteredException('es')).kind,
        OfflineModelErrorKind.metered,
      );
      expect(
        dictionaryPackError(const DictionaryPackUnsupportedException('es'))
            .kind,
        OfflineModelErrorKind.unsupported,
      );
      expect(
        dictionaryPackError(
          DictionaryPackChecksumException('es', 'bad', url: catalog),
          catalogUrl: catalog,
        ),
        const OfflineModelError(OfflineModelErrorKind.checksum),
      );
      expect(
        dictionaryPackError(
          DictionaryPackDownloadException(
            'es',
            'HTTP 404',
            statusCode: 404,
            url: Uri.parse('https://mirror.example:8443/m/dictionary/es.mzd'),
          ),
          catalogUrl: catalog,
        ),
        const OfflineModelError(
          OfflineModelErrorKind.server,
          statusCode: 404,
          mirror: 'mirror.example:8443',
        ),
      );
      expect(
        dictionaryPackError(
          DictionaryPackDownloadException(
            'es',
            'down',
            url: Uri.parse('https://mirror.example/es.mzd'),
          ),
          catalogUrl: catalog,
        ),
        const OfflineModelError(
          OfflineModelErrorKind.network,
          mirror: 'mirror.example',
        ),
      );
      expect(
        dictionaryPackError(
          DictionaryPackDownloadException(
            'es',
            NetworkPolicyError.cleartext.name,
          ),
        ).kind,
        OfflineModelErrorKind.network,
      );
      expect(
        dictionaryPackError(StateError('?')).kind,
        OfflineModelErrorKind.unknown,
      );
    });
  });

  test('DictionaryPackItem matches names and codes', () {
    final item = DictionaryPackItem(
      pack: es,
      display: const OfflineLanguage(
        code: 'es',
        name: 'Spanish',
        nativeName: 'Español',
      ),
    );
    expect(item.matches('span'), isTrue);
    expect(item.matches('es'), isTrue);
    expect(item.matches('fr'), isFalse);
  });
}

/// Storage whose listing fails (after [failAfter] successful ones, served
/// by [inner]).
class _BrokenStorage extends MemoryDictionaryPackStorage {
  new({this.failAfter = 0});

  final int failAfter;
  MemoryDictionaryPackStorage? inner;
  int _lists = 0;

  @override
  Future<List<StoredDictionaryPack>> list() async {
    if (_lists++ < failAfter) return await inner!.list();
    throw StateError('unreadable');
  }

  @override
  Future<void> delete(String id) async {}
}
