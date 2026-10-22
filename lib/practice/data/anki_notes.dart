import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/anki_export.dart';
import 'package:mozhi/practice/models/practice_item.dart';

/// The phrases of the collection [collectionId] (null: of every
/// collection, each phrase once) as Anki notes ([AnkiExport]): the front
/// is the phrase in the language being learned, the back the user's
/// language (see [userLanguageOf], with [appLanguage]) with the
/// pronunciation and the note on lines of their own; the tags name every
/// exported collection the phrase is in ([AnkiExport.collectionTag] of
/// [nameOf]) and its language pair ([AnkiExport.pairTag]).
Future<List<AnkiNote>> ankiNotesOf(
  PhrasebookRepository phrasebook, {
  required String appLanguage,
  required String Function(PhraseCollection collection) nameOf,
  String? collectionId,
}) async {
  final collections = [
    for (final collection in await phrasebook.collections())
      if (collectionId == null || collection.id == collectionId) collection,
  ];
  final phrases = <String, Phrase>{};
  final tags = <String, List<String>>{};
  for (final collection in collections) {
    final tag = AnkiExport.collectionTag(nameOf(collection));
    for (final phrase in await phrasebook.phrases(
      collectionId: collection.id,
    )) {
      if (phrase.text.trim().isEmpty || phrase.translation.trim().isEmpty) {
        continue;
      }
      phrases.putIfAbsent(phrase.id, () => phrase);
      final list = tags.putIfAbsent(phrase.id, () => []);
      if (!list.contains(tag)) list.add(tag);
    }
  }
  final user = userLanguageOf(phrases.values, appLanguage);
  return [
    for (final phrase in phrases.values)
      _note(phrase, learnedSideOf(phrase, user), tags[phrase.id]!),
  ];
}

AnkiNote _note(Phrase phrase, bool foreignIsSource, List<String> tags) {
  final front = foreignIsSource ? phrase.text : phrase.translation;
  final back = foreignIsSource ? phrase.translation : phrase.text;
  final pronunciation = foreignIsSource ? '' : phrase.pronunciation.trim();
  return AnkiNote(
    front: front.trim(),
    back: [
      back.trim(),
      if (pronunciation.isNotEmpty) pronunciation,
      if (phrase.note.trim().isNotEmpty) phrase.note.trim(),
    ].join('\n'),
    tags: [...tags, AnkiExport.pairTag(phrase.sourceCode, phrase.targetCode)],
  );
}
