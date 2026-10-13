import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:translation_repository/translation_repository.dart';

class ConversationState extends Equatable {
  const ConversationState({
    required this.languageA,
    required this.languageB,
    this.turns = const [],
    this.autoSpeak = false,
    this.faceToFace = false,
    this.speakingTurnId,
    this.speechFailures = 0,
  });

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
  ];
}
