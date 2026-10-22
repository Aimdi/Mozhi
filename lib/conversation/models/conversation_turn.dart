import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The two people taking part in a conversation.
///
/// Side [a] is the person holding the phone (bottom half in face-to-face
/// mode), side [b] the person across the table (top half, upside down).
enum ConversationSide {
  a,
  b;

  /// The side this one is talking to.
  ConversationSide get other => this == a ? b : a;
}

/// Progress of one turn's translation.
enum ConversationTurnStatus {
  /// The translation is being fetched (AI engines stream it in).
  translating,

  /// The translation is complete.
  complete,

  /// The translation failed; see [ConversationTurn.error].
  failed,
}

/// One message of the conversation: what [side] said ([original], in
/// [source]) and its [translation] into [target] for the other side.
class ConversationTurn extends Equatable {
  const new({
    required this.id,
    required this.side,
    required this.original,
    required this.source,
    required this.target,
    required this.createdAt,
    this.translation = '',
    this.engineId,
    this.engineName,
    this.status = ConversationTurnStatus.translating,
    this.error,
    this.guest,
  });

  /// Unique within a conversation; increases with every turn.
  final int id;
  final ConversationSide side;
  final String original;
  final Language source;
  final Language target;

  /// Grows while an AI engine streams; final once [status] is complete.
  final String translation;

  /// Engine that produced (or is producing) [translation]; null when no
  /// engine was available.
  final String? engineId;
  final String? engineName;

  /// When the turn was sent.
  final DateTime createdAt;
  final ConversationTurnStatus status;

  /// Translation error (`MozhiApiException`, `LlmApiException`, ...) when
  /// [status] is [ConversationTurnStatus.failed].
  final Object? error;

  /// The number of the guest who wrote this turn in a conversation shared
  /// on the local network ("Guest 2", see `ConversationShareCubit`); null
  /// for what was said or typed on this device.
  final int? guest;

  bool get isTranslating => status == ConversationTurnStatus.translating;
  bool get isComplete => status == ConversationTurnStatus.complete;
  bool get isFailed => status == ConversationTurnStatus.failed;

  ConversationTurn copyWith({
    String? translation,
    String? Function()? engineId,
    String? Function()? engineName,
    ConversationTurnStatus? status,
    Object? Function()? error,
  }) => ConversationTurn(
    id: id,
    side: side,
    original: original,
    source: source,
    target: target,
    createdAt: createdAt,
    translation: translation ?? this.translation,
    engineId: engineId != null ? engineId() : this.engineId,
    engineName: engineName != null ? engineName() : this.engineName,
    status: status ?? this.status,
    error: error != null ? error() : this.error,
    guest: guest,
  );

  @override
  List<Object?> get props => [
    id,
    side,
    original,
    source,
    target,
    translation,
    engineId,
    engineName,
    createdAt,
    status,
    error,
    guest,
  ];
}
