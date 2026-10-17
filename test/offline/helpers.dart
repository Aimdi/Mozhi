import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:translation_repository/translation_repository.dart';

class MockOfflineTranslator extends Mock implements OfflineTranslator;

class MockOfflineModelFilePicker extends Mock implements OfflineModelFilePicker;

/// A picker that returns [paths] (cancelled when empty), calling
/// `onCopying` first when [copies] is set.
MockOfflineModelFilePicker stubOfflineModelFilePicker({
  List<String> paths = const ['/picked/model.deen.intgemm.alphas.bin.gz'],
  bool copies = false,
}) {
  final picker = MockOfflineModelFilePicker();
  when(() => picker.pick(onCopying: any(named: 'onCopying')))
      .thenAnswer((invocation) async {
        if (copies) {
          (invocation.namedArguments[#onCopying] as void Function()?)?.call();
        }
        return paths;
      });
  when(picker.clearCopies).thenAnswer((_) async {});
  return picker;
}

/// Supported languages of [stubOfflineTranslator], deliberately unsorted.
const testOfflineLanguages = {'fr', 'de', 'en', 'ja', 'xx'};

/// An available translator with [downloaded] models; downloads and
/// deletions succeed immediately.
MockOfflineTranslator stubOfflineTranslator({
  bool available = true,
  Set<String> downloaded = const {'en', 'de'},
}) {
  final translator = MockOfflineTranslator();
  when(() => translator.isAvailable).thenReturn(available);
  when(() => translator.supportedLanguages).thenReturn(testOfflineLanguages);
  when(translator.downloadedLanguages).thenAnswer((_) async => {...downloaded});
  when(
    () => translator.downloadLanguage(any(), wifiOnly: any(named: 'wifiOnly')),
  ).thenAnswer((_) async {});
  when(() => translator.deleteLanguage(any())).thenAnswer((_) async {});
  return translator;
}

const int _mb = 1024 * 1024;

/// Download sizes of [FakeOfflineModelDetails] (English needs none).
const Map<String, int> testDownloadSizes = {
  'en': 0,
  'de': 50 * _mb,
  'fr': 40 * _mb,
  'ja': 60 * _mb,
  'xx': 30 * _mb,
};

/// Storage of [FakeOfflineModelDetails]: German installed (70 MB).
const testStorage = OfflineStorage(
  installedBytes: {'de': 70 * _mb},
  totalBytes: 70 * _mb,
);

/// [OfflineModelDetails] with fixed sizes whose downloads report
/// [progressSteps], then wait for [hold] (if set) and throw [error] (if
/// set).
class FakeOfflineModelDetails implements OfflineModelDetails {
  new({this.sizes = testDownloadSizes, this.storageValue = testStorage});

  Map<String, int> sizes;
  OfflineStorage storageValue;
  Exception? storageError;
  int storageCalls = 0;

  List<double> progressSteps = const [];
  Completer<void>? hold;
  Exception? error;

  /// The storage reported after a successful download, if it changes.
  OfflineStorage? storageAfterDownload;

  /// (code, wifiOnly) of every download.
  final downloads = <(String, bool)>[];

  /// The progress callback of the latest download.
  void Function(double fraction)? lastOnProgress;

  @override
  int downloadSize(String code) => sizes[code] ?? 0;

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async {
    storageCalls++;
    if (storageError case final error?) throw error;
    return storageValue;
  }

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    downloads.add((code, wifiOnly));
    lastOnProgress = onProgress;
    if (onProgress != null) progressSteps.forEach(onProgress);
    if (hold case final hold?) await hold.future;
    if (error case final error?) throw error;
    if (storageAfterDownload case final after?) storageValue = after;
  }
}

/// The files to download by hand for German in
/// [FakeImportingModelDetails] (two directions, one file each).
const testManualFiles = {
  'de': [
    OfflineModelFile(
      source: 'de',
      target: 'en',
      name: 'model.deen.intgemm.alphas.bin.gz',
      url: 'https://models.test/de-en/model.deen.intgemm.alphas.bin.gz',
      size: 25 * _mb,
    ),
    OfflineModelFile(
      source: 'en',
      target: 'de',
      name: 'model.ende.intgemm.alphas.bin.gz',
      url: 'https://models.test/en-de/model.ende.intgemm.alphas.bin.gz',
      size: 25 * _mb,
    ),
  ],
};

/// [FakeOfflineModelDetails] that also imports: [importFiles] waits for
/// [importHold] (if set), throws [importError] (if set) or returns
/// [report], and then reports [storageAfterImport] (if set).
class FakeImportingModelDetails extends FakeOfflineModelDetails
    implements OfflineModelImport {
  new({this.manual = testManualFiles});

  Map<String, List<OfflineModelFile>> manual;
  OfflineImportReport report = const OfflineImportReport();
  Exception? importError;
  Completer<void>? importHold;
  OfflineStorage? storageAfterImport;

  /// The paths of every import.
  final imports = <List<String>>[];

  @override
  Future<OfflineImportReport> importFiles(List<String> paths) async {
    imports.add(paths);
    if (importHold case final hold?) await hold.future;
    if (importError case final error?) throw error;
    if (storageAfterImport case final after?) storageValue = after;
    return report;
  }

  @override
  List<OfflineModelFile> manualFiles(String code) => manual[code] ?? const [];
}
