import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/cubit/ocr_offer_state.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart'
    show OfflineModelsCubit;
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';

export 'ocr_offer_state.dart';

/// The image screen's offer to get missing text recognition data for
/// [language] (see [OcrDataMissingException]): [download] it (only on the
/// user's tap, honouring the offline languages' "Download over Wi-Fi only"
/// setting, `OfflineModelsCubit.wifiOnlyKey` in `store`) or
/// [importFromFiles] without the network (Offline only). Becomes
/// [OcrOfferStatus.installed] once the data is on the device, also when it
/// was installed elsewhere (the offline languages screen) meanwhile.
class OcrOfferCubit extends Cubit<OcrOfferState> {
  new({
    required this._data,
    required this.language,
    required this._store,
    this._picker = const OfflineModelFilePicker(),
  }) : super(const OcrOfferState()) {
    _changes = _data.ocrLanguagesChanged.listen((_) => unawaited(_refresh()));
  }

  final TextRecognitionLanguageData _data;
  final KeyValueStore _store;
  final OfflineModelFilePicker _picker;
  late final StreamSubscription<void> _changes;

  /// The language whose data is offered.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final OcrLanguage language;

  /// Downloads the data, over a metered network only with
  /// [overMeteredNetwork] (the user chose "Download anyway") or when Wi-Fi
  /// only is off. A metered network stops with
  /// [OfflineModelErrorKind.metered] before anything is sent.
  Future<void> download({bool overMeteredNetwork = false}) async {
    if (state.isBusy || state.status == OcrOfferStatus.installed) return;
    emit(
      state.copyWith(
        status: OcrOfferStatus.downloading,
        progress: () => null,
        error: () => null,
        importReport: () => null,
      ),
    );
    final wifiOnly = !overMeteredNetwork && await _readWifiOnly();
    try {
      await _data.downloadOcrLanguage(
        language.code,
        wifiOnly: wifiOnly,
        onProgress: _reportProgress,
      );
    } on Object catch (error, stackTrace) {
      final failure = OfflineModelError.of(error);
      if (failure.kind != OfflineModelErrorKind.metered) {
        addError(error, stackTrace);
      }
      if (isClosed) return;
      emit(
        state.copyWith(
          status: OcrOfferStatus.idle,
          progress: () => null,
          error: () => failure,
        ),
      );
      return;
    }
    if (isClosed) return;
    emit(
      state.copyWith(status: OcrOfferStatus.installed, progress: () => null),
    );
  }

  /// Lets the user pick files (e.g. `deu.traineddata` downloaded on
  /// another device) and installs them, without the network. Cancelling
  /// the picker changes nothing.
  Future<void> importFromFiles() async {
    if (state.isBusy || state.status == OcrOfferStatus.installed) return;
    void start() {
      if (isClosed || state.status == OcrOfferStatus.importing) return;
      emit(
        state.copyWith(
          status: OcrOfferStatus.importing,
          error: () => null,
          importReport: () => null,
        ),
      );
    }

    OcrImportReport report;
    try {
      final paths = await _picker.pick(onCopying: start);
      if (paths.isEmpty) {
        if (!isClosed) emit(state.copyWith(status: OcrOfferStatus.idle));
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
    if (isClosed) return;
    final installed =
        report.installed.contains(language.code) ||
        report.alreadyInstalled.contains(language.code);
    emit(
      state.copyWith(
        status: installed ? OcrOfferStatus.installed : OcrOfferStatus.idle,
        importReport: () => installed ? null : report,
      ),
    );
  }

  Future<void> _refresh() async {
    if (isClosed || state.status == OcrOfferStatus.installed) return;
    try {
      final installed = await _data.installedOcrLanguages();
      if (isClosed || !installed.containsKey(language.code)) return;
      if (state.status == OcrOfferStatus.downloading) return;
      emit(
        state.copyWith(
          status: OcrOfferStatus.installed,
          error: () => null,
          importReport: () => null,
        ),
      );
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Emits download progress in whole percent steps only.
  void _reportProgress(double fraction) {
    if (isClosed || state.status != OcrOfferStatus.downloading) return;
    final previous = state.progress;
    if (previous != null &&
        (previous * 100).floor() == (fraction * 100).floor()) {
      return;
    }
    emit(state.copyWith(progress: () => fraction));
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
