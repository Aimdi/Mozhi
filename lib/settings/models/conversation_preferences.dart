import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The conversation's language pair and voice options as the user last
/// chose them, kept across app starts in `AppSettings.conversation`.
class ConversationPreferences extends Equatable {
  const new({
    this.languageA,
    this.languageB,
    this.detectSpeaker = true,
    this.turnPause = defaultTurnPause,
  });

  /// Tolerant counterpart of [toJson]: missing or invalid values fall back
  /// to their defaults (`auto` and custom languages are dropped). Never
  /// throws.
  factory fromJson(Map<String, dynamic> json) {
    Language? language(Object? value) {
      if (value is! Map<String, dynamic>) return null;
      try {
        final language = Language.fromJson(value);
        return language.isAuto || language.isCustom ? null : language;
      } on Object {
        return null;
      }
    }

    final pause = json['turnPauseMs'];
    return ConversationPreferences(
      languageA: language(json['languageA']),
      languageB: language(json['languageB']),
      detectSpeaker: switch (json['detectSpeaker']) {
        final bool value => value,
        _ => true,
      },
      turnPause: pause is int && pause > 0
          ? Duration(milliseconds: pause)
          : defaultTurnPause,
    );
  }

  /// The default of [turnPause] (`ConversationState.defaultTurnPause`).
  static const defaultTurnPause = Duration(milliseconds: 800);

  /// The language of the first speaker (side A); null until chosen.
  final Language? languageA;

  /// The language of the second speaker (side B); null until chosen.
  final Language? languageB;

  /// "Detect the speaker" of hands-free conversations.
  final bool detectSpeaker;

  /// The silence that ends a turn of a hands-free conversation.
  final Duration turnPause;

  Map<String, dynamic> toJson() => {
    if (languageA case final language?) 'languageA': language.toJson(),
    if (languageB case final language?) 'languageB': language.toJson(),
    'detectSpeaker': detectSpeaker,
    'turnPauseMs': turnPause.inMilliseconds,
  };

  @override
  List<Object?> get props => [languageA, languageB, detectSpeaker, turnPause];
}
