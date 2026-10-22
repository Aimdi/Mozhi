import 'dart:typed_data';

import 'package:translation_repository/translation_repository.dart';

const houseNoun = DictionaryPackEntry(
  word: 'house',
  partOfSpeech: 'noun',
  pronunciation: 'haʊs',
  senses: [
    DictionaryPackSense(
      gloss: 'A structure serving as an abode.',
      tags: 'countable',
      examples: [DictionaryPackExample('This is my house.')],
    ),
    DictionaryPackSense(
      gloss: 'A dynasty.',
      examples: [DictionaryPackExample('the House of Windsor', 'das Haus')],
    ),
  ],
  synonyms: ['home', 'house', 'dwelling'],
  relatedWords: ['household'],
  etymology: 'From Old English hūs.',
  translations: {
    'de': [
      DictionaryPackTranslation('Haus', 0),
      DictionaryPackTranslation('Dynastie', 1),
    ],
    'zh': [DictionaryPackTranslation('房子')],
  },
);

const houseVerb = DictionaryPackEntry(
  word: 'house',
  partOfSpeech: 'verb',
  pronunciation: 'haʊz',
  senses: [DictionaryPackSense(gloss: 'To keep within a structure.')],
  synonyms: ['home', 'shelter'],
);

const go = DictionaryPackEntry(
  word: 'go',
  partOfSpeech: 'verb',
  senses: [DictionaryPackSense(gloss: 'To move.')],
  translations: {
    'de': [DictionaryPackTranslation('gehen')],
  },
);

const wentNoun = DictionaryPackEntry(
  word: 'went',
  partOfSpeech: 'noun',
  senses: [DictionaryPackSense(gloss: 'A path.', tags: 'archaic')],
);

const cafe = DictionaryPackEntry(
  word: 'café',
  partOfSpeech: 'noun',
  senses: [DictionaryPackSense(gloss: 'A coffee shop.')],
);

const polishAdjective = DictionaryPackEntry(
  word: 'Polish',
  partOfSpeech: 'adj',
  senses: [DictionaryPackSense(gloss: 'Of Poland.')],
);

const polishVerb = DictionaryPackEntry(
  word: 'polish',
  partOfSpeech: 'verb',
  senses: [DictionaryPackSense(gloss: 'To make shiny.')],
);

const mice = DictionaryPackEntry(
  word: 'mice',
  partOfSpeech: 'noun',
  senses: [DictionaryPackSense(gloss: 'plural of mouse', formOf: 'mouse')],
);

const left = DictionaryPackEntry(
  word: 'left',
  partOfSpeech: 'adj',
  senses: [DictionaryPackSense(gloss: 'On the west side when facing north.')],
);

const leftForm = DictionaryPackEntry(
  word: 'left',
  partOfSpeech: 'verb',
  senses: [DictionaryPackSense(gloss: 'past of leave', formOf: 'leave')],
);

/// A small English pack: [houseNoun] and [houseVerb] (form `houses`),
/// [go] (forms `went`, `gone`), [wentNoun], [cafe], [polishAdjective],
/// [polishVerb], [mice] (only a form of a missing word), [left] and
/// [leftForm].
Uint8List buildTestPack({
  int blockSize = DictionaryPackHeader.defaultBlockSize,
  Uint8List Function(Uint8List data)? compress,
  Iterable<(DictionaryPackEntry, List<String>)>? entries,
}) {
  final writer = DictionaryPackWriter(
    language: 'en',
    name: 'English',
    snapshot: '2026-10-01',
    sourceUrl: 'https://en.wiktionary.org/',
    licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
    attribution: 'From Wiktionary, CC BY-SA 4.0.',
    targets: const ['de', 'zh'],
    blockSize: blockSize,
    compress: compress ?? gzipEncodeStored,
  );
  for (final (entry, forms)
      in entries ??
          [
            (houseNoun, ['houses']),
            (houseVerb, ['houses', 'housed', 'Houses']),
            (go, ['went', 'gone', 'goes', 'go']),
            (wentNoun, <String>[]),
            (cafe, ['cafés', 'cafe']),
            (polishAdjective, <String>[]),
            (polishVerb, ['polished']),
            (mice, <String>[]),
            (left, <String>[]),
            (leftForm, <String>[]),
          ]) {
    writer.add(entry, forms: forms);
  }
  return writer.build();
}

/// A source over [bytes] that counts its reads and can fail them.
final class CountingSource implements DictionaryPackSource {
  new(this.bytes);

  final Uint8List bytes;
  int reads = 0;
  bool closed = false;
  Exception? failWith;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads++;
    final error = failWith;
    if (error != null) throw error;
    return await MemoryDictionaryPackSource(bytes).read(offset, length);
  }

  @override
  Future<void> close() async => closed = true;
}
