import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/voice/speech_input_state.dart' show SpeechInputFailure;

/// Where a hands-free conversation is: the large microphone starts it
/// (`ConversationCubit.toggleSession`), and from then on the two sides
/// take turns without touching the phone.
///
/// ```text
/// idle ─tap─► listening(A) ─heard─► translating ─► speaking ─► listening(B)
///               │                     │              │
///               │ silence, taken over │ consent,     │ consent to
///               │                     │ failure      │ read online
///               ▼                     ▼              ▼
///             paused ◄────────────────┴──────────────┘ ─tap─► listening
///             failed (voice input error)               ─tap─► listening
///
/// running (listening, translating, speaking) ─tap, background, tab─► idle
/// ```
///
/// * [ConversationSessionListening]: the microphone is open (or opening)
///   for one side, in its language.
/// * [ConversationSessionTranslating]: what was heard is a new turn of
///   the transcript and is being translated.
/// * [ConversationSessionSpeaking]: the translation is read aloud; the
///   microphone stays closed until it ends, so the app never hears itself.
/// * [ConversationSessionPaused] and [ConversationSessionFailed]: the
///   microphone is closed; tapping it continues with their `next` side.
sealed class ConversationSession extends Equatable {
  const new();

  /// No session.
  static const ConversationSession idle = ConversationSessionIdle();

  /// Listening, translating or speaking: tapping the microphone stops it.
  bool get isRunning => false;

  /// Started and not stopped: running, paused or failed.
  bool get isActive => isRunning;

  /// The side whose turn it is: the one listened for (or listened for
  /// next), or the speaker of the message being translated; null while
  /// idle.
  ConversationSide? get side => null;
}

/// No hands-free conversation.
final class ConversationSessionIdle extends ConversationSession {
  const new();

  @override
  List<Object?> get props => [];
}

/// What the microphone of [ConversationSessionListening] is doing.
enum ConversationListenStage {
  /// The recogniser is starting (it may ask for the microphone
  /// permission), or waits for the end of a translation read aloud.
  starting,

  /// The microphone is open.
  listening,

  /// The microphone closed and an on-device recogniser transcribes what
  /// was said.
  transcribing,
}

/// Listening for [side] in its language. With [detectsLanguage] the
/// recogniser detects which of the two languages is spoken, so either side
/// may speak; [heard] is what was recognised so far.
final class ConversationSessionListening extends ConversationSession {
  const new({
    required this.side,
    this.stage = ConversationListenStage.starting,
    this.detectsLanguage = false,
    this.heard = '',
  });

  @override
  final ConversationSide side;
  final ConversationListenStage stage;
  final bool detectsLanguage;
  final String heard;

  @override
  bool get isRunning => true;

  ConversationSessionListening copyWith({
    ConversationListenStage? stage,
    bool? detectsLanguage,
    String? heard,
  }) => ConversationSessionListening(
    side: side,
    stage: stage ?? this.stage,
    detectsLanguage: detectsLanguage ?? this.detectsLanguage,
    heard: heard ?? this.heard,
  );

  @override
  List<Object?> get props => [side, stage, detectsLanguage, heard];
}

/// Translating turn [turnId], said by [speaker]; then [next] is listened
/// for (the other side, unless the turn was switched).
final class ConversationSessionTranslating extends ConversationSession {
  const new({required this.turnId, required this.speaker, required this.next});

  final int turnId;
  final ConversationSide speaker;
  final ConversationSide next;

  @override
  bool get isRunning => true;

  @override
  ConversationSide get side => speaker;

  @override
  List<Object?> get props => [turnId, speaker, next];
}

/// Reading turn [turnId]'s translation aloud (null: something else is read
/// aloud, e.g. a message's listen button); then [next] is listened for.
final class ConversationSessionSpeaking extends ConversationSession {
  const new({required this.next, this.turnId});

  final int? turnId;
  final ConversationSide next;

  @override
  bool get isRunning => true;

  @override
  ConversationSide get side => next;

  @override
  List<Object?> get props => [turnId, next];
}

/// Why a hands-free conversation paused ([ConversationSessionPaused]).
enum ConversationPauseReason {
  /// Nobody spoke for a while (`ConversationCubit` `silenceTimeout`).
  silence,

  /// Something else took the microphone over.
  interrupted,

  /// Turn [ConversationSessionPaused.turnId] needs consent before it may
  /// be sent to the translation service (asked inline in its bubble).
  consent,

  /// Turn [ConversationSessionPaused.turnId] may only be read aloud online
  /// with consent (offered by the read-aloud error).
  speechConsent,

  /// Turn [ConversationSessionPaused.turnId] could not be translated.
  translationFailed,
}

/// Paused for [reason]: the microphone is closed; continuing listens for
/// [next]. [turnId] is the turn the reason is about, if any.
final class ConversationSessionPaused extends ConversationSession {
  const new({required this.next, required this.reason, this.turnId});

  final ConversationSide next;
  final ConversationPauseReason reason;
  final int? turnId;

  @override
  bool get isActive => true;

  @override
  ConversationSide get side => next;

  @override
  List<Object?> get props => [next, reason, turnId];
}

/// Voice input failed with [failure] (no permission, no recogniser or
/// model, ...): the microphone is closed; trying again listens for
/// [next]. [onDevice] and [offlineSupported] select the explanation (see
/// `showVoiceInputErrorSnackBar`).
final class ConversationSessionFailed extends ConversationSession {
  const new({
    required this.next,
    required this.failure,
    this.onDevice = false,
    this.offlineSupported = false,
  });

  final ConversationSide next;
  final SpeechInputFailure failure;
  final bool onDevice;
  final bool offlineSupported;

  @override
  bool get isActive => true;

  @override
  ConversationSide get side => next;

  @override
  List<Object?> get props => [next, failure, onDevice, offlineSupported];
}
