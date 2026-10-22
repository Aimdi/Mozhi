import 'package:equatable/equatable.dart';

/// Where a [Phrase] came from.
enum PhraseOrigin {
  /// Typed or imported by the user (a CSV import).
  manual,

  /// A favourite of the history (the built-in Favorites collection), or a
  /// copy of one in a collection.
  favorite,

  /// A translation of the history added to a collection.
  history,

  /// A dictionary entry (the word and its translation or summary).
  dictionary,

  /// A phrase of a starter phrasebook (Wikivoyage), or a copy of one.
  starter,
}

/// One phrase of the phrasebook: [text] in [sourceCode] and its
/// [translation] in [targetCode], with the user's [note].
///
/// Ids say where a phrase lives:
/// * `h:<history entry id>` ([favoriteIdPrefix]): a favourite of the
///   history, read from it (nothing is copied);
/// * `s:<pack id>:<phrase id>` ([starterIdPrefix]): a phrase of an
///   installed starter phrasebook (read-only);
/// * anything else (`p:<random>`): a phrase stored in the phrasebook.
///
/// Language codes are never `auto`: a favourite whose source language was
/// detected has the detected language, and [unknownLanguage] (`und`) when
/// there was none (or for a custom AI language).
class Phrase extends Equatable {
  const new({
    required this.id,
    required this.text,
    required this.translation,
    required this.sourceCode,
    required this.targetCode,
    required this.createdAt,
    required this.updatedAt,
    this.note = '',
    this.origin = PhraseOrigin.manual,
    this.pronunciation = '',
    this.topic = '',
  });

  /// Parses a phrase written by [toJson]. Throws [FormatException] when a
  /// required field is missing or invalid; an unknown `origin` reads as
  /// [PhraseOrigin.manual].
  factory fromJson(Map<String, dynamic> json) {
    if (json
        case {
          'id': final String id,
          'text': final String text,
          'translation': final String translation,
          'sourceCode': final String sourceCode,
          'targetCode': final String targetCode,
        }
        when id.isNotEmpty && sourceCode.isNotEmpty && targetCode.isNotEmpty) {
      final createdAt = parseTime(json['createdAt']);
      if (createdAt == null) {
        throw FormatException('Invalid phrase createdAt', json);
      }
      return Phrase(
        id: id,
        text: text,
        translation: translation,
        sourceCode: sourceCode,
        targetCode: targetCode,
        createdAt: createdAt,
        updatedAt: parseTime(json['updatedAt']) ?? createdAt,
        note: _string(json['note']),
        origin:
            PhraseOrigin.values.asNameMap()[json['origin']] ??
            PhraseOrigin.manual,
        pronunciation: _string(json['pronunciation']),
        topic: _string(json['topic']),
      );
    }
    throw FormatException('Invalid phrase', json);
  }

  /// Id prefix of the history favourites (`h:<history entry id>`).
  static const favoriteIdPrefix = 'h:';

  /// Id prefix of starter phrases (`s:<pack id>:<phrase id>`).
  static const starterIdPrefix = 's:';

  /// Id prefix of phrases stored in the phrasebook.
  static const storedIdPrefix = 'p:';

  /// The language code of an unknown language (BCP 47 "undetermined").
  static const unknownLanguage = 'und';

  /// The phrase id of the history favourite [historyId].
  static String favoriteId(String historyId) => '$favoriteIdPrefix$historyId';

  /// The history entry id of the favourite [phraseId], or null when it is
  /// not one.
  static String? historyIdOf(String phraseId) =>
      phraseId.startsWith(favoriteIdPrefix)
      ? phraseId.substring(favoriteIdPrefix.length)
      : null;

  /// The phrase id of phrase [phraseId] of the starter pack [packId].
  static String starterId(String packId, String phraseId) =>
      '$starterIdPrefix$packId:$phraseId';

  /// The pack id of the starter phrase [id], or null when it is not one.
  static String? starterPackOf(String id) {
    if (!id.startsWith(starterIdPrefix)) return null;
    final rest = id.substring(starterIdPrefix.length);
    final colon = rest.indexOf(':');
    return colon <= 0 ? null : rest.substring(0, colon);
  }

  final String id;

  /// The phrase, in [sourceCode].
  final String text;

  /// Its translation, in [targetCode].
  final String translation;

  /// The language of [text]: a language code, never `auto`.
  final String sourceCode;

  /// The language of [translation]: a language code, never `auto`.
  final String targetCode;
  final DateTime createdAt;

  /// When the phrase (or its note) last changed.
  final DateTime updatedAt;

  /// The user's note.
  final String note;
  final PhraseOrigin origin;

  /// How to say [translation] (a starter phrase's pronunciation guide);
  /// empty when unknown.
  final String pronunciation;

  /// The section of the starter phrasebook it comes from ("Basics",
  /// "Eating"); empty otherwise.
  final String topic;

  /// Whether this is a history favourite (read from the history).
  bool get isFavorite => id.startsWith(favoriteIdPrefix);

  /// Whether this is a phrase of a starter phrasebook (read-only).
  bool get isStarter => id.startsWith(starterIdPrefix);

  /// Whether the phrase is stored in the phrasebook (neither a favourite
  /// nor a starter phrase).
  bool get isStored => !isFavorite && !isStarter;

  /// What makes two phrases the same phrase (the languages, the text and
  /// the translation, trimmed): adding one that a collection already has
  /// adds nothing.
  String get contentKey =>
      '$sourceCode\u001f$targetCode\u001f${text.trim()}'
      '\u001f${translation.trim()}';

  Phrase copyWith({
    String? id,
    String? text,
    String? translation,
    String? sourceCode,
    String? targetCode,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? note,
    PhraseOrigin? origin,
    String? pronunciation,
    String? topic,
  }) => Phrase(
    id: id ?? this.id,
    text: text ?? this.text,
    translation: translation ?? this.translation,
    sourceCode: sourceCode ?? this.sourceCode,
    targetCode: targetCode ?? this.targetCode,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    note: note ?? this.note,
    origin: origin ?? this.origin,
    pronunciation: pronunciation ?? this.pronunciation,
    topic: topic ?? this.topic,
  );

  /// Times are written as UTC ISO-8601 strings; empty optional fields are
  /// left out.
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'translation': translation,
    'sourceCode': sourceCode,
    'targetCode': targetCode,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (note.isNotEmpty) 'note': note,
    'origin': origin.name,
    if (pronunciation.isNotEmpty) 'pronunciation': pronunciation,
    if (topic.isNotEmpty) 'topic': topic,
  };

  /// A time written by [toJson] (or milliseconds since the epoch), in local
  /// time; null when [value] is neither.
  static DateTime? parseTime(Object? value) => switch (value) {
    final String iso => DateTime.tryParse(iso)?.toLocal(),
    final int millis => DateTime.fromMillisecondsSinceEpoch(millis),
    _ => null,
  };

  static String _string(Object? value) => value is String ? value : '';

  @override
  List<Object?> get props => [
    id,
    text,
    translation,
    sourceCode,
    targetCode,
    createdAt,
    updatedAt,
    note,
    origin,
    pronunciation,
    topic,
  ];
}
