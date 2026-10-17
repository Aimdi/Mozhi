import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:translation_repository/translation_repository.dart';

class MockOfflineTranslator extends Mock implements OfflineTranslator;

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
