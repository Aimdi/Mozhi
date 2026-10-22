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
  // Read-only query of the service; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  SyncState get current => _service.state;

  /// The ids of the sections this app can sync, in the registry's order.
  // Read-only query of the service; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  List<String> get sectionIds => _service.sectionIds;

  /// Syncs now; the failure, or null when it worked.
  // Returns the failure for the row or dialog to show; the state follows
  // the service.
  // ignore: prefer_void_public_cubit_methods
  Future<SyncFailure?> syncNow() => _service.syncNow();

  /// Unlocks sync with the server [password] and/or the [passphrase].
  // Returns the failure for the row or dialog to show; the state follows
  // the service.
  // ignore: prefer_void_public_cubit_methods
  Future<SyncFailure?> unlock({String? password, String? passphrase}) =>
      _failureOf(
        () => _service.unlock(password: password, passphrase: passphrase),
      );

  /// Re-encrypts the sync file with a new [passphrase].
  // Returns the failure for the row or dialog to show; the state follows
  // the service.
  // ignore: prefer_void_public_cubit_methods
  Future<SyncFailure?> changePassphrase(String passphrase) =>
      _failureOf(() => _service.changePassphrase(passphrase));

  /// Saves what to sync and when.
  Future<void> updateOptions(SyncConfig config) =>
      _service.updateOptions(config);

  /// Turns sync off, deleting the sync file too with [deleteRemote].
  // Returns the failure for the row or dialog to show; the state follows
  // the service.
  // ignore: prefer_void_public_cubit_methods
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
