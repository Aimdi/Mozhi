import 'dart:async';

import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

const int _mb = 1024 * 1024;

const deuOcr = OcrLanguage(code: 'deu', appCode: 'de', downloadSize: 1525436);

final engOcr = OcrLanguage(
  code: 'eng',
  appCode: 'en',
  downloadSize: 4 * _mb,
  url: Uri.parse('https://example.org/eng.traineddata'),
);

const fraOcr = OcrLanguage(code: 'fra', appCode: 'fr', downloadSize: 3 * _mb);

const jpnOcr = OcrLanguage(code: 'jpn', appCode: 'ja', downloadSize: 2 * _mb);

const chiSimOcr = OcrLanguage(
  code: 'chi_sim',
  appCode: 'zh-CN',
  downloadSize: 2 * _mb,
);

/// A recognizer with downloadable language data (like Tesseract): German,
/// English, French, Japanese and Simplified Chinese; [installed] are on the
/// device. Downloads and imports succeed at once unless set up otherwise.
class FakeOcrData
    implements
        TextRecognitionService,
        TextRecognitionLanguageData,
        TextRecognitionConfidence {
  new({
    this.isSupported = true,
    Map<String, int>? installed,
    this.text = 'Hallo',
  }) : installed = installed ?? {};

  @override
  bool isSupported;

  /// Bytes per installed code.
  Map<String, int> installed;

  /// What [recognizeWith] returns.
  String text;

  /// The confidence [recognizeWithConfidence] reports (null: unknown).
  int? confidence;

  /// The layout [recognizeWithConfidence] reports (null: unknown).
  TextLayout? layout;

  List<OcrLanguage> languages = [chiSimOcr, deuOcr, engOcr, fraOcr, jpnOcr];

  /// Thrown by [recognizeWith], [downloadOcrLanguage] or [importOcrFiles]
  /// when set.
  Exception? recognizeError;
  Exception? downloadError;
  Exception? importError;
  Exception? installedError;
  Exception? languagesError;

  /// When set, downloads wait for it (after reporting [progressSteps]).
  Completer<void>? downloadGate;
  List<double> progressSteps = const [];

  /// What [importOcrFiles] reports; by default every known
  /// `<code>.traineddata` among the paths is installed.
  OcrImportReport? importReport;

  final recognized = <List<String>>[];
  final downloads = <({String code, bool wifiOnly})>[];
  final deleted = <String>[];
  final imported = <List<String>>[];
  final sources = <Language>[];
  final _changes = StreamController<void>.broadcast();

  /// Installs [code] behind the caller's back (e.g. on another screen).
  void installElsewhere(String code) {
    installed = {...installed, code: _sizeOf(code)};
    _changes.add(null);
  }

  int _sizeOf(String code) =>
      languages.where((l) => l.code == code).firstOrNull?.downloadSize ?? 1;

  @override
  Stream<void> get ocrLanguagesChanged => _changes.stream;

  @override
  Future<List<OcrLanguage>> ocrLanguages() async {
    final error = languagesError;
    if (error != null) throw error;
    return languages;
  }

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) async {
    final key = LanguageMatcher.normalize(code).toLowerCase();
    for (final language in languages) {
      if (language.appCode.toLowerCase() == key ||
          language.appCode.toLowerCase() == key.split('-').first) {
        return language;
      }
    }
    return null;
  }

  @override
  Future<Map<String, int>> installedOcrLanguages() async {
    final error = installedError;
    if (error != null) throw error;
    return {...installed};
  }

  @override
  Future<String> recognize(PickedImage image, {required Language source}) {
    sources.add(source);
    return recognizeWith(image, const ['eng']);
  }

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) async {
    recognized.add(codes);
    final error = recognizeError;
    if (error != null) throw error;
    return text;
  }

  @override
  Future<TextWithConfidence> recognizeWithConfidence(
    PickedImage image,
    List<String> codes,
  ) async => TextWithConfidence(
    await recognizeWith(image, codes),
    confidence: confidence,
    layout: layout,
  );

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    downloads.add((code: code, wifiOnly: wifiOnly));
    progressSteps.forEach(onProgress ?? (_) {});
    await downloadGate?.future;
    final error = downloadError;
    if (error != null) throw error;
    installed = {...installed, code: _sizeOf(code)};
    _changes.add(null);
  }

  @override
  Future<void> deleteOcrLanguage(String code) async {
    deleted.add(code);
    installed = {...installed}..remove(code);
    _changes.add(null);
  }

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) async {
    imported.add(paths);
    final error = importError;
    if (error != null) throw error;
    final report =
        importReport ??
        OcrImportReport(
          installed: [
            for (final language in languages)
              if (paths.any((p) => p.endsWith(language.fileName)))
                language.code,
          ],
        );
    for (final code in report.installed) {
      installed = {...installed, code: _sizeOf(code)};
    }
    if (report.installed.isNotEmpty) _changes.add(null);
    return report;
  }
}

/// [FakeOcrData] without a confidence (like a recognizer that does not
/// report one).
class PlainOcrData
    implements TextRecognitionService, TextRecognitionLanguageData {
  new(this.inner);

  final FakeOcrData inner;

  @override
  bool get isSupported => inner.isSupported;

  @override
  Stream<void> get ocrLanguagesChanged => inner.ocrLanguagesChanged;

  @override
  Future<List<OcrLanguage>> ocrLanguages() => inner.ocrLanguages();

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) =>
      inner.ocrLanguageFor(code);

  @override
  Future<Map<String, int>> installedOcrLanguages() =>
      inner.installedOcrLanguages();

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      inner.recognize(image, source: source);

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) =>
      inner.recognizeWith(image, codes);

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) => inner.downloadOcrLanguage(
    code,
    wifiOnly: wifiOnly,
    onProgress: onProgress,
  );

  @override
  Future<void> deleteOcrLanguage(String code) => inner.deleteOcrLanguage(code);

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) =>
      inner.importOcrFiles(paths);
}

/// [FakeOcrData] whose downloads wait until [cancelOcrDownload] stops them
/// (or [downloadGate] opens).
class CancellableOcrData extends FakeOcrData
    implements CancellableOcrDownloads {
  new() : super(installed: {'deu': 1525436});

  final cancelled = <String>[];

  /// Thrown by [cancelOcrDownload] when set.
  Exception? cancelError;

  /// What a cancelled download fails with.
  Exception stopWith = const OfflineDownloadCancelledException();

  Completer<void>? _running;

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    final running = _running = Completer<void>();
    onProgress?.call(0.25);
    final gate = downloadGate;
    await Future.any([running.future, ?gate?.future]);
    if (running.isCompleted) throw stopWith;
    await super.downloadOcrLanguage(code, wifiOnly: wifiOnly);
  }

  @override
  Future<void> cancelOcrDownload(String code) async {
    cancelled.add(code);
    final error = cancelError;
    if (error != null) throw error;
    final running = _running;
    if (running != null && !running.isCompleted) running.complete();
  }
}
