import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_cubit.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';

class _MockPacks extends Mock implements DictionaryPacks;

void main() {
  late Uint8List spanish;
  late DictionaryPackInfo es;
  late MemoryDictionaryPackStorage storage;
  late MemoryStore store;
  late StreamController<List<int>> body;
  late Completer<void> listened;

  setUp(() {
    spanish = spanishPack();
    es = packInfo('es', spanish);
    storage = MemoryDictionaryPackStorage();
    store = MemoryStore();
    listened = Completer<void>();
    body = StreamController<List<int>>(
      onListen: () {
        body.add(spanish.sublist(0, 100));
        listened.complete();
      },
    );
  });

  DictionaryPacks packs() => DictionaryPacks(
    catalog: DictionaryPackCatalog([es]),
    storage: storage,
    httpClient: MockClient.streaming(
      (request, _) async => http.StreamedResponse(body.stream, 200),
    ),
  );

  group('DictionaryPacksCubit cancel', () {
    test('stops a running download quietly, installing nothing', () async {
      final cubit = DictionaryPacksCubit(packs: packs(), store: store);
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.canCancelDownload('es'), isFalse);
      unawaited(cubit.download('es'));
      await listened.future;
      expect(cubit.state.pending, {'es': OfflineModelOperation.download});
      expect(cubit.state.canCancelDownload('es'), isTrue);
      final states = <DictionaryPacksState>[];
      final subscription = cubit.stream.listen(states.add);
      addTearDown(subscription.cancel);

      await cubit.cancelDownload('es');
      await pumpEventQueue();

      expect(states.first.cancelling, {'es'});
      expect(states.first.canCancelDownload('es'), isFalse);
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.cancelling, isEmpty);
      expect(cubit.state.outcome, isNull);
      expect(cubit.state.isInstalled('es'), isFalse);
      expect(states.every((state) => state.outcome == null), isTrue);
      expect(await storage.list(), isEmpty);
    });

    test('does nothing without a running download', () async {
      final dictionaries = _MockPacks();
      when(() => dictionaries.changes).thenAnswer((_) => const Stream.empty());
      final cubit = DictionaryPacksCubit(packs: dictionaries, store: store);
      addTearDown(cubit.close);
      await cubit.cancelDownload('es');
      verifyNever(() => dictionaries.cancelInstall(any()));
      expect(cubit.state.cancelling, isEmpty);
    });

    test('reports a cancel that fails and a quiet end', () async {
      final dictionaries = _MockPacks();
      final download = Completer<void>();
      when(() => dictionaries.changes).thenAnswer((_) => const Stream.empty());
      when(() => dictionaries.catalog).thenReturn(DictionaryPackCatalog([es]));
      when(() => dictionaries.isSupported).thenReturn(true);
      when(() => dictionaries.installing).thenReturn(const {});
      when(dictionaries.installed).thenAnswer((_) async => const []);
      when(
        () => dictionaries.install(
          es,
          wifiOnly: any(named: 'wifiOnly'),
          onProgress: any(named: 'onProgress'),
        ),
      ).thenAnswer((_) => download.future);
      when(() => dictionaries.cancelInstall('es')).thenThrow(Exception('gone'));
      final errors = <Object>[];
      final cubit = _ErrorsCubit(dictionaries, store, errors);
      addTearDown(cubit.close);
      await cubit.load();
      unawaited(cubit.download('es'));
      await pumpEventQueue();

      await cubit.cancelDownload('es');
      expect(errors, [isA<Exception>()]);
      expect(cubit.state.cancelling, {'es'});

      // However the download ends while it is cancelled, no outcome.
      download.completeError(Exception('closed'));
      await pumpEventQueue();
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.outcome, isNull);
    });
  });
}

class _ErrorsCubit extends DictionaryPacksCubit {
  new(DictionaryPacks packs, KeyValueStore store, this.errors)
    : super(packs: packs, store: store);

  final List<Object> errors;

  @override
  void onError(Object error, StackTrace stackTrace) {
    errors.add(error);
    super.onError(error, stackTrace);
  }
}
