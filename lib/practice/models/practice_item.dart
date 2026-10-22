import 'package:equatable/equatable.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/practice/models/practice_card.dart';

/// A card with the phrase it asks for: what the review shows.
///
/// [foreignIsSource] says which side of the phrase is the language being
/// learned (see [learnedSideOf]): a recognise card shows that side first,
/// a produce card asks for it.
final class PracticeItem extends Equatable {
  const new({
    required this.card,
    required this.phrase,
    required this.foreignIsSource,
  });

  final PracticeCard card;
  final Phrase phrase;

  /// Whether [Phrase.text] is in the language being learned (else
  /// [Phrase.translation] is).
  final bool foreignIsSource;

  String get id => card.id;
  CardDirection get direction => card.direction;

  /// The text in the language being learned, and its language.
  String get foreignText => foreignIsSource ? phrase.text : phrase.translation;
  String get foreignCode =>
      foreignIsSource ? phrase.sourceCode : phrase.targetCode;

  /// The text in the user's language, and its language.
  String get nativeText => foreignIsSource ? phrase.translation : phrase.text;
  String get nativeCode =>
      foreignIsSource ? phrase.targetCode : phrase.sourceCode;

  /// What the card shows first: the foreign text (recognise) or the
  /// user's (produce).
  String get frontText =>
      direction == CardDirection.recognize ? foreignText : nativeText;
  String get frontCode =>
      direction == CardDirection.recognize ? foreignCode : nativeCode;

  /// The answer.
  String get backText =>
      direction == CardDirection.recognize ? nativeText : foreignText;
  String get backCode =>
      direction == CardDirection.recognize ? nativeCode : foreignCode;

  /// How to say the foreign text, when the phrase knows (starter phrases
  /// have it for their translation).
  String get pronunciation => foreignIsSource ? '' : phrase.pronunciation;

  PracticeItem withCard(PracticeCard card) => PracticeItem(
    card: card,
    phrase: phrase,
    foreignIsSource: foreignIsSource,
  );

  @override
  List<Object?> get props => [card, phrase, foreignIsSource];
}

/// The primary subtag of a language code (`pt` of `pt-BR`), lower case.
String primaryLanguage(String code) =>
    code.split(RegExp('[-_]')).first.trim().toLowerCase();

/// The user's own language among [phrases]: [appLanguage] (the app's
/// language) when at least half of them have it on one side, else the
/// language most of them have (people save phrases between their language
/// and the ones they learn), [appLanguage] on a tie or when there are
/// none.
String userLanguageOf(Iterable<Phrase> phrases, String appLanguage) {
  final app = primaryLanguage(appLanguage);
  final counts = <String, int>{};
  var total = 0;
  for (final phrase in phrases) {
    total++;
    final sides = {
      primaryLanguage(phrase.sourceCode),
      primaryLanguage(phrase.targetCode),
    }..remove(Phrase.unknownLanguage);
    for (final code in sides) {
      counts[code] = (counts[code] ?? 0) + 1;
    }
  }
  if (total == 0 || (counts[app] ?? 0) * 2 >= total) return app;
  var best = app;
  var most = counts[app] ?? 0;
  for (final MapEntry(key: code, value: count) in counts.entries) {
    if (count > most) {
      best = code;
      most = count;
    }
  }
  return best;
}

/// Whether [phrase]'s text (rather than its translation) is in the
/// language being learned, for a user whose language is [userLanguage]:
/// the side that is not in [userLanguage]; the translation when neither
/// or both are.
bool learnedSideOf(Phrase phrase, String userLanguage) {
  final user = primaryLanguage(userLanguage);
  final source = primaryLanguage(phrase.sourceCode) == user;
  final target = primaryLanguage(phrase.targetCode) == user;
  return target && !source;
}
