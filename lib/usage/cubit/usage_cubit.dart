import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/usage/cubit/usage_state.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/models.dart';

export 'usage_state.dart';

/// Exposes a [UsageTracker] to the UI and follows its changes.
class UsageCubit extends Cubit<UsageState> {
  new(this._tracker)
    : super(UsageState(snapshot: _tracker.snapshot)) {
    _subscription = _tracker.changes.listen(
      (snapshot) =>
          emit(state.copyWith(status: UsageStatus.ready, snapshot: snapshot)),
    );
  }

  final UsageTracker _tracker;
  late final StreamSubscription<UsageSnapshot> _subscription;

  /// Loads the stored usage.
  Future<void> load() async {
    emit(state.copyWith(status: UsageStatus.loading));
    try {
      final snapshot = await _tracker.load();
      if (isClosed) return;
      emit(state.copyWith(status: UsageStatus.ready, snapshot: snapshot));
    } on Object catch (error, stackTrace) {
      if (isClosed) return;
      addError(error, stackTrace);
      emit(state.copyWith(status: UsageStatus.failure));
    }
  }

  /// Sets the monthly character budget of [providerId]; null removes it.
  Future<void> setBudget(String providerId, int? monthlyChars) =>
      _guard(
        () => _tracker.setBudget(
          providerId,
          monthlyChars == null || monthlyChars <= 0
              ? null
              : UsageBudget(
                  monthlyChars: monthlyChars,
                  warningThreshold:
                      _tracker.snapshot.budgetFor(providerId)?.warningThreshold ??
                      UsageBudget.defaultWarningThreshold,
                ),
        ),
      );

  /// Deletes the usage counters of [providerId], or of all providers.
  Future<void> reset({String? providerId}) =>
      _guard(() => _tracker.reset(providerId: providerId));

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      // The tracker already updated its in-memory counters; only persisting
      // failed, which the next successful write repairs.
      addError(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
