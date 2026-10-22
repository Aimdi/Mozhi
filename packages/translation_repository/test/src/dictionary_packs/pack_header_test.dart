import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _json() => const DictionaryPackHeader(
  language: 'es',
  entryCount: 3,
  keyCount: 4,
  directory: (offset: 10, length: 5),
  blocks: (offset: 15, length: 3),
  dataLength: 18,
  sha256: _sha,
  name: 'Spanish',
  targets: ['en'],
  fold: {'Á': 'a'},
).toJson();

void main() {
  group('DictionaryPackHeader', () {
    test('round-trips through JSON and bytes', () {
      final header = DictionaryPackHeader.fromJson(_json());
      expect(header.language, 'es');
      expect(header.glossLanguage, 'en');
      expect(header.name, 'Spanish');
      expect(header.source, 'Wiktionary');
      expect(header.license, 'CC BY-SA 4.0');
      expect(header.targets, ['en']);
      expect(header.fold, {'Á': 'a'});
      expect(header.directory, (offset: 10, length: 5));
      expect(header.blocks, (offset: 15, length: 3));
      expect(header.blockSize, DictionaryPackHeader.defaultBlockSize);
      final bytes = header.encode();
      expect(ascii.decode(bytes.sublist(0, 8)), 'MOZHIDCT');
      final length = DictionaryPackHeader.metadataLength(bytes);
      expect(length, bytes.length - DictionaryPackHeader.prefixLength);
      expect(
        DictionaryPackHeader.fromJson(
          jsonDecode(utf8.decode(bytes.sublist(16))),
        ).toJson(),
        header.toJson(),
      );
    });

    test('defaults missing optional fields', () {
      final json = _json()
        ..remove('glossLanguage')
        ..remove('fold')
        ..remove('targets');
      final header = DictionaryPackHeader.fromJson(json);
      expect(header.glossLanguage, 'en');
      expect(header.fold, isEmpty);
      expect(header.targets, isEmpty);
    });

    test('rejects invalid metadata', () {
      void rejects(void Function(Map<String, Object?> json) edit) {
        final json = _json();
        edit(json);
        expect(
          () => DictionaryPackHeader.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }

      expect(() => DictionaryPackHeader.fromJson('x'), throwsFormatException);
      rejects((json) => json['format'] = 2);
      rejects((json) => json['fold'] = {'a': 1});
      rejects((json) => json['fold'] = []);
      rejects((json) => json['layout'] = []);
      rejects(
        (json) => json['layout'] = {
          'directory': [1],
          'blocks': [1, 2],
        },
      );
      rejects(
        (json) => json['layout'] = {
          'directory': [-1, 2],
          'blocks': [1, 2],
        },
      );
      rejects((json) => json['sha256'] = 'ABC');
      rejects((json) => json['language'] = '');
      rejects((json) => json['language'] = 3);
      rejects((json) => json['targets'] = [1]);
      rejects((json) => json['entries'] = -1);
      rejects((json) => json['keys'] = '4');
    });

    test('reads the metadata length only from a pack prefix', () {
      final bytes = const DictionaryPackHeader(
        language: 'es',
        entryCount: 0,
        keyCount: 0,
        directory: (offset: 0, length: 0),
        blocks: (offset: 0, length: 0),
        dataLength: 0,
        sha256: _sha,
      ).encode();
      expect(
        () => DictionaryPackHeader.metadataLength(Uint8List(8)),
        throwsFormatException,
      );
      expect(
        () => DictionaryPackHeader.metadataLength(
          Uint8List.fromList(bytes)..[0] = 0x41,
        ),
        throwsFormatException,
      );
      expect(
        () => DictionaryPackHeader.metadataLength(
          Uint8List.fromList(bytes)..setRange(12, 16, [0, 0, 0x20, 0]),
        ),
        throwsFormatException,
      );
    });
  });

  test('DictionaryAttribution has value equality', () {
    const a = DictionaryAttribution(
      source: 'Wiktionary',
      license: 'CC BY-SA 4.0',
    );
    expect(
      a,
      const DictionaryAttribution(
        source: 'Wiktionary',
        license: 'CC BY-SA 4.0',
      ),
    );
    expect(
      a,
      isNot(
        const DictionaryAttribution(source: 'WikDict', license: 'CC BY-SA 4.0'),
      ),
    );
    expect(
      a.hashCode,
      const DictionaryAttribution(
        source: 'Wiktionary',
        license: 'CC BY-SA 4.0',
      ).hashCode,
    );
    expect('$a', 'DictionaryAttribution(Wiktionary, CC BY-SA 4.0)');
  });
}
