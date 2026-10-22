import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';
import 'package:translation_repository/translation_repository.dart' show Sha256;

/// A starter pack's JSON as `tool/phrasebooks.py build` writes it.
Map<String, Object?> starterPackJson({
  String id = 'pt',
  String language = 'pt',
  String name = 'Portuguese',
  int revision = 1234,
}) => {
  'format': 'mozhi-phrasebook',
  'formatVersion': 1,
  'id': id,
  'language': language,
  'baseLanguage': 'en',
  'name': name,
  'title': '$name phrasebook',
  'source': 'Wikivoyage',
  'sourceUrl': 'https://en.wikivoyage.org/wiki/${name}_phrasebook',
  'revision': revision,
  'revisionUrl': 'https://en.wikivoyage.org/w/index.php?oldid=$revision',
  'authorsUrl':
      'https://en.wikivoyage.org/w/index.php?title=${name}_phrasebook&action=history',
  'license': 'CC BY-SA 4.0',
  'licenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
  'retrieved': '2026-10-22',
  'attribution': 'From Wikivoyage, by Wikivoyage contributors, CC BY-SA 4.0.',
  'sections': [
    {
      'title': 'Basics',
      'phrases': [
        {
          'id': 'a1',
          'text': 'Hello.',
          'translation': 'Olá.',
          'pronunciation': 'oh-LAH',
        },
        {'id': 'a2', 'text': 'Thank you.', 'translation': 'Obrigado.'},
      ],
    },
    {
      'title': 'Eating',
      'phrases': [
        {'id': 'b1', 'text': 'The bill, please.', 'translation': 'A conta.'},
      ],
    },
  ],
};

/// [json] as a pack file (gzip'd JSON).
Uint8List starterPackBytes(Map<String, Object?> json) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(json))));

/// The catalogue entry of [bytes] for pack [id].
StarterPhrasebookInfo starterInfo(
  Uint8List bytes, {
  String id = 'pt',
  String name = 'Portuguese',
  String language = 'pt',
}) => StarterPhrasebookInfo(
  id: id,
  language: language,
  name: name,
  url: Uri.parse('https://example.org/phrasebooks/$id.json.gz'),
  size: bytes.length,
  sha256: Sha256.of(bytes),
  phrases: 3,
  revision: 1234,
);

/// Writes the pack [bytes] into [store] as [StarterPhrasebooks] keeps an
/// installed one.
Future<void> installStarterPack(
  KeyValueStore store,
  Uint8List bytes, {
  String id = 'pt',
  String name = 'Portuguese',
}) async {
  await store.write(
    '${StarterPhrasebooks.packKeyPrefix}$id',
    base64Encode(bytes),
  );
  final index = await store.read(StarterPhrasebooks.indexKey);
  final list = index == null ? <Object?>[] : jsonDecode(index) as List;
  await store.write(
    StarterPhrasebooks.indexKey,
    jsonEncode([
      ...list,
      InstalledStarterPhrasebook(
        id: id,
        language: id,
        baseLanguage: 'en',
        name: name,
        sha256: Sha256.of(bytes),
        size: bytes.length,
        phrases: 3,
        installedAt: DateTime(2026, 10, 22),
      ).toJson(),
    ]),
  );
}
