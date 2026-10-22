import 'dart:typed_data';

import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:translation_repository/translation_repository.dart';

/// A small Spanish pack: `gato` (forms `gatos`, `gata`) and `árbol`.
Uint8List spanishPack() {
  final writer =
      DictionaryPackWriter(
          language: 'es',
          name: 'Spanish',
          snapshot: '2026-10-01',
          licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
          attribution: 'Spanish entries from Wiktionary.',
        )
        ..add(
          const DictionaryPackEntry(
            word: 'gato',
            partOfSpeech: 'noun',
            pronunciation: 'ˈɡato',
            senses: [
              DictionaryPackSense(
                gloss: 'cat',
                tags: 'masculine',
                examples: [
                  DictionaryPackExample('El gato duerme.', 'The cat sleeps.'),
                ],
              ),
            ],
            synonyms: ['minino'],
          ),
          forms: ['gatos', 'gata'],
        )
        ..add(
          const DictionaryPackEntry(
            word: 'árbol',
            partOfSpeech: 'noun',
            senses: [DictionaryPackSense(gloss: 'tree')],
          ),
        );
  return writer.build();
}

/// A small English pack: `cat` (translated into Spanish and German), `go`
/// (form `went`) and `gato` (an English word too, for detection).
Uint8List englishPack() {
  final writer = DictionaryPackWriter(language: 'en', name: 'English')
    ..add(
      const DictionaryPackEntry(
        word: 'cat',
        partOfSpeech: 'noun',
        pronunciation: 'kæt',
        senses: [DictionaryPackSense(gloss: 'A small domesticated feline.')],
        translations: {
          'es': [DictionaryPackTranslation('gato', 0)],
          'de': [DictionaryPackTranslation('Katze', 0)],
        },
      ),
    )
    ..add(
      const DictionaryPackEntry(
        word: 'go',
        partOfSpeech: 'verb',
        senses: [DictionaryPackSense(gloss: 'To move.')],
      ),
      forms: ['went'],
    )
    ..add(
      const DictionaryPackEntry(
        word: 'Gato',
        partOfSpeech: 'noun',
        senses: [DictionaryPackSense(gloss: 'A surname.')],
      ),
    );
  return writer.build();
}

/// The catalogue entry of [bytes] as pack [id].
DictionaryPackInfo packInfo(
  String id,
  Uint8List bytes, {
  String? language,
  String name = 'Spanish',
}) => DictionaryPackInfo(
  id: id,
  language: language ?? id,
  name: name,
  url: Uri.parse('https://github.com/Aimdi/Mozhi/releases/download/r/$id.mzd'),
  size: bytes.length,
  sha256: Sha256.of(bytes),
  entries: 2,
);

/// The stored record of [info].
StoredDictionaryPack storedPack(DictionaryPackInfo info) =>
    StoredDictionaryPack(
      id: info.id,
      language: info.language,
      name: info.name,
      size: info.size,
      sha256: info.sha256,
    );
