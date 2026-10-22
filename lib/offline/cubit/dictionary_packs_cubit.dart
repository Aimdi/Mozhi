import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_state.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:translation_repository/translation_repository.dart';

export 'dictionary_packs_state.dart';

/// Lists the offline dictionaries of the catalogue and downloads, updates
/// and deletes them (Dictionaries, below the offline languages).
///
/// Downloads honour the offline languages' "Download over Wi-Fi only"
/// setting ([OfflineModelsCubit.wifiOnlyKey] in `store`, default on): on a
/// metered network they fail with [OfflineModelErrorKind.metered] and
/// [download] with `overMeteredNetwork` retries anyway. Changes made
/// elsewhere are picked up through [DictionaryPacks.changes]. Failures
/// never throw: [load] switches to [OfflineModelsStatus.failure],
/// operations report an [OfflineModelOutcome]; errors other than a
/// metered network also go to `addError`.
class DictionaryPacksCubit extends Cubit<DictionaryPacksState> {
  new({
    required this._packs,
    required this._store,
    this._describe = describeOfflineLanguage,
  }) : super(const DictionaryPacksState()) {
    _changes = _packs.changes.listen((_) => unawaited(_refreshInstalled()));
  }

  final DictionaryPacks _packs;
  final KeyValueStore _store;
  final OfflineLanguageDescriber _describe;
  late final StreamSubscription<void> _changes;

  Future<void> load() async {
    emit(state.copyWith(status: OfflineModelsStatus.loading));
    final wifiOnly = await _readWifiOnly();
    try {
      final items =
          [
            for (final pack in _packs.catalog.packs)
              DictionaryPackItem(pack: pack, display: _display(pack)),
          ]..sort(
            (a, b) => a.display.name.toLowerCase().compareTo(
              b.display.name.toLowerCase(),
            ),
          );
      final installed = await _readInstalled(throwing: true);
      if (isClosed) return;
      emit(
        state.copyWith(
          status: OfflineModelsStatus.ready,
          isAvailable: _packs.isSupported,
          packs: items,
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

  /// Downloads (or updates) the pack [id], honouring
  /// [DictionaryPacksState.wifiOnly] unless [overMeteredNetwork] (the user
  /// chose "Download anyway").
  Future<void> download(String id, {bool overMeteredNetwork = false}) async {
    final item = state.item(id);
    if (item == null) return;
    final wifiOnly = state.wifiOnly && !overMeteredNetwork;
    await _run(
      id,
      state.isOutdated(id)
          ? OfflineModelOperation.update
          : OfflineModelOperation.download,
      () => _packs.install(
        item.pack,
        wifiOnly: wifiOnly,
        onProgress: (fraction) => _reportProgress(id, fraction),
      ),
    );
  }

  Future<void> delete(String id) =>
      _run(id, OfflineModelOperation.delete, () => _packs.delete(id));

  /// Filters [DictionaryPacksState.visible] (case-insensitive).
  void search(String query) => emit(state.copyWith(query: query));

  Future<void> _run(
    String id,
    OfflineModelOperation operation,
    Future<void> Function() action,
  ) async {
    if (state.pending.containsKey(id)) return;
    emit(
      state.copyWith(
        pending: {...state.pending, id: operation},
        outcome: () => null,
      ),
    );
    final failure = await _attempt(id, action);
    final installed = await _readInstalled();
    if (isClosed) return;
    emit(
      state.copyWith(
        installed: installed,
        pending: {...state.pending}..remove(id),
        progress: {...state.progress}..remove(id),
        outcome: () => OfflineModelOutcome(
          language: state.item(id)?.display ?? _describe(id),
          operation: operation,
          succeeded: failure == null,
          error: failure,
        ),
      ),
    );
  }

  /// Runs [action] for the pack [id]: the error it failed with, classified
  /// ([dictionaryPackError]; also sent to `addError` unless the network is
  /// metered), or null. A method of its own so that no nullable local is
  /// assigned in a `catch` and read in a closure (dart2js got that wrong).
  Future<OfflineModelError?> _attempt(
    String id,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return null;
    } on Object catch (error, stackTrace) {
      final failure = dictionaryPackError(
        error,
        catalogUrl: state.item(id)?.pack.url,
      );
      if (failure.kind != OfflineModelErrorKind.metered) {
        addError(error, stackTrace);
      }
      return failure;
    }
  }

  OfflineLanguage _display(DictionaryPackInfo pack) {
    final described = _describe(pack.language);
    return OfflineLanguage(
      code: pack.id,
      name: described.name == pack.language && pack.name.isNotEmpty
          ? pack.name
          : described.name,
      nativeName: described.nativeName,
    );
  }

  Future<void> _refreshInstalled() async {
    final installed = await _readInstalled();
    if (isClosed || _same(installed, state.installed)) return;
    emit(state.copyWith(installed: installed));
  }

  Future<Map<String, StoredDictionaryPack>> _readInstalled({
    bool throwing = false,
  }) async {
    try {
      return {for (final pack in await _packs.installed()) pack.id: pack};
    } on Object catch (error, stackTrace) {
      if (throwing) rethrow;
      addError(error, stackTrace);
      return state.installed;
    }
  }

  /// Emits download progress in whole percent steps only.
  void _reportProgress(String id, double fraction) {
    if (isClosed || !state.pending.containsKey(id)) return;
    final previous = state.progress[id];
    if (previous != null &&
        (previous * 100).floor() == (fraction * 100).floor()) {
      return;
    }
    emit(state.copyWith(progress: {...state.progress, id: fraction}));
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

/// [error] of a dictionary pack operation, classified for the user like
/// the offline models' ([OfflineModelError.of]); a download from another
/// host than [catalogUrl]'s names that mirror.
OfflineModelError dictionaryPackError(Object error, {Uri? catalogUrl}) {
  String? mirrorOf(Uri? url) {
    if (url == null || catalogUrl == null || url.host == catalogUrl.host) {
      return null;
    }
    return url.hasPort ? '${url.host}:${url.port}' : url.host;
  }

  return switch (error) {
    DictionaryPackMeteredException() => const OfflineModelError(
      OfflineModelErrorKind.metered,
    ),
    DictionaryPackChecksumException(:final url) => OfflineModelError(
      OfflineModelErrorKind.checksum,
      mirror: mirrorOf(url),
    ),
    DictionaryPackDownloadException(:final int statusCode, :final url) =>
      OfflineModelError(
        OfflineModelErrorKind.server,
        statusCode: statusCode,
        mirror: mirrorOf(url),
      ),
    DictionaryPackDownloadException(:final message, :final url) =>
      OfflineModelError(
        OfflineModelErrorKind.network,
        networkPolicy: NetworkPolicyError.of(message),
        mirror: mirrorOf(url),
      ),
    DictionaryPackUnsupportedException() => const OfflineModelError(
      OfflineModelErrorKind.unsupported,
    ),
    _ => OfflineModelError.of(error),
  };
}

bool _same(
  Map<String, StoredDictionaryPack> a,
  Map<String, StoredDictionaryPack> b,
) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
