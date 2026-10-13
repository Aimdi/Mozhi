import 'package:bloc/bloc.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:translation_repository/translation_repository.dart';

export 'offline_models_state.dart';

/// Describes an offline language code for display.
typedef OfflineLanguageDescriber = OfflineLanguage Function(String code);

/// Lists the offline engine's languages and downloads/deletes their models.
///
/// The "Wi-Fi only" choice is persisted in `store` under [wifiOnlyKey]
/// (default on). Failures never throw: [load] switches to
/// [OfflineModelsStatus.failure], downloads and deletions report an
/// [OfflineModelOutcome]; all errors also go to `addError`.
class OfflineModelsCubit extends Cubit<OfflineModelsState> {
  OfflineModelsCubit({
    required OfflineTranslator translator,
    required KeyValueStore store,
    OfflineLanguageDescriber describe = describeOfflineLanguage,
  }) : _translator = translator,
       _store = store,
       _describe = describe,
       super(const OfflineModelsState());

  static const wifiOnlyKey = 'offline.wifiOnly';

  final OfflineTranslator _translator;
  final KeyValueStore _store;
  final OfflineLanguageDescriber _describe;

  Future<void> load() async {
    emit(state.copyWith(status: OfflineModelsStatus.loading));
    final wifiOnly = await _readWifiOnly();
    try {
      final available = _translator.isAvailable;
      final languages = [
        for (final code in _translator.supportedLanguages) _describe(code),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final downloaded = available
          ? await _translator.downloadedLanguages()
          : const <String>{};
      if (isClosed) return;
      emit(
        state.copyWith(
          status: OfflineModelsStatus.ready,
          isAvailable: available,
          languages: languages,
          downloaded: downloaded,
          wifiOnly: wifiOnly,
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

  /// Downloads the model for [code], honouring [OfflineModelsState.wifiOnly].
  Future<void> download(String code) => _run(
    code,
    OfflineModelOperation.download,
    () => _translator.downloadLanguage(code, wifiOnly: state.wifiOnly),
    (downloaded) => {...downloaded, code},
  );

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
    var succeeded = true;
    try {
      await action();
    } on Object catch (error, stackTrace) {
      succeeded = false;
      addError(error, stackTrace);
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        downloaded: succeeded ? update(state.downloaded) : null,
        pending: {...state.pending}..remove(code),
        outcome: () => OfflineModelOutcome(
          language: _languageOf(code),
          operation: operation,
          succeeded: succeeded,
        ),
      ),
    );
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

/// Names [code] via [LanguageCatalog], falling back to the code itself.
OfflineLanguage describeOfflineLanguage(String code) {
  try {
    final language = LanguageCatalog.byCode(code);
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
