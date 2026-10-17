import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/cubit/ocr_languages_state.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';

export 'ocr_languages_state.dart';

/// Lists the languages of on-device text recognition and downloads,
/// deletes and imports their data (Text recognition, below the offline
/// languages).
///
/// Downloads honour the offline languages' "Download over Wi-Fi only"
/// setting ([OfflineModelsCubit.wifiOnlyKey] in `store`, default on): on a
/// metered network they fail with [OfflineModelErrorKind.metered] and
/// [download] with `overMeteredNetwork` retries anyway. Imports
/// ([importFromFiles], with `picker`) never use the network. Changes made
/// elsewhere (the image screen's download offer) are picked up through
/// [TextRecognitionLanguageData.ocrLanguagesChanged]. Failures never
/// throw: [load] switches to [OfflineModelsStatus.failure], operations
/// report an [OfflineModelOutcome]; errors other than a metered network
/// also go to `addError`.
class OcrLanguagesCubit extends Cubit<OcrLanguagesState> {
  new({
    required this._data,
    required this._store,
    this._picker = const OfflineModelFilePicker(),
    this._describe = describeOfflineLanguage,
  }) : super(const OcrLanguagesState()) {
    _changes = _data.ocrLanguagesChanged.listen(
      (_) => unawaited(_refreshInstalled()),
    );
  }

  final TextRecognitionLanguageData _data;
  final KeyValueStore _store;
  final OfflineModelFilePicker _picker;
  final OfflineLanguageDescriber _describe;
  late final StreamSubscription<void> _changes;

  Future<void> load() async {
    emit(state.copyWith(status: OfflineModelsStatus.loading));
    final wifiOnly = await _readWifiOnly();
    try {
      final available = _data.isSupported;
      final languages =
          [
            for (final language in await _data.ocrLanguages())
              OcrLanguageItem(
                ocr: language,
                display: _describe(language.appCode),
              ),
          ]..sort(
            (a, b) => a.display.name.toLowerCase().compareTo(
              b.display.name.toLowerCase(),
            ),
          );
      final installed = available
          ? await _data.installedOcrLanguages()
          : const <String, int>{};
      if (isClosed) return;
      emit(
        state.copyWith(
          status: OfflineModelsStatus.ready,
          isAvailable: available,
          languages: languages,
          installed: installed,
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

  /// Downloads the data of [code], honouring [OcrLanguagesState.wifiOnly]
  /// unless [overMeteredNetwork] (the user chose "Download anyway").
  Future<void> download(String code, {bool overMeteredNetwork = false}) {
    final wifiOnly = state.wifiOnly && !overMeteredNetwork;
    return _run(
      code,
      OfflineModelOperation.download,
      () => _data.downloadOcrLanguage(
        code,
        wifiOnly: wifiOnly,
        onProgress: (fraction) => _reportProgress(code, fraction),
      ),
    );
  }

  Future<void> delete(String code) => _run(
    code,
    OfflineModelOperation.delete,
    () => _data.deleteOcrLanguage(code),
  );

  Future<void> setWifiOnly({required bool enabled}) async {
    emit(state.copyWith(wifiOnly: enabled));
    try {
      await _store.write(OfflineModelsCubit.wifiOnlyKey, '$enabled');
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Filters [OcrLanguagesState.visible] (case-insensitive).
  void search(String query) => emit(state.copyWith(query: query));

  /// Lets the user pick `.traineddata` files (downloaded by hand) and
  /// installs them. Nothing is sent over the network, so this works in
  /// every privacy mode. Reports an [OcrImportReport]; cancelling the
  /// picker changes nothing.
  Future<void> importFromFiles() async {
    if (!state.isAvailable || state.importing) return;
    void start() {
      if (isClosed || state.importing) return;
      emit(state.copyWith(importing: true, importOutcome: () => null));
    }

    OcrImportReport report;
    try {
      final paths = await _picker.pick(onCopying: start);
      if (paths.isEmpty) {
        if (!isClosed && state.importing) {
          emit(state.copyWith(importing: false));
        }
        return;
      }
      start();
      try {
        report = await _data.importOcrFiles(paths);
      } finally {
        await _clearPickedCopies();
      }
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      report = OcrImportReport(error: error);
    }
    final installed = await _readInstalled();
    if (isClosed) return;
    emit(
      state.copyWith(
        importing: false,
        installed: installed,
        importOutcome: () => report,
      ),
    );
  }

  Future<void> _run(
    String code,
    OfflineModelOperation operation,
    Future<void> Function() action,
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
    final installed = await _readInstalled();
    if (isClosed) return;
    emit(
      state.copyWith(
        installed: installed,
        pending: {...state.pending}..remove(code),
        progress: {...state.progress}..remove(code),
        outcome: () => OfflineModelOutcome(
          language: state.item(code)?.display ?? _describe(code),
          operation: operation,
          succeeded: failure == null,
          error: failure,
        ),
      ),
    );
  }

  Future<void> _refreshInstalled() async {
    final installed = await _readInstalled();
    if (isClosed || mapEquals(installed, state.installed)) return;
    emit(state.copyWith(installed: installed));
  }

  Future<Map<String, int>> _readInstalled() async {
    if (!state.isAvailable) return state.installed;
    try {
      return await _data.installedOcrLanguages();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return state.installed;
    }
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

  Future<void> _clearPickedCopies() async {
    try {
      await _picker.clearCopies();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  Future<bool> _readWifiOnly() async {
    try {
      return await _store.read(OfflineModelsCubit.wifiOnlyKey) != 'false';
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return true;
    }
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    await super.close();
  }
}
