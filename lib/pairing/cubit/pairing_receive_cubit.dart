import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/cubit/pairing_receive_state.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_connection.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

export 'pairing_receive_state.dart';

/// **Receive on this phone**: listens on this phone's private address
/// with a fresh code ([start]), waits for the other phone, lets the user
/// compare the numbers ([confirm]), shows its offer, and receives and
/// installs what the user accepts ([accept]) once the numbers matched.
///
/// One connection per code; a new code ([start] again) or another address
/// ([useAddress]) starts over. Closing the cubit stops listening and any
/// transfer.
class PairingReceiveCubit extends Cubit<PairingReceiveState> {
  new(this._environment) : super(const PairingReceiveState());

  final PairingEnvironment _environment;
  PairingListener? _listener;
  PairingReceiver? _receiver;

  /// Bumped by every [start]: results of an older one are dropped.
  int _run = 0;

  /// Makes a new code and waits for a phone, on [address] when given
  /// (one of [PairingReceiveState.addresses]), else on the best one.
  Future<void> start({String? address}) async {
    final run = ++_run;
    await _stop();
    if (isClosed) return;
    emit(const PairingReceiveState());
    final addresses = await _environment.addresses();
    if (run != _run || isClosed) return;
    if (addresses.isEmpty) {
      emit(const PairingReceiveState(step: PairingReceiveStep.noNetwork));
      return;
    }
    final chosen = addresses.contains(address) ? address! : addresses.first;
    final PairingListener listener;
    try {
      listener = await _environment.listen(
        InternetAddress(chosen),
        _environment.codeValidity,
      );
    } on Object catch (error) {
      if (run == _run && !isClosed) _fail(PairingFailure.of(error));
      return;
    }
    if (run != _run || isClosed) {
      await listener.close();
      return;
    }
    _listener = listener;
    emit(
      PairingReceiveState(
        step: PairingReceiveStep.waiting,
        addresses: addresses,
        address: chosen,
        code: listener.code,
        expiresAt: listener.expiresAt,
      ),
    );
    unawaited(_waitForPhone(listener, run));
  }

  /// Listens on [address] instead, with a new code.
  Future<void> useAddress(String address) => start(address: address);

  /// Takes or leaves the offered item [id].
  void toggle(String id) {
    if (state.step != PairingReceiveStep.offer ||
        !state.available.any((offered) => offered.item.id == id)) {
      return;
    }
    final selected = {...state.selected};
    if (!selected.remove(id)) selected.add(id);
    emit(state.copyWith(selected: selected));
  }

  /// How the data item is restored.
  void setMode(BackupRestoreMode mode) => emit(state.copyWith(mode: mode));

  /// The user compared the numbers (while the other phone chooses, or
  /// with its offer): when they [match], the offer can be accepted; else
  /// the connection stops (someone may be in the middle, or another phone
  /// connected first).
  Future<void> confirm({required bool match}) async {
    final receiver = _receiver;
    if (receiver == null ||
        state.numbersConfirmed ||
        (state.step != PairingReceiveStep.connected &&
            state.step != PairingReceiveStep.offer)) {
      return;
    }
    if (match) {
      emit(state.copyWith(numbersConfirmed: true));
      return;
    }
    // What the connection still brings is dropped.
    _run++;
    _receiver = null;
    await receiver.cancel();
    if (!isClosed) _fail(PairingFailure.sasMismatch);
  }

  /// Receives and installs the selected items, once the numbers matched.
  Future<void> accept() async {
    final receiver = _receiver;
    if (receiver == null ||
        state.step != PairingReceiveStep.offer ||
        !state.numbersConfirmed) {
      return;
    }
    emit(
      state.copyWith(
        step: PairingReceiveStep.transferring,
        progress: PairingProgress(bytes: 0, totalBytes: state.selectedBytes),
      ),
    );
    await _environment.keepScreenOn(enabled: true);
    try {
      final results = await receiver.accept(
        state.selected,
        mode: state.mode,
        onProgress: _onProgress,
      );
      if (!isClosed) {
        emit(state.copyWith(step: PairingReceiveStep.done, results: results));
      }
    } on Object catch (error) {
      if (!isClosed) _fail(PairingFailure.of(error));
    } finally {
      _receiver = null;
      await _environment.keepScreenOn(enabled: false);
    }
  }

  /// Says no to the offer.
  Future<void> decline() async {
    final receiver = _receiver;
    if (receiver == null || state.step != PairingReceiveStep.offer) return;
    _receiver = null;
    try {
      await receiver.decline();
    } on Object {
      // The other phone learns it either way: the connection closes.
      await receiver.close();
    }
    if (!isClosed) emit(state.copyWith(step: PairingReceiveStep.declined));
  }

  @override
  Future<void> close() async {
    _run++;
    await _stop();
    await super.close();
  }

  Future<void> _waitForPhone(PairingListener listener, int run) async {
    final PairingChannel channel;
    try {
      channel = await listener.connection;
    } on PairingExpiredException catch (error) {
      if (run != _run || isClosed) return;
      if (error.tooManyAttempts) {
        _fail(PairingFailure.of(error));
      } else {
        emit(state.copyWith(step: PairingReceiveStep.expired));
      }
      return;
    } on Object {
      // Closed for a new code, or the page closed.
      return;
    }
    if (run != _run || isClosed) {
      channel.destroy();
      return;
    }
    final receiver = PairingReceiver(
      channel,
      _environment.library,
      workDirectory: await _environment.workDirectory(),
      timeouts: _environment.timeouts,
    );
    if (run != _run || isClosed) {
      channel.destroy();
      return;
    }
    _receiver = receiver;
    emit(state.copyWith(step: PairingReceiveStep.connected, sas: channel.sas));
    try {
      final offered = await receiver.offer();
      if (run != _run || isClosed) return;
      emit(
        state.copyWith(
          step: PairingReceiveStep.offer,
          offered: offered,
          selected: {
            for (final item in offered)
              if (item.plan.status == PairingItemStatus.available) item.item.id,
          },
        ),
      );
    } on Object catch (error) {
      if (run == _run && !isClosed) _fail(PairingFailure.of(error));
    }
  }

  void _onProgress(PairingProgress progress) {
    if (isClosed) return;
    final last = state.progress;
    if (last != null &&
        last.installing == progress.installing &&
        last.itemId == progress.itemId &&
        (last.fraction * 100).floor() == (progress.fraction * 100).floor()) {
      return;
    }
    emit(state.copyWith(progress: progress));
  }

  void _fail(PairingFailure failure) {
    _receiver = null;
    emit(state.copyWith(step: PairingReceiveStep.failed, failure: failure));
  }

  Future<void> _stop() async {
    final listener = _listener;
    final receiver = _receiver;
    _listener = null;
    _receiver = null;
    await listener?.close();
    if (receiver != null) await receiver.cancel();
  }
}
