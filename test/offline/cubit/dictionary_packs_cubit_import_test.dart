import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_cubit.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../helpers.dart';

void main() {
  late Uint8List spanish;
  late DictionaryPackInfo es;
  late MemoryDictionaryPackStorage storage;
  late MockOfflineModelFilePicker picker;

  setUp(() {
    spanish = spanishPack();
    es = packInfo('es', spanish);
    storage = MemoryDictionaryPackStorage();
    picker = stubOfflineModelFilePicker();
  });

  void picks(List<PickedImportFile> files) =>
      when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
          .thenAnswer((invocation) async {
            (invocation.namedArguments[#onCopying] as void Function()?)?.call();
            return files;
          });

  Future<DictionaryPacksCubit> loaded({
    List<DictionaryPackInfo>? catalog,
    DictionaryPackStorage? store,
  }) async {
    final cubit = DictionaryPacksCubit(
      packs: DictionaryPacks(
        catalog: DictionaryPackCatalog(catalog ?? [es]),
        storage: store ?? storage,
        httpClient: MockClient((_) async => http.Response('', 500)),
      ),
      store: MemoryStore(),
      picker: picker,
    );
    addTearDown(cubit.close);
    await cubit.load();
    return cubit;
  }

  test('installs the picked packs and reports them', () async {
    picks([PickedImportFile.bytes('es.mzd', spanish)]);
    final cubit = await loaded();
    expect(cubit.state.canImport, isTrue);
    final states = <DictionaryPacksState>[];
    final subscription = cubit.stream.listen(states.add);

    await cubit.importFromFiles();
    await subscription.cancel();

    expect(states.first.importing, isTrue);
    expect(cubit.state.importing, isFalse);
    expect(cubit.state.isInstalled('es'), isTrue);
    final outcome = cubit.state.importOutcome!;
    expect(outcome.error, isNull);
    expect(
      outcome.report.packs.single.status,
      DictionaryImportStatus.installed,
    );
    expect(outcome, DictionaryImportOutcome(report: outcome.report));
    verifyNever(picker.clearCopies);
  });

  test('cancelling the picker changes nothing', () async {
    picks(const []);
    final cubit = await loaded();

    await cubit.importFromFiles();

    expect(cubit.state.importing, isFalse);
    expect(cubit.state.importOutcome, isNull);
  });

  test('a picker that fails is reported', () async {
    when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
        .thenThrow(StateError('picker'));
    final cubit = await loaded();
    final errors = <Object>[];
    cubit.stream.listen(null, onError: errors.add);

    await cubit.importFromFiles();

    expect(cubit.state.importOutcome?.error, isA<OfflineModelError>());
    expect(cubit.state.importing, isFalse);
  });

  test('not offered without storage or without a catalogue', () async {
    picks([PickedImportFile.bytes('es.mzd', spanish)]);
    final unsupported = await loaded(
      store: MemoryDictionaryPackStorage(isSupported: false),
    );
    expect(unsupported.state.canImport, isFalse);
    await unsupported.importFromFiles();
    expect(unsupported.state.importOutcome, isNull);

    final empty = await loaded(catalog: const []);
    expect(empty.state.canImport, isFalse);
    verifyNever(() => picker.pickContents(onCopying: any(named: 'onCopying')));
  });
}
