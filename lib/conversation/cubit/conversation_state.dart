import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/cubit/conversation_session.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:translation_repository/translation_repository.dart';

export 'conversation_session.dart';

class ConversationState extends Equatable {
  const new({
    required this.languageA,
    required this.languageB,
    this.turns = const [],
    this.autoSpeak = false,
    this.faceToFace = false,
    this.speakingTurnId,
    this.speechFailures = 0,
    this.lastSpeechFailure,
    this.handsFree = false,
    this.session = ConversationSession.idle,
    this.detectSpeaker = true,
    this.turnPause = defaultTurnPause,
  });

  /// The silence that ends a turn of a hands-free conversation with
  /// offline speech ([turnPause] by default).
  static const defaultTurnPause = Duration(milliseconds: 800);

  /// The shortest and longest [turnPause] the user can choose.
  static const minTurnPause = Duration(milliseconds: 500);
  static const maxTurnPause = Duration(seconds: 2);

  /// Language spoken by [ConversationSide.a] (the phone's owner).
  final Language languageA;

  /// Language spoken by [ConversationSide.b] (the other person).
  final Language languageB;

  /// Oldest first.
  final List<ConversationTurn> turns;

  /// Read each completed translation aloud for the other side.
  final bool autoSpeak;

  /// Split screen with side B's half upside down, so two people facing
  /// each other can share the device.
  final bool faceToFace;

  /// Turn whose translation is being read aloud, if any.
  final int? speakingTurnId;

  /// Incremented whenever reading a translation aloud fails (auto-speak
  /// included), so the UI can report it.
  final int speechFailures;

  /// The last failed read-aloud: which turn, how, what went wrong
  /// (`SpeechService` errors), and whether the user had already allowed a
  /// Mozhi instance to read it (`asked`: then nothing more is offered).
  final ConversationSpeechFailure? lastSpeechFailure;

  /// Whether a hands-free conversation can be started ([session]): a speech
  /// recogniser is available.
  final bool handsFree;

  /// The hands-free conversation (see [ConversationSession]).
  final ConversationSession session;

  /// "Detect the speaker": with a recogniser that detects the spoken
  /// language (offline Whisper), the side whose language was heard takes
  /// the turn; off, whoever's turn it is speaks in their own language.
  final bool detectSpeaker;

  /// How much silence ends a turn of a hands-free conversation, with a
  /// recogniser that tells speech from silence itself (offline Whisper);
  /// the system recogniser keeps its own.
  final Duration turnPause;

  /// Language spoken by [side].
  Language languageOf(ConversationSide side) =>
      side == ConversationSide.a ? languageA : languageB;

  bool get isEmpty => turns.isEmpty;
  bool get isTranslating => turns.any((turn) => turn.isTranslating);

  ConversationTurn? turnById(int id) {
    for (final turn in turns) {
      if (turn.id == id) return turn;
    }
    return null;
  }

  ConversationState copyWith({
    Language? languageA,
    Language? languageB,
    List<ConversationTurn>? turns,
    bool? autoSpeak,
    bool? faceToFace,
    int? Function()? speakingTurnId,
    int? speechFailures,
    ConversationSpeechFailure? lastSpeechFailure,
    ConversationSession? session,
    bool? detectSpeaker,
    Duration? turnPause,
  }) => ConversationState(
    languageA: languageA ?? this.languageA,
    languageB: languageB ?? this.languageB,
    turns: turns ?? this.turns,
    autoSpeak: autoSpeak ?? this.autoSpeak,
    faceToFace: faceToFace ?? this.faceToFace,
    speakingTurnId: speakingTurnId != null
        ? speakingTurnId()
        : this.speakingTurnId,
    speechFailures: speechFailures ?? this.speechFailures,
    lastSpeechFailure: lastSpeechFailure ?? this.lastSpeechFailure,
    handsFree: handsFree,
    session: session ?? this.session,
    detectSpeaker: detectSpeaker ?? this.detectSpeaker,
    turnPause: turnPause ?? this.turnPause,
  );

  @override
  List<Object?> get props => [
    languageA,
    languageB,
    turns,
    autoSpeak,
    faceToFace,
    speakingTurnId,
    speechFailures,
    lastSpeechFailure,
    handsFree,
    session,
    detectSpeaker,
    turnPause,
  ];
}

/// See [ConversationState.lastSpeechFailure].
typedef ConversationSpeechFailure = ({
  int turnId,
  bool slow,
  Object error,
  bool asked,
});
