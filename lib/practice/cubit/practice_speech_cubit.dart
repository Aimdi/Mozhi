import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/practice/data/practice_speech.dart';

/// Where speaking practice is.
enum PracticeSpeechStatus {
  /// Finding out whether it can run.
  checking,

  /// It cannot run here ([PracticeSpeechAvailability.unsupported]).
  unsupported,

  /// No speech model: one can be downloaded in the voice settings.
  modelMissing,

  /// Ready to listen.
  idle,

  /// The microphone is open.
  listening,

  /// Recording ended; transcribing on the device.
  transcribing,

  /// What was heard, compared with the phrase ([PracticeSpeechState.check]).
  heard,

  /// Listening failed ([PracticeSpeechState.failure]).
  failed,
}

final class PracticeSpeechState extends Equatable {
  const new({
    this.status = PracticeSpeechStatus.checking,
    this.level = 0,
    this.check,
    this.failure,
  });

  final PracticeSpeechStatus status;

  /// The loudness while listening, 0 to 1.
  final double level;

  /// What was heard compared with the expected phrase.
  final AnswerCheck? check;
  final PracticeSpeechFailure? failure;

  /// Whether speaking practice is offered (it can run, a model or not).
  bool get isOffered =>
      status != PracticeSpeechStatus.checking &&
      status != PracticeSpeechStatus.unsupported;

  /// Whether the microphone can be used now.
  bool get canListen =>
      status == PracticeSpeechStatus.idle ||
      status == PracticeSpeechStatus.heard ||
      status == PracticeSpeechStatus.failed;

  @override
  List<Object?> get props => [status, level, check, failure];
}

/// Speaking practice on a produce card: [listen] records the user saying
/// the phrase (on this device: [PracticeRecognizer]), [stop] ends the
/// recording, and what was heard is compared with the expected text
/// ([checkAnswer]). The comparison suggests a rating; the user rates. The
/// recording is never stored.
class PracticeSpeechCubit extends Cubit<PracticeSpeechState> {
  new({required this._recognizer}) : super(const PracticeSpeechState());

  final PracticeRecognizer _recognizer;

  /// Bumped by every [listen] and [reset]: older results are dropped.
  int _session = 0;

  /// Whether it can listen in the language [code].
  bool supportsLanguage(String code) => _recognizer.supportsLanguage(code);

  /// Finds out whether speaking practice can run (again after the voice
  /// settings may have changed).
  Future<void> load() async {
    final availability = await _recognizer.availability();
    if (isClosed) return;
    emit(
      PracticeSpeechState(
        status: switch (availability) {
          PracticeSpeechAvailability.unsupported =>
            PracticeSpeechStatus.unsupported,
          PracticeSpeechAvailability.modelMissing =>
            PracticeSpeechStatus.modelMissing,
          PracticeSpeechAvailability.ready => PracticeSpeechStatus.idle,
        },
      ),
    );
  }

  /// Listens to the user saying [expected] in the language [code] until
  /// [stop], then compares.
  Future<void> listen({required String expected, required String code}) async {
    if (!state.canListen) return;
    final session = ++_session;
    emit(const PracticeSpeechState(status: PracticeSpeechStatus.listening));
    try {
      final heard = await _recognizer.listen(
        code,
        onLevel: (level) {
          if (session == _session &&
              !isClosed &&
              state.status == PracticeSpeechStatus.listening) {
            emit(
              PracticeSpeechState(
                status: PracticeSpeechStatus.listening,
                level: level,
              ),
            );
          }
        },
        onTranscribing: () {
          if (session == _session && !isClosed) {
            emit(
              const PracticeSpeechState(
                status: PracticeSpeechStatus.transcribing,
              ),
            );
          }
        },
      );
      if (session != _session || isClosed) return;
      emit(
        PracticeSpeechState(
          status: PracticeSpeechStatus.heard,
          check: checkAnswer(
            expected: expected,
            answer: heard,
            languageCode: code,
          ),
        ),
      );
    } on PracticeSpeechException catch (error) {
      if (session != _session || isClosed) return;
      if (error.failure == PracticeSpeechFailure.cancelled) {
        emit(const PracticeSpeechState(status: PracticeSpeechStatus.idle));
        return;
      }
      emit(
        PracticeSpeechState(
          status: error.failure == PracticeSpeechFailure.modelMissing
              ? PracticeSpeechStatus.modelMissing
              : PracticeSpeechStatus.failed,
          failure: error.failure,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (session != _session || isClosed) return;
      emit(
        const PracticeSpeechState(
          status: PracticeSpeechStatus.failed,
          failure: PracticeSpeechFailure.engine,
        ),
      );
      addError(error, stackTrace);
    }
  }

  /// Ends the recording; the comparison follows.
  Future<void> stop() async {
    if (state.status != PracticeSpeechStatus.listening) return;
    emit(const PracticeSpeechState(status: PracticeSpeechStatus.transcribing));
    await _recognizer.stop();
  }

  /// Drops a recording and what was heard (the next card).
  Future<void> reset() async {
    _session++;
    final busy =
        state.status == PracticeSpeechStatus.listening ||
        state.status == PracticeSpeechStatus.transcribing;
    if (state.isOffered &&
        state.status != PracticeSpeechStatus.modelMissing &&
        !isClosed) {
      emit(const PracticeSpeechState(status: PracticeSpeechStatus.idle));
    }
    if (busy) await _recognizer.cancel();
  }

  @override
  Future<void> close() async {
    _session++;
    await _recognizer.dispose();
    await super.close();
  }
}
