import 'package:bloc/bloc.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:translation_repository/translation_repository.dart';

export 'offline_models_state.dart';

/// Describes an offline language code for display.
typedef OfflineLanguageDescriber = OfflineLanguage Function(String code);

/// Lists the offline engine's languages and downloads, updates and deletes
/// their models. Languages that translate one way only (models from
/// English into Azerbaijani, but not back) are listed too, with their
/// [OfflineLanguage.direction], when `details` tells which they are
/// ([OfflineLanguageDirections]).
///
/// With `details` (Mozilla's Bergamot engine, see `offlineModelDetailsOf`)
/// it also reports download sizes, disk usage, updates and download
/// progress, and re-reads the downloaded languages after each operation
/// (models can be shared between languages).
///
/// With `importer` (default: `details` when it is an [OfflineModelImport])
/// it installs models from files the user picks ([importFromFiles], with
/// `picker`) and lists the files to download by hand per language
/// ([OfflineModelsState.manualDownloads]). Imports never use the network.
///
/// The "Wi-Fi only" choice is persisted in `store` under [wifiOnlyKey]
/// (default on): a download on a metered network then fails with
/// [OfflineModelErrorKind.metered] and [download] with
/// `overMeteredNetwork` retries it anyway. Failures never throw: [load]
/// switches to [OfflineModelsStatus.failure], operations report an
/// [OfflineModelOutcome] with an [OfflineModelError]; errors other than a
/// metered network also go to `addError`.
///
/// With a translator that has [CancellableDownloads],
/// [OfflineModelsState.canCancel] is true and [cancelDownload] stops a
/// running download or update quietly: no outcome (so no message), and the
/// language stays as it was (what was received is kept for resuming).
class OfflineModelsCubit extends Cubit<OfflineModelsState> {
  new({
    required this._translator,
    required this._store,
    this._details,
    OfflineModelImport? importer,
    this._picker = const OfflineModelFilePicker(),
    this._describe = describeOfflineLanguage,
  }) : _importer =
           importer ??
           switch (_details) {
             final OfflineModelImport details => details,
             _ => null,
           },
       super(const OfflineModelsState());

  static const wifiOnlyKey = 'offline.wifiOnly';

  final OfflineTranslator _translator;
  final KeyValueStore _store;
  final OfflineModelDetails? _details;
  final OfflineModelImport? _importer;
  final OfflineModelFilePicker _picker;
  final OfflineLanguageDescriber _describe;

