import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/models/tombstone.dart';

void main() {
  final at = DateTime.utc(2026, 10, 20, 9);

  group(Tombstone, () {
    test('round-trips through JSON, in UTC', () {
      final tombstone = Tombstone(id: 'p1', deletedAt: at.toLocal());

      expect(tombstone.toJson(), {
        'id': 'p1',
        'deletedAt': '2026-10-20T09:00:00.000Z',
      });
      expect(
        Tombstone.fromJson(tombstone.toJson()),
        Tombstone(id: 'p1', deletedAt: at),
      );
    });

    test('fromJson refuses missing or invalid fields', () {
      for (final json in [
        <String, dynamic>{},
        {'id': 'p1'},
        {'id': '', 'deletedAt': '2026-10-20T09:00:00.000Z'},
        {'id': 'p1', 'deletedAt': 'yesterday'},
        {'id': 1, 'deletedAt': '2026-10-20T09:00:00.000Z'},
      ]) {
        expect(() => Tombstone.fromJson(json), throwsFormatException);
      }
    });

    test('parseList skips invalid elements and other shapes', () {
      expect(
        Tombstone.parseList([
          {'id': 'p1', 'deletedAt': '2026-10-20T09:00:00.000Z'},
          {'id': 'p2'},
          'p3',
        ]),
        [Tombstone(id: 'p1', deletedAt: at)],
      );
      expect(Tombstone.parseList(null), isEmpty);
      expect(Tombstone.parseList({'id': 'p1'}), isEmpty);
    });
  });

  group('change time helpers', () {
    test('unknownChangeTime is the epoch', () {
      expect(unknownChangeTime, DateTime.utc(1970));
    });

    test('laterOf', () {
      final later = at.add(const Duration(seconds: 1));
      expect(laterOf(null, null), isNull);
      expect(laterOf(at, null), at);
      expect(laterOf(null, at), at);
      expect(laterOf(at, later), later);
      expect(laterOf(later, at), later);
    });

    test('parseChangeTime', () {
      expect(parseChangeTime('2026-10-20T09:00:00.000Z'), at);
      expect(parseChangeTime('x'), isNull);
      expect(parseChangeTime(1), isNull);
      expect(parseChangeTime(null), isNull);
    });
  });
}
