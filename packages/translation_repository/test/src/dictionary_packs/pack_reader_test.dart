import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'pack_helpers.dart';

Future<DictionaryPackReader> _open(Uint8List bytes, {int cachedBlocks = 8}) =>
    DictionaryPackReader.open(
      MemoryDictionaryPackSource(bytes),
      cachedBlocks: cachedBlocks,
    );

/// [pack] with its metadata changed by [edit].
Uint8List _withMetadata(
  Uint8List pack,
  void Function(Map<String, Object?> json) edit,
) {
  final length = DictionaryPackHeader.metadataLength(pack);
  final json = jsonDecode(
    utf8.decode(pack.sublist(16, 16 + length)),
  ) as Map<String, Object?>;
  edit(json);
  final metadata = utf8.encode(jsonEncode(json));
  final out = BytesBuilder()
    ..add(pack.sublist(0, 12))
    ..add([
      metadata.length & 0xff,
      (metadata.length >> 8) & 0xff,
      (metadata.length >> 16) & 0xff,
      metadata.length >> 24,
    ])
    ..add(metadata)
    ..add(pack.sublist(16 + length));
  return out.takeBytes();
}

Future<List<(String, String, bool)>> _hits(
  DictionaryPackReader reader,
  String word,
) async => [
  for (final hit in await reader.lookUp(word))
    (hit.entry.word, hit.entry.partOfSpeech, hit.viaForm),
];

