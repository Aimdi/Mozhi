import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';

/// Whether the translate screen offers on-device AI
/// ([OnDeviceAiOfferCubit]).
enum OnDeviceAiOfferStatus {
  /// Not decided yet (nothing is shown).
  checking,

  /// The card is shown.
  shown,

  /// Never, or not now.
  hidden,
}

/// The state of [OnDeviceAiOfferCubit].
class OnDeviceAiOfferState extends Equatable {
  const new({
    this.status = OnDeviceAiOfferStatus.checking,
    this.smallestDownload,
  });

  final OnDeviceAiOfferStatus status;

  /// The download size in bytes of the smallest model that fits this
  /// phone, or null when the catalogue does not know it.
  final int? smallestDownload;

  bool get shown => status == OnDeviceAiOfferStatus.shown;

  @override
  List<Object?> get props => [status, smallestDownload];
}

/// The translate screen's one-time offer of on-device AI ("Translate and
/// explain with AI that stays on your phone"): [load] shows it when a model
/// of the catalogue fits this phone ([OnDeviceFit.ok] or
/// [OnDeviceFit.slow]), none is installed yet and the user has not put it
/// away. The screen also hides it while an AI provider exists.
///
/// * [notNow] hides it for [snooze] (stored, so it does not come back on
///   the next start);
/// * [never] ("Don't show again") and [opened] (the user went to see the
///   models) hide it for good.
///
/// It never downloads anything: the card only leads to the On-device AI
/// settings. What it stores (under [storeKey] in the preferences) goes
/// with "Delete all local data".
class OnDeviceAiOfferCubit extends Cubit<OnDeviceAiOfferState> {
  new({required this._models, required this._store, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      super(const OnDeviceAiOfferState());

  /// Preferences key: `never`, or the time (milliseconds since the epoch)
  /// until which the offer is snoozed.
  static const storeKey = 'translate.onDeviceAiOffer';

  /// How long [notNow] hides the offer.
  static const snooze = Duration(days: 30);

  static const _never = 'never';

  final OnDeviceModels _models;
  final KeyValueStore _store;
  final DateTime Function() _clock;
  StreamSubscription<void>? _changes;

  /// Decides whether to show the offer (see the class docs) and hides it
  /// as soon as a model is installed.
  Future<void> load() async {
    try {
      await _models.ready;
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await _changes?.cancel();
    _changes = _models.changes.listen((_) {
      if (!isClosed && state.shown && _installed) _hide();
    });
    final fitting = [
      for (final model in _models.catalog.models)
        if (_fits(_models.fitOf(model))) model,
    ];
    if (isClosed) return;
    if (_installed || fitting.isEmpty || await _putAway()) {
      if (!isClosed) _hide();
      return;
    }
    if (isClosed) return;
    emit(
      OnDeviceAiOfferState(
        status: OnDeviceAiOfferStatus.shown,
        smallestDownload: _smallest(fitting),
      ),
    );
  }

  /// "Not now": hidden for [snooze].
  Future<void> notNow() =>
      _putAwayUntil(_clock().add(snooze).millisecondsSinceEpoch.toString());

  /// "Don't show again".
  Future<void> never() => _putAwayUntil(_never);

  /// The user opened the On-device AI settings from the card: it has done
  /// its job.
  Future<void> opened() => _putAwayUntil(_never);

  bool get _installed =>
      _models.translationModel != null || _models.assistantModel != null;

  static bool _fits(OnDeviceFit fit) =>
      fit == OnDeviceFit.ok || fit == OnDeviceFit.slow;

  static int? _smallest(List<LlamaCatalogModel> models) {
    final sizes = [
      for (final model in models)
        if (model.size > 0) model.size,
    ];
    if (sizes.isEmpty) return null;
    return sizes.reduce((a, b) => a < b ? a : b);
  }

  /// Whether the user put the offer away (for good, or not yet back).
  Future<bool> _putAway() async {
    final String? value;
    try {
      value = await _store.read(storeKey);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      // Unknown: rather not nag.
      return true;
    }
    if (value == null) return false;
    if (value == _never) return true;
    final until = int.tryParse(value);
    return until == null || _clock().millisecondsSinceEpoch < until;
  }

  Future<void> _putAwayUntil(String value) async {
    _hide();
    try {
      await _store.write(storeKey, value);
    } on Object catch (error, stackTrace) {
      // Hidden for this run anyway.
      addError(error, stackTrace);
    }
  }

  void _hide() {
    if (isClosed) return;
    emit(const OnDeviceAiOfferState(status: OnDeviceAiOfferStatus.hidden));
  }

  @override
  Future<void> close() async {
    await _changes?.cancel();
    await super.close();
  }
}
