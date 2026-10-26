import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:mozhi/offline/offline.dart';

import '../helpers.dart';

/// [FakeImportingModelDetails] of the web app: imports read the picked
/// files by their contents.
class _ContentsDetails extends FakeImportingModelDetails
    implements OfflineModelContentsImport {
  final picked = <List<PickedImportFile>>[];

  @override
  Future<OfflineImportReport> importContents(
    List<PickedImportFile> files,
  ) async {
    picked.add(files);
    if (importError case final error?) throw error;
    return report;
  }
}

void main() {
  late _ContentsDetails details;
  late MockOfflineModelFilePicker picker;
  final file = PickedImportFile.bytes(
    'model.deen.intgemm.alphas.bin.gz',
    Uint8List(3),
  );

  setUp(() {
    details = _ContentsDetails()
      ..report = const OfflineImportReport(
        models: [
          OfflineImportedModel(
            source: 'de',
            target: 'en',
            status: OfflineImportStatus.installed,
          ),
        ],
        unmatchedFiles: ['notes.txt'],
      );
    picker = stubOfflineModelFilePicker();
  });

  Future<OfflineModelsCubit> loaded() async {
    final cubit = OfflineModelsCubit(
      translator: stubOfflineTranslator(),
      store: MemoryStore(),
      details: details,
      picker: picker,
    );
    addTearDown(cubit.close);
    await cubit.load();
    return cubit;
  }

  test('reads the picked files by their contents', () async {
    when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
        .thenAnswer((invocation) async {
          (invocation.namedArguments[#onCopying] as void Function()?)?.call();
          return [file];
        });
    final cubit = await loaded();
    final states = <OfflineModelsState>[];
    final subscription = cubit.stream.listen(states.add);

    await cubit.importFromFiles();
    await subscription.cancel();

    expect(details.picked, [
      [file],
    ]);
    expect(details.imports, isEmpty);
    verifyNever(() => picker.pick(onCopying: any(named: 'onCopying')));
    verifyNever(picker.clearCopies);
    expect(states.first.importing, isTrue);
    final outcome = cubit.state.importOutcome!;
    expect(outcome.installedAny, isTrue);
    expect(outcome.entries.single.source.code, 'de');
    expect(outcome.unmatchedFiles, ['notes.txt']);
    expect(cubit.state.importing, isFalse);
  });

  test('cancelling the picker changes nothing', () async {
    when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
        .thenAnswer((invocation) async {
          (invocation.namedArguments[#onCopying] as void Function()?)?.call();
          return const [];
        });
    final cubit = await loaded();

    await cubit.importFromFiles();

    expect(details.picked, isEmpty);
    expect(cubit.state.importing, isFalse);
    expect(cubit.state.importOutcome, isNull);
  });

  test('a failing import is reported', () async {
    when(() => picker.pickContents(onCopying: any(named: 'onCopying')))
        .thenAnswer((_) async => [file]);
    details.importError = const FileSystemException('QuotaExceededError');
    final cubit = await loaded();

    await cubit.importFromFiles();

    expect(cubit.state.importOutcome?.error, isNotNull);
    expect(cubit.state.importing, isFalse);
  });
}