void main() {
  group('DictionaryPackReader', () {
    late Uint8List pack;

    setUp(() => pack = buildTestPack());

    test('reads the header', () async {
      final reader = await _open(pack);
      final header = reader.header;
      expect(header.language, 'en');
      expect(header.glossLanguage, 'en');
      expect(header.name, 'English');
      expect(header.entryCount, 10);
      expect(header.keyCount, 13);
      expect(header.targets, ['de', 'zh']);
      expect(header.fold['É'], 'e');
      expect(
        header.attribution,
        const DictionaryAttribution(
          source: 'Wiktionary',
          sourceUrl: 'https://en.wiktionary.org/',
          license: 'CC BY-SA 4.0',
          licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
          text: 'From Wiktionary, CC BY-SA 4.0.',
          snapshot: '2026-10-01',
        ),
      );
      expect(await reader.verify(), isTrue);
    });

    test('looks headwords up, folding case and accents', () async {
      final reader = await _open(pack);
      expect(await _hits(reader, 'house'), [
        ('house', 'noun', false),
        ('house', 'verb', false),
      ]);
      expect((await reader.lookUp('house')).first.entry, houseNoun);
      for (final query in ['café', 'Café', 'CAFÉ', 'cafe', ' cafe\u0301 ']) {
        expect(await _hits(reader, query), [
          ('café', 'noun', false),
        ], reason: query);
      }
      expect(await _hits(reader, 'POLISH'), [
        ('Polish', 'adj', false),
        ('polish', 'verb', false),
      ]);
    });

    test('finds the lemmas of inflected forms', () async {
      final reader = await _open(pack);
      expect(await _hits(reader, 'houses'), [
        ('house', 'noun', true),
        ('house', 'verb', true),
      ]);
      expect(await _hits(reader, 'went'), [
        ('went', 'noun', false),
        ('go', 'verb', true),
      ]);
      expect(await _hits(reader, 'cafés'), [('café', 'noun', true)]);
    });

    test('finds nothing for unknown words', () async {
      final reader = await _open(pack);
      expect(await reader.lookUp(''), isEmpty);
      expect(await reader.lookUp('   '), isEmpty);
      expect(await reader.lookUp('a'), isEmpty);
      expect(await reader.lookUp('hous'), isEmpty);
      expect(await reader.lookUp('zzz'), isEmpty);
    });

    test('suggests words by prefix, as written', () async {
      final reader = await _open(pack);
      expect(await reader.suggest('ho'), ['house', 'housed', 'houses']);
      expect(await reader.suggest('HO', limit: 2), ['house', 'housed']);
      expect(await reader.suggest('pol'), ['Polish', 'polished']);
      expect(await reader.suggest('caf'), ['café', 'cafés']);
      expect(await reader.suggest('a'), isEmpty);
      expect(await reader.suggest('zz'), isEmpty);
      expect(await reader.suggest(''), isEmpty);
      expect(await reader.suggest('ho', limit: 0), isEmpty);
    });

    test('reads entries by id', () async {
      final reader = await _open(pack);
      expect(await reader.entry(0), cafe);
      expect(() => reader.entry(10), throwsRangeError);
      expect(() => reader.entry(-1), throwsRangeError);
    });

    test('works across many small blocks', () async {
      final small = buildTestPack(blockSize: 48);
      final reader = await _open(small, cachedBlocks: 2);
      expect(await _hits(reader, 'went'), [
        ('went', 'noun', false),
        ('go', 'verb', true),
      ]);
      expect(await _hits(reader, 'polish'), [
        ('Polish', 'adj', false),
        ('polish', 'verb', false),
      ]);
      expect(await reader.suggest('h'), ['house', 'housed', 'houses']);
      expect(await reader.suggest('', limit: 3), isEmpty);
      for (var id = 0; id < reader.header.entryCount; id++) {
        expect(await reader.entry(id), isA<DictionaryPackEntry>());
      }
      expect(await reader.verify(chunkSize: 7), isTrue);
    });

    test('reads packs compressed with zlib', () async {
      final zipped = buildTestPack(
        compress: (data) => Uint8List.fromList(GZipCodec().encode(data)),
      );
      expect(zipped.length, lessThan(pack.length));
      final reader = await _open(zipped);
      expect(await _hits(reader, 'gone'), [('go', 'verb', true)]);
    });

    test('keeps the last blocks in memory', () async {
      final source = CountingSource(buildTestPack(blockSize: 48));
      final reader = await DictionaryPackReader.open(source, cachedBlocks: 2);
      final opened = source.reads;
      await reader.lookUp('café');
      final first = source.reads - opened;
      expect(first, greaterThan(0));
      await reader.lookUp('café');
      expect(source.reads - opened, first);
      // Other blocks push the cached ones out.
      await reader.lookUp('went');
      await reader.lookUp('polish');
      final before = source.reads;
      await reader.lookUp('café');
      expect(source.reads, greaterThan(before));
    });

    test('shares a block that is being read', () async {
      final source = CountingSource(pack);
      final reader = await DictionaryPackReader.open(source);
      final opened = source.reads;
      await Future.wait([reader.lookUp('house'), reader.lookUp('house')]);
      // One key block and one entry block.
      expect(source.reads - opened, 2);
    });

    test('does not keep a failed read', () async {
      final source = CountingSource(pack);
      final reader = await DictionaryPackReader.open(source);
      source.failWith = const FileSystemException('gone');
      await expectLater(
        reader.lookUp('house'),
        throwsA(isA<FileSystemException>()),
      );
      source.failWith = null;
      expect(await reader.lookUp('house'), hasLength(2));
    });

    test('notices damaged data', () async {
      final damaged = Uint8List.fromList(pack);
      damaged[damaged.length - 20] ^= 0xff;
      final reader = await _open(damaged);
      expect(await reader.verify(), isFalse);
      final short = CountingSource(pack);
      final truncated = await DictionaryPackReader.open(short);
      short.bytes.fillRange(0, 0);
      expect(await truncated.verify(), isTrue);
    });

    test('fails on a truncated read during verify', () async {
      final source = _ShortSource(pack);
      final reader = await DictionaryPackReader.open(source);
      source.short = true;
      expect(await reader.verify(), isFalse);
      await expectLater(reader.lookUp('zebra'), throwsFormatException);
    });

    test('rejects what is not a valid pack, closing the source', () async {
      Future<void> rejects(Uint8List bytes) async {
        final source = CountingSource(bytes);
        await expectLater(
          DictionaryPackReader.open(source),
          throwsFormatException,
        );
        expect(source.closed, isTrue);
      }

      await rejects(Uint8List.fromList(utf8.encode('NOTAPACK' * 4)));
      await rejects(Uint8List.fromList(pack.sublist(0, pack.length - 1)));
      await rejects(Uint8List.fromList(pack.sublist(0, 100)));
      await rejects(Uint8List.fromList(pack)..[8] = 2);
      await rejects(Uint8List.fromList(pack)..setRange(12, 16, [0, 0, 0, 0]));
      await rejects(Uint8List.fromList(pack)..setRange(12, 16, [0, 0, 0, 1]));
      await rejects(_withMetadata(pack, (json) => json['format'] = 2));
      await rejects(_withMetadata(pack, (json) => json['dataLength'] = 1));
      await rejects(
        _withMetadata(pack, (json) {
          (json['layout']! as Map<String, Object?>)['blocks'] = [0, 1 << 20];
        }),
      );
      await rejects(
        _withMetadata(pack, (json) {
          final layout = json['layout']! as Map<String, Object?>;
          layout['blocks'] = layout['directory'];
        }),
      );
      await rejects(_withMetadata(pack, (json) => json['entries'] = 0));
      await rejects(_withMetadata(pack, (json) => json['keys'] = -1));
      await rejects(_withMetadata(pack, (json) => json['sha256'] = 'x'));
    });

    test('rejects a corrupt directory', () async {
      // The directory says its key block is longer than the data.
      final writer = DictionaryPackWriter(language: 'en')..add(cafe);
      final small = writer.build();
      final length = DictionaryPackHeader.metadataLength(small);
      final header = DictionaryPackHeader.fromJson(
        jsonDecode(utf8.decode(small.sublist(16, 16 + length))),
      );
      final at = 16 + length + header.directory.offset;
      final broken = Uint8List.fromList(small)..[at + 2] = 0x7f;
      await expectLater(
        DictionaryPackReader.open(MemoryDictionaryPackSource(broken)),
        throwsFormatException,
      );
    });

    test('closes', () async {
      final source = CountingSource(pack);
      final reader = await DictionaryPackReader.open(source);
      await reader.close();
      await reader.close();
      expect(source.closed, isTrue);
      expect(() => reader.lookUp('house'), throwsStateError);
    });

    test('an empty pack finds nothing', () async {
      final reader = await _open(DictionaryPackWriter(language: 'xx').build());
      expect(reader.header.entryCount, 0);
      expect(await reader.lookUp('house'), isEmpty);
      expect(await reader.suggest('h'), isEmpty);
      expect(await reader.verify(), isTrue);
    });
  });

  test('DictionaryPackHit has value equality', () {
    const a = DictionaryPackHit(id: 1, entry: cafe);
    expect(a, const DictionaryPackHit(id: 1, entry: cafe));
    expect(
      a,
      isNot(const DictionaryPackHit(id: 1, entry: cafe, viaForm: true)),
    );
    expect(a.hashCode, const DictionaryPackHit(id: 1, entry: cafe).hashCode);
    expect('$a', contains('café'));
  });
}

/// Answers reads with one byte too few once [short] is set.
final class _ShortSource implements DictionaryPackSource {
  new(this._bytes);

  final Uint8List _bytes;
  bool short = false;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final bytes = await MemoryDictionaryPackSource(_bytes).read(offset, length);
    return short && bytes.isNotEmpty ? bytes.sublist(1) : bytes;
  }

  @override
  Future<void> close() async {}
}
