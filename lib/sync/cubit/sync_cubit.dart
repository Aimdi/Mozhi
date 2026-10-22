import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// The sync settings' view of the [SyncService]: its [SyncState] as it
/// changes, and the actions of the settings rows. Actions return their
/// failure (null when they worked) for the row or dialog to show.
class SyncCubit extends Cubit<SyncState> {
  new(this._service) : super(_service.state) {
    _subscription = _service.states.listen(emit);
    unawaited(_service.load());
  }

  final SyncService _service;
  late final StreamSubscription<SyncState> _subscription;

  /// The service's state now ([state] follows it a moment later).
  SyncState get current => _service.state;

  /// The ids of the sections this app can sync, in the registry's order.
  List<String> get sectionIds => _service.sectionIds;

  Future<SyncFailure?> syncNow() => _service.syncNow();

  Future<SyncFailure?> unlock({String? password, String? passphrase}) =>
      _failureOf(
        () => _service.unlock(password: password, passphrase: passphrase),
      );

  Future<SyncFailure?> changePassphrase(String passphrase) =>
      _failureOf(() => _service.changePassphrase(passphrase));

  Future<void> updateOptions(SyncConfig config) =>
      _service.updateOptions(config);

  Future<SyncFailure?> turnOff({bool deleteRemote = false}) =>
      _failureOf(() => _service.turnOff(deleteRemote: deleteRemote));

  static Future<SyncFailure?> _failureOf(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on SyncException catch (error) {
      return error.failure;
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
