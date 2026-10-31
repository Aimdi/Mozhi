import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/pairing/cubit/pairing_send_state.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';

export 'pairing_send_state.dart';

/// **Send to another phone**: connects with the other phone's code
/// ([connect]), lets the user compare the numbers ([confirm]) and choose
/// what to send, offers it and sends what the other phone accepts
/// ([send]).
///
/// The initial code (from a `mozhi://pair` link) only fills in the code:
/// nothing connects until the user taps Connect. Closing the cubit stops
/// any transfer.
class PairingSendCubit extends Cubit<PairingSendState> {
  new(
    this._environment, {
    String? initialCode,
    this._purpose = PairingSendPurpose.everything,
  }) : super(PairingSendState(input: initialCode?.trim() ?? ''));

  final PairingEnvironment _environment;

  /// What is selected at first.
  final PairingSendPurpose _purpose;
  PairingSender? _sender;

  /// Completed to stop the [connect] under way.
  Completer<void>? _connecting;

  /// The code as the user types it.
  void setInput(String input) =>
      emit(state.copyWith(input: input, invalidCode: false));

  /// Connects to the phone of the typed code.
  Future<void> connect() async {
    if (state.step != PairingSendStep.enterCode) return;
    final code = PairingCode.tryParse(state.input);
    if (code == null) {
      emit(state.copyWith(invalidCode: true));
      return;
    }
    emit(state.copyWith(step: PairingSendStep.connecting));
    final cancel = _connecting = Completer<void>();
    final PairingChannel channel;
    try {
      channel = await _environment.connect(code, cancel: cancel.future);
    } on Object catch (error) {
      if (!isClosed && !cancel.isCompleted) {
        _fail(PairingFailure.of(error, connecting: true));
      }
      return;
    } finally {
      if (identical(_connecting, cancel)) _connecting = null;
    }
    if (isClosed || cancel.isCompleted) {
      channel.destroy();
      return;
    }
    _sender = PairingSender(channel, timeouts: _environment.timeouts);
    emit(state.copyWith(step: PairingSendStep.confirm, sas: channel.sas));
  }

  /// Stops [connect] (it tries again for as long as the code works when
  /// the other phone is busy) and goes back to the code.
  void cancelConnect() {
    final cancel = _connecting;
    if (cancel == null || state.step != PairingSendStep.connecting) return;
    _connecting = null;
    cancel.complete();
    emit(PairingSendState(input: state.input));
  }

  /// The user compared the numbers: when they [match], lists what can be
  /// sent; else stops (someone may be in the middle).
  Future<void> confirm({required bool match}) async {
    final sender = _sender;
    if (sender == null || state.step != PairingSendStep.confirm) return;
    if (!match) {
      _sender = null;
      await sender.cancel();
      if (!isClosed) _fail(PairingFailure.sasMismatch);
      return;
    }
    emit(state.copyWith(step: PairingSendStep.choose, loading: true));
    final library = _environment.library;
    final packs = await library.outgoingPacks();
    final sections = <String>[
      for (final section in library.backup?.sections ?? const <Never>[])
        section.id,
    ];
    if (isClosed) return;
    emit(
      state.copyWith(
        loading: false,
        packs: packs,
        sections: sections,
        chosenSections: sections.toSet(),
        selected: switch (_purpose) {
          PairingSendPurpose.packs => {
            for (final outgoing in packs) outgoing.item.id,
          },
          PairingSendPurpose.everything => {
            if (sections.isNotEmpty) PairingBackupItem.id,
          },
        },
      ),
    );
  }

  /// Sends or leaves the item [id] ([PairingBackupItem.id] for the data).
  void toggle(String id) {
    final selected = {...state.selected};
    if (!selected.remove(id)) selected.add(id);
    emit(state.copyWith(selected: selected));
  }

  /// Sends or leaves the backup section [id].
  void toggleSection(String id) {
    final chosen = {...state.chosenSections};
    if (!chosen.remove(id)) chosen.add(id);
    emit(state.copyWith(chosenSections: chosen));
  }

  /// Whether the data includes API keys and passwords.
  void setIncludeSecrets({required bool include}) =>
      emit(state.copyWith(includeSecrets: include));

  /// Offers the selection and sends what the other phone accepts.
  Future<void> send() async {
    final sender = _sender;
    if (sender == null ||
        state.step != PairingSendStep.choose ||
        state.loading ||
        !state.canSend) {
      return;
    }
    emit(state.copyWith(step: PairingSendStep.waiting));
    try {
      final items = [
        if (state.sendsData)
          await PairingBackupItem.outgoing(
            _environment.library.backup!,
            sections: state.chosenSections,
            includeSecrets: state.includeSecrets,
          ),
        for (final outgoing in state.packs)
          if (state.selected.contains(outgoing.item.id)) outgoing,
      ];
      final requested = await sender.offer(items);
      if (isClosed) return;
      final wanted = {for (final request in requested) request.item.id};
      final total = requested.fold(
        0,
        (sum, request) =>
            sum + request.files.fold(0, (sum, file) => sum + file.size),
      );
      emit(
        state.copyWith(
          step: PairingSendStep.transferring,
          progress: PairingProgress(bytes: 0, totalBytes: total),
          skipped: [
            for (final outgoing in items)
              if (!wanted.contains(outgoing.item.id)) outgoing.item.id,
          ],
        ),
      );
      await _environment.keepScreenOn(enabled: true);
      final results = await sender.send(requested, onProgress: _onProgress);
      if (!isClosed) {
        emit(state.copyWith(step: PairingSendStep.done, results: results));
      }
    } on Object catch (error) {
      if (!isClosed) _fail(PairingFailure.of(error));
    } finally {
      _sender = null;
      await _environment.keepScreenOn(enabled: false);
    }
  }

  /// Back to the code, after a failure.
  void retry() {
    if (state.step != PairingSendStep.failed) return;
    emit(PairingSendState(input: state.input));
  }

  @override
  Future<void> close() async {
    final connecting = _connecting;
    _connecting = null;
    if (connecting != null && !connecting.isCompleted) connecting.complete();
    final sender = _sender;
    _sender = null;
    if (sender != null) await sender.cancel();
    await super.close();
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
    _sender = null;
    emit(state.copyWith(step: PairingSendStep.failed, failure: failure));
  }
}
