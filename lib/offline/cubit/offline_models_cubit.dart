import 'package:bloc/bloc.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:translation_repository/translation_repository.dart';

export 'offline_models_state.dart';

/// Describes an offline language code for display.
typedef OfflineLanguageDescriber = OfflineLanguage Function(String code);

/// Lists the offline engine's languages and downloads, updates and deletes
/// their models.
///
/// With `details` (Mozilla's Bergamot engine, see `offlineModelDetailsOf`)
/// it also reports download sizes, disk usage, updates and download
/// progress, and re-reads the downloaded languages after each operation
/// (models can be shared between languages).
///
/// The "Wi-Fi only" choice is persisted in `store` under [wifiOnlyKey]
/// (default on): a download on a metered network then fails with
/// [OfflineModelErrorKind.metered] and [download] with
/// `overMeteredNetwork` retries it anyway. Failures never throw: [load]
/// switches to [OfflineModelsStatus.failure], operations report an
/// [OfflineModelOutcome] with an [OfflineModelError]; errors other than a
/// metered network also go to `addError`.
class OfflineModelsCubit extends Cubit<OfflineModelsState> {
  new({
    required this._translator,
    required this._store,
    this._details,
    this._describe = describeOfflineLanguage,
  }) : super(const OfflineModelsState());

  static const wifiOnlyKey = 'offline.wifiOnly';

  final OfflineTranslator _translator;
  final KeyValueStore _store;
  final OfflineModelDetails? _details;
  final OfflineLanguageDescriber _describe;

  Future<void> load() async {
    emit(state.copyWith(status: OfflineModelsStatus.loading));
    final wifiOnly = await _readWifiOnly();
    try {
      final available = _translator.isAvailable;
      final codes = _translator.supportedLanguages;
      final languages = [for (final code in codes) _describe(code)]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final details = _details;
      final sizes = details == null
          ? const <String, int>{}
          : {for (final code in codes) code: details.downloadSize(code)};
      final downloaded = available
          ? await _translator.downloadedLanguages()
          : const <String>{};
      final storage = available ? await _readStorage() : null;
      if (isClosed) return;
      emit(
        state.copyWith(
          status: OfflineModelsStatus.ready,
          isAvailable: available,
          languages: languages,
          downloaded: downloaded,
          wifiOnly: wifiOnly,
          downloadSizes: sizes,
          storage: () => storage,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed) return;
      emit(
        state.copyWith(status: OfflineModelsStatus.failure, wifiOnly: wifiOnly),
      );
      addError(error, stackTrace);
    }
  }

  /// Downloads the models for [code] (or updates them when a newer version
  /// exists), honouring [OfflineModelsState.wifiOnly] unless
  /// [overMeteredNetwork] (the user chose "Download anyway").
  Future<void> download(String code, {bool overMeteredNetwork = false}) {
    final wifiOnly = state.wifiOnly && !overMeteredNetwork;
    final details = _details;
    return _run(
      code,
      state.isOutdated(code)
          ? OfflineModelOperation.update
          : OfflineModelOperation.download,
      () => details == null
          ? _translator.downloadLanguage(code, wifiOnly: wifiOnly)
          : details.download(
              code,
              wifiOnly: wifiOnly,
              onProgress: (fraction) => _reportProgress(code, fraction),
            ),
      (downloaded) => {...downloaded, code},
    );
  }

  Future<void> delete(String code) => _run(
    code,
    OfflineModelOperation.delete,
    () => _translator.deleteLanguage(code),
    (downloaded) => {...downloaded}..remove(code),
  );

  Future<void> setWifiOnly({required bool enabled}) async {
    emit(state.copyWith(wifiOnly: enabled));
    try {
      await _store.write(wifiOnlyKey, '$enabled');
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Filters [OfflineModelsState.visible] (case-insensitive).
  void search(String query) => emit(state.copyWith(query: query));

  Future<void> _run(
    String code,
    OfflineModelOperation operation,
    Future<void> Function() action,
    Set<String> Function(Set<String> downloaded) update,
  ) async {
    if (state.pending.containsKey(code)) return;
    emit(
      state.copyWith(
        pending: {...state.pending, code: operation},
        outcome: () => null,
      ),
    );
    OfflineModelError? failure;
    try {
      await action();
    } on Object catch (error, stackTrace) {
      failure = OfflineModelError.of(error);
      if (failure.kind != OfflineModelErrorKind.metered) {
        addError(error, stackTrace);
      }
    }
    final succeeded = failure == null;
    // With details the engine knows best what is downloaded now; reading
    // the storage again also refreshes sizes and updates after a failure
    // (e.g. a discarded download).
    final fallback = succeeded ? update(state.downloaded) : null;
    final downloaded = _details != null
        ? await _readDownloaded() ?? fallback
        : fallback;
    final storage = _details != null ? await _readStorage() : state.storage;
    if (isClosed) return;
    emit(
      state.copyWith(
        downloaded: downloaded,
        storage: () => storage,
        pending: {...state.pending}..remove(code),
        progress: {...state.progress}..remove(code),
        outcome: () => OfflineModelOutcome(
          language: _languageOf(code),
          operation: operation,
          succeeded: succeeded,
          error: failure,
        ),
      ),
    );
  }

  /// Emits download progress in whole percent steps only.
  void _reportProgress(String code, double fraction) {
    if (isClosed || !state.pending.containsKey(code)) return;
    final previous = state.progress[code];
    if (previous != null &&
        (previous * 100).floor() == (fraction * 100).floor()) {
      return;
    }
    emit(state.copyWith(progress: {...state.progress, code: fraction}));
  }

  Future<Set<String>?> _readDownloaded() async {
    try {
      return await _translator.downloadedLanguages();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return null;
    }
  }

  Future<OfflineStorage?> _readStorage() async {
    final details = _details;
    if (details == null) return null;
    try {
      return await details.storage(_translator.supportedLanguages);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return null;
    }
  }

  OfflineLanguage _languageOf(String code) {
    for (final language in state.languages) {
      if (language.code == code) return language;
    }
    return _describe(code);
  }

  Future<bool> _readWifiOnly() async {
    try {
      return await _store.read(wifiOnlyKey) != 'false';
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return true;
    }
  }
}

/// Names [code] via [LanguageCatalog] (or [lookup]), falling back to the
/// code itself when the language is unknown or the lookup fails.
OfflineLanguage describeOfflineLanguage(
  String code, {
  Language? Function(String code) lookup = LanguageCatalog.byCode,
}) {
  try {
    final language = lookup(code);
    final name = language?.name ?? LanguageCatalog.nameOf(code);
    final nativeName = language?.nativeName;
    return OfflineLanguage(
      code: code,
      name: name,
      nativeName: nativeName == name ? null : nativeName,
    );
  } on Object {
    return OfflineLanguage(code: code, name: code);
  }
}
