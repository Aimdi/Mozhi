import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// Where the sync setup is.
enum SyncSetupStep {
  /// The connection fields are being filled in (or changed since the
  /// last test).
  editing,

  /// The connection test runs.
  testing,

  /// The connection works ([SyncSetupState.probe]): passphrase and
  /// options next.
  tested,

  /// The first sync runs.
  turningOn,

  /// Sync is on.
  done,
}

class SyncSetupState extends Equatable {
  const new({
    this.step = SyncSetupStep.editing,
    this.probe,
    this.failure,
    this.cause,
  });

  final SyncSetupStep step;

  /// What the last successful connection test found.
  final SyncProbe? probe;

  /// Why the last test or the first sync failed.
  final SyncFailure? failure;

  /// The error behind a [SyncFailure.policy].
  final Object? cause;

  bool get busy =>
      step == SyncSetupStep.testing || step == SyncSetupStep.turningOn;

  @override
  List<Object?> get props => [step, probe, failure, cause];
}

/// The sync setup: the connection test ([test]), then the first sync
/// with the passphrase and options ([turnOn]). Changing the connection
/// fields ([edited]) asks for a new test.
class SyncSetupCubit extends Cubit<SyncSetupState> {
  new(this._service) : super(const SyncSetupState());

  final SyncService _service;
  SyncConnection? _tested;

  /// The ids of the sections this app can sync.
  List<String> get sectionIds => _service.sectionIds;

  /// Tests [connection] ([SyncService.probe]).
  Future<void> test(SyncConnection connection) async {
    emit(const SyncSetupState(step: SyncSetupStep.testing));
    try {
      final probe = await _service.probe(connection);
      _tested = connection;
      emit(SyncSetupState(step: SyncSetupStep.tested, probe: probe));
    } on SyncException catch (error) {
      _tested = null;
      emit(SyncSetupState(failure: error.failure, cause: error.cause));
    }
  }

  /// The connection fields changed: the last test no longer applies.
  void edited(SyncConnection connection) {
    if (connection == _tested || state.busy) return;
    if (state.step == SyncSetupStep.editing && state.failure == null) return;
    _tested = null;
    emit(const SyncSetupState());
  }

  /// Turns sync on with the tested connection, [passphrase] and
  /// [options] ([SyncService.setUp]).
  Future<void> turnOn({
    required String passphrase,
    required SyncConfig options,
  }) async {
    final connection = _tested;
    final probe = state.probe;
    if (connection == null || probe == null) return;
    emit(SyncSetupState(step: SyncSetupStep.turningOn, probe: probe));
    try {
      await _service.setUp(
        connection: connection,
        passphrase: passphrase,
        config: options,
        probed: probe,
      );
      emit(SyncSetupState(step: SyncSetupStep.done, probe: probe));
    } on SyncException catch (error) {
      emit(
        SyncSetupState(
          step: SyncSetupStep.tested,
          probe: probe,
          failure: error.failure,
          cause: error.cause,
        ),
      );
    }
  }
}
