import 'package:equatable/equatable.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart'
    show dictionaryScriptLanguage;
import 'package:mozhi/dictionary/data/dictionary_entry_store.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:translation_repository/translation_repository.dart';

/// A phrase to add to a collection (`PhrasebookRepository.addPhrase`): what
/// a [Phrase] holds but its id and times, which the repository gives it.
class PhraseDraft extends Equatable {
  const new({
    required this.text,
    required this.translation,
    required this.sourceCode,
    required this.targetCode,
    this.note = '',
    this.origin = PhraseOrigin.manual,
    this.pronunciation = '',
    this.topic = '',
  });

  /// A history entry: a translation ([PhraseOrigin.history]) or a
  /// dictionary look-up ([PhraseOrigin.dictionary]), in the languages of
  /// [phraseLanguageOf].
  ///
  /// A look-up is the word with its first translation into the target
  /// language, from the entry the history kept
  /// ([HistoryEntry.dictionaryJson]); only without one (an offline
  /// dictionary's entry, or one saved before entries were kept) its
  /// summary. A word looked up with "Detect language" is in the language
  /// found then ([HistoryEntry.detectedSource]), else in the one its
  /// script tells, if any.
  factory fromHistory(HistoryEntry entry) {
    if (!entry.isDictionary) {
      return PhraseDraft(
        text: entry.text.trim(),
        translation: entry.translation.trim(),
        sourceCode: phraseLanguageOf(
          entry.source,
          detected: entry.detectedSource,
        ),
        targetCode: phraseLanguageOf(entry.target),
        origin: PhraseOrigin.history,
      );
    }
    final kept = decodeDictionaryEntry(entry.dictionaryJson);
    final translation = kept == null ? null : firstDictionaryTranslation(kept);
    return PhraseDraft(
      text: entry.text.trim(),
      translation: translation ?? entry.translation.trim(),
      sourceCode: phraseLanguageOf(
        entry.source,
        detected: entry.detectedSource ?? dictionaryScriptLanguage(entry.text),
      ),
      targetCode: phraseLanguageOf(entry.target),
      origin: PhraseOrigin.dictionary,
    );
  }

  /// A copy of [phrase] (a favourite or a starter phrase going into a
  /// collection), with its note, pronunciation and topic.
  factory fromPhrase(Phrase phrase) => PhraseDraft(
    text: phrase.text,
    translation: phrase.translation,
    sourceCode: phrase.sourceCode,
    targetCode: phrase.targetCode,
    note: phrase.note,
    origin: phrase.origin,
    pronunciation: phrase.pronunciation,
    topic: phrase.topic,
  );

  final String text;
  final String translation;
  final String sourceCode;
  final String targetCode;
  final String note;
  final PhraseOrigin origin;
  final String pronunciation;
  final String topic;

  /// Whether there is nothing to save: no text or no translation.
  bool get isEmpty => text.trim().isEmpty || translation.trim().isEmpty;

  /// The phrase [id] made of this draft at [time].
  Phrase toPhrase(String id, DateTime time) => Phrase(
    id: id,
    text: text.trim(),
    translation: translation.trim(),
    sourceCode: sourceCode,
    targetCode: targetCode,
    createdAt: time,
    updatedAt: time,
    note: note.trim(),
    origin: origin,
    pronunciation: pronunciation.trim(),
    topic: topic.trim(),
  );

  /// See [Phrase.contentKey].
  String get contentKey =>
      '$sourceCode\u001f$targetCode\u001f${text.trim()}'
      '\u001f${translation.trim()}';

  @override
  List<Object?> get props => [
    text,
    translation,
    sourceCode,
    targetCode,
    note,
    origin,
    pronunciation,
    topic,
  ];
}

/// The phrase language code of [language]: [detected] for "Detect
/// language" (when known), [Phrase.unknownLanguage] for an undetected or
/// custom language, its code otherwise. Never `auto`.
String phraseLanguageOf(Language language, {String? detected}) {
  if (language.isCustom) return Phrase.unknownLanguage;
  if (language.isAuto) {
    final code = detected?.trim() ?? '';
    return code.isEmpty || code == 'auto' ? Phrase.unknownLanguage : code;
  }
  final code = language.code.trim();
  return code.isEmpty ? Phrase.unknownLanguage : code;
}
