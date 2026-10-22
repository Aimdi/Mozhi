import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

void main() {
  final sha256 = 'a' * 64;
  final sha1 = 'b' * 40;

  group('PairingFile', () {
    test('round-trips through JSON', () {
      final file = PairingFile(
        name: 'de-en/model.bin',
        size: 12,
        sha256: sha256,
        sha1: sha1,
      );
      expect(PairingFile.fromJson(file.toJson()), file);
      const plain = PairingFile(name: 'a.bin', size: 0);
      expect(plain.toJson(), {'name': 'a.bin', 'size': 0});
      expect(PairingFile.fromJson(plain.toJson()), plain);
    });

    test('accepts only safe names', () {
      for (final name in ['a', 'deu.traineddata', 'de-en/vocab.spm', 'A_b-1']) {
        expect(PairingFile.isValidName(name), isTrue, reason: name);
      }
      for (final name in [
        '',
        '.hidden',
        '..',
        '../x',
        'a/../b',
        'a/b/c',
        '/abs',
        'a/',
        r'a\b',
        'a b',
        'x' * 129,
      ]) {
        expect(PairingFile.isValidName(name), isFalse, reason: name);
      }
    });

    test('refuses invalid JSON', () {
      for (final json in <Object?>[
        'file',
        {'name': '../x', 'size': 1},
        {'name': 'a', 'size': -1},
        {'name': 'a', 'size': 1.5},
        {'name': 'a', 'size': PairingFile.maxSize + 1},
        {'name': 'a', 'size': 1, 'sha256': 'xyz'},
        {'name': 'a', 'size': 1, 'sha256': 'A' * 64},
        {'name': 'a', 'size': 1, 'sha1': 3},
      ]) {
        expect(
          () => PairingFile.fromJson(json),
          throwsA(isA<PairingProtocolException>()),
          reason: '$json',
        );
      }
    });
  });

  group('PairingItem', () {
    final item = PairingItem(
      kind: PairingItemKind.translation,
      key: 'de',
      files: [
        PairingFile(name: 'de-en/model.bin', size: 10, sha256: sha256),
        const PairingFile(name: 'de-en/vocab.spm', size: 5),
      ],
    );

    test('has an id, a size and its files', () {
      expect(item.id, 'translation:de');
      expect(item.size, 15);
      expect(item.file('de-en/vocab.spm')?.size, 5);
      expect(item.file('other'), isNull);
      expect(item.toString(), 'PairingItem(translation:de)');
    });

    test('round-trips through JSON', () {
      expect(PairingItem.fromJson(item.toJson()), item);
      const data = PairingItem(
        kind: PairingItemKind.data,
        key: 'backup',
        files: [PairingFile(name: 'backup.json', size: 3)],
        sections: ['history', 'settings'],
        secrets: true,
      );
      expect(data.toJson()['secrets'], isTrue);
      expect(PairingItem.fromJson(data.toJson()), data);
      expect(item.toJson().containsKey('sections'), isFalse);
    });

    test('refuses invalid JSON', () {
      final file = {'name': 'a', 'size': 1};
      for (final json in <Object?>[
        null,
        {'kind': 'apps', 'key': 'x', 'files': <Object?>[]},
        {'kind': 'ocr', 'key': '../x', 'files': <Object?>[]},
        {'kind': 'ocr', 'key': 3, 'files': <Object?>[]},
        {'kind': 'ocr', 'key': 'x', 'files': 'all'},
        {
          'kind': 'ocr',
          'key': 'x',
          'files': List.filled(PairingItem.maxFiles + 1, file),
        },
        {
          'kind': 'ocr',
          'key': 'x',
          'files': [file, file],
        },
        {'kind': 'data', 'key': 'x', 'files': <Object?>[], 'sections': 'all'},
        {
          'kind': 'data',
          'key': 'x',
          'files': <Object?>[],
          'sections': ['../x'],
        },
        {
          'kind': 'data',
          'key': 'x',
          'files': <Object?>[],
          'sections': List.filled(PairingItem.maxSections + 1, 'a'),
        },
        {'kind': 'data', 'key': 'x', 'files': <Object?>[], 'secrets': 'yes'},
      ]) {
        expect(
          () => PairingItem.fromJson(json),
          throwsA(isA<PairingProtocolException>()),
          reason: '$json',
        );
      }
    });
  });

  test('kinds and outcomes parse their names only', () {
    expect(PairingItemKind.tryParse('ocr'), PairingItemKind.ocr);
    expect(PairingItemKind.tryParse('apps'), isNull);
    expect(PairingItemOutcome.tryParse('noSpace'), PairingItemOutcome.noSpace);
    expect(PairingItemOutcome.tryParse(3), isNull);
  });

  test('plans know their size', () {
    const plan = PairingPlan.available([
      PairingFile(name: 'a', size: 3),
      PairingFile(name: 'b', size: 4),
    ]);
    expect(plan.size, 7);
    expect(plan.status, PairingItemStatus.available);
    expect(const PairingPlan.installed().files, isEmpty);
    expect(
      const PairingPlan.incompatible().status,
      PairingItemStatus.incompatible,
    );
  });
}
