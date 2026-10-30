import 'package:equatable/equatable.dart';
import 'package:mozhi/voice/speech_input_state.dart' show SpeechInputFailure;
import 'package:translation_repository/translation_repository.dart';

/// What a hands-free conversation hears while it listens for one utterance
/// ([ConversationRecognizer.listen]).
///
/// An utterance ends with exactly one of [ConversationHeardFinal],
/// [ConversationHeardFailure] or [ConversationHeardEnd], after which its
/// stream closes.
sealed class ConversationHearing extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// The microphone is open. [detectsLanguage]: the recogniser detects which
/// language is spoken (the final result says which).
final class ConversationHeardStart extends ConversationHearing {
  const new({this.detectsLanguage = false});

  final bool detectsLanguage;

  @override
  List<Object?> get props => [detectsLanguage];
}

/// The input loudness, normalised to `0..1`. Loudness alone is not speech
/// (background noise is loud too): see [ConversationHeardSpeech].
final class ConversationHeardLevel extends ConversationHearing {
  const new(this.level);

  final double level;

  @override
  List<Object?> get props => [level];
}

/// Someone is speaking: the recogniser recognised words, or its own voice
/// activity detection heard speech (on-device recognisers, which only
/// recognise words after recording). Reported once per utterance.
final class ConversationHeardSpeech extends ConversationHearing {
  const new();
}

/// The words recognised so far (the whole utterance, not just new words).
final class ConversationHeardPartial extends ConversationHearing {
  const new(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// The microphone closed and the recording is being transcribed (on-device
/// recognisers); the final result follows.
final class ConversationHeardTranscribing extends ConversationHearing {
  const new();
}

/// The utterance: [text] and, when the recogniser detected it, the app
/// (BCP-47) code of its [language].
final class ConversationHeardFinal extends ConversationHearing {
  const new(this.text, {this.language});

  final String text;
  final String? language;

  @override
  List<Object?> get props => [text, language];
}

/// Listening failed: [failure] (silence is [SpeechInputFailure.noMatch]).
///
/// [onDevice] and [offlineSupported] are what the voice input error
/// messages need (`showVoiceInputErrorSnackBar`).
final class ConversationHeardFailure extends ConversationHearing {
  const new(
    this.failure, {
    this.onDevice = false,
    this.offlineSupported = false,
  });

  final SpeechInputFailure failure;
  final bool onDevice;
  final bool offlineSupported;

  @override
  List<Object?> get props => [failure, onDevice, offlineSupported];
}

/// The utterance ended without a result. [interrupted]: something else
/// took the microphone over (another voice input button).
final class ConversationHeardEnd extends ConversationHearing {
  const new({this.interrupted = false});

  final bool interrupted;

  @override
  List<Object?> get props => [interrupted];
}

/// The speech recogniser of a hands-free conversation, one utterance at a
/// time. `SpeechInputConversationRecognizer` is the app's, over the
/// app-wide `SpeechInputService`.
abstract interface class ConversationRecognizer {
  /// Opens the microphone and listens for one utterance in [language]; the
  /// returned stream reports what is heard (see [ConversationHearing]) and
  /// closes when the utterance ends. With [detectLanguage] a recogniser
  /// that can (on-device Whisper) detects the spoken language instead.
  /// [pause] is the silence after speech that ends the utterance (null:
  /// the recogniser's default): on-device Whisper measures it with its
  /// voice activity detection, the system recogniser stops once no new
  /// words came for that long.
  ///
  /// Listening again cancels the previous utterance.
  Stream<ConversationHearing> listen(
    Language language, {
    bool detectLanguage = false,
    Duration? pause,
  });

  /// Closes the microphone and drops the current utterance (its stream
  /// closes without further events). Does nothing when not listening.
  Future<void> cancel();

  /// Cancels and releases the recogniser; it cannot be used afterwards.
  Future<void> dispose();
}