  Future<void> load() async {
    emit(state.copyWith(status: OfflineModelsStatus.loading));
    final wifiOnly = await _readWifiOnly();
    try {
      final available = _translator.isAvailable;
      final oneWay = _oneWayLanguages();
      final codes = _codes(oneWay);
      final languages = [
        for (final code in codes)
          switch (oneWay[code]) {
            final direction? => _describe(code).withDirection(direction),
            null => _describe(code),
          },
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final details = _details;
      final sizes = details == null
          ? const <String, int>{}
          : {for (final code in codes) code: details.downloadSize(code)};
      final importer = _importer;
      final named = {for (final language in languages) language.code: language};
      OfflineLanguage name(String code) => named[code] ?? _describe(code);
      final manual = <String, List<OfflineManualDirection>>{
        if (importer != null)
          for (final code in codes)
            if (_directions(importer.manualFiles(code), name)
                case final directions when directions.isNotEmpty)
              code: directions,
      };
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
          canImport: available && importer != null,
          manualDownloads: manual,
          canCancel: available && _translator is CancellableDownloads,
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

  /// Stops the running download or update of [code] (see
  /// [OfflineModelsState.canCancelDownload]); it ends without an
  /// [OfflineModelsState.outcome]. Does nothing otherwise.
  Future<void> cancelDownload(String code) async {
    final translator = _translator;
    if (translator is! CancellableDownloads || !state.canCancelDownload(code)) {
      return;
    }
    emit(state.copyWith(cancelling: {...state.cancelling, code}));
    try {
      await translator.cancelDownload(code);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
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

  /// Lets the user pick model files (downloaded by hand, see
  /// [OfflineModelsState.manualDownloads]) and installs every model they
  /// complete. Nothing is sent over the network, so this works in every
  /// privacy mode. Reports an [OfflineImportOutcome] and refreshes the
  /// downloaded languages; cancelling the picker changes nothing.
  Future<void> importFromFiles() async {
    final importer = _importer;
    if (importer == null || !state.canImport || state.importing) return;
    void start() {
      if (isClosed || state.importing) return;
      emit(state.copyWith(importing: true, importOutcome: () => null));
    }

    void cancelled() {
      if (!isClosed && state.importing) emit(state.copyWith(importing: false));
    }

    OfflineImportOutcome outcome;
    try {
      if (importer is OfflineModelContentsImport) {
        // The web app: the picked files are read by their contents.
        final files = await _picker.pickContents(onCopying: start);
        if (files.isEmpty) return cancelled();
        start();
        outcome = _outcomeOf(await importer.importContents(files));
      } else {
        final paths = await _picker.pick(onCopying: start);
        if (paths.isEmpty) return cancelled();
        start();
        try {
          outcome = _outcomeOf(await importer.importFiles(paths));
        } finally {
          await _clearPickedCopies();
        }
      }
    } on Object catch (error, stackTrace) {
      outcome = OfflineImportOutcome(error: OfflineModelError.of(error));
      addError(error, stackTrace);
    }
    final downloaded = await _readDownloaded();
    final storage = _details != null ? await _readStorage() : state.storage;
    if (isClosed) return;
    emit(
      state.copyWith(
        importing: false,
        downloaded: downloaded,
        storage: () => storage,
        importOutcome: () => outcome,
      ),
    );
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
    final (:failure, :cancelled) = await _attempt(action);
    final succeeded = failure == null && !cancelled;
    // Cancelled by the user (whatever the download said as it stopped):
    // nothing to report.
    final quiet = !succeeded && (cancelled || state.cancelling.contains(code));
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
        cancelling: {...state.cancelling}..remove(code),
        outcome: () => quiet
            ? null
            : OfflineModelOutcome(
                language: _languageOf(code),
                operation: operation,
                succeeded: succeeded,
                error: failure,
              ),
      ),
    );
  }

  /// Runs [action]: no failure when it succeeds or was cancelled
  /// ([OfflineDownloadCancelledException]), else why it failed (reported
  /// through [addError] unless it only needs the metered-network consent).
  ///
  /// A separate method on purpose: with the result kept in a local declared
  /// before a try/catch in `_run`, dart2js (Dart 3.13) reused that local's
  /// JavaScript variable for another value on the success path, so every
  /// successful download in the web app was reported as failed.
  Future<({OfflineModelError? failure, bool cancelled})> _attempt(
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return (failure: null, cancelled: false);
    } on OfflineDownloadCancelledException {
      return (failure: null, cancelled: true);
    } on Object catch (error, stackTrace) {
      final failure = OfflineModelError.of(error);
      if (failure.kind != OfflineModelErrorKind.metered) {
        addError(error, stackTrace);
      }
      return (failure: failure, cancelled: false);
    }
  }

  OfflineImportOutcome _outcomeOf(OfflineImportReport report) =>
      OfflineImportOutcome(
        entries: [
          for (final model in report.models)
            OfflineImportEntry(
              source: _languageOf(model.source),
              target: _languageOf(model.target),
              status: model.status,
              missingFiles: model.missingFiles,
              error: model.error,
            ),
        ],
        unmatchedFiles: report.unmatchedFiles,
      );

  /// [files] grouped by direction, in their order.
  static List<OfflineManualDirection> _directions(
    List<OfflineModelFile> files,
    OfflineLanguage Function(String code) name,
  ) {
    final groups = <(String, String), List<OfflineModelFile>>{};
    for (final file in files) {
      (groups[(file.source, file.target)] ??= []).add(file);
    }
    return [
      for (final MapEntry(key: (source, target), value: files)
          in groups.entries)
        OfflineManualDirection(
          source: name(source),
          target: name(target),
          files: List.unmodifiable(files),
        ),
    ];
  }

  /// The picker's copies are only needed during the import.
  Future<void> _clearPickedCopies() async {
    try {
      await _picker.clearCopies();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
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
      return await details.storage(_codes(_oneWayLanguages()));
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return null;
    }
  }

  /// The languages the engine translates one way only
  /// ([OfflineLanguageDirections]); empty when it does not tell.
  Map<String, OfflineLanguageDirection> _oneWayLanguages() {
    if (_details case final OfflineLanguageDirections directions) {
      return directions.oneWayLanguages;
    }
    return const {};
  }

  /// Every language listed: those that go both ways and those that go one
  /// way only ([oneWay]), which can be downloaded and deleted alike.
  Set<String> _codes(Map<String, OfflineLanguageDirection> oneWay) => {
    ..._translator.supportedLanguages,
    ...oneWay.keys,
  };

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
