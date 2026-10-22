import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/models/history_tombstone.dart';

void main() {
  group(HistoryTombstone, () {
    final tombstone = HistoryTombstone(
      id: '1729600000000000',
      deletedAt: DateTime.utc(2026, 10, 22, 9, 30),
    );

    test('round-trips through JSON in UTC', () {
      expect(tombstone.toJson(), {
        'id': '1729600000000000',
        'deletedAt': '2026-10-22T09:30:00.000Z',
      });
      expect(HistoryTombstone.fromJson(tombstone.toJson()), tombstone);
      expect(
        HistoryTombstone(
          id: '1',
          deletedAt: DateTime.utc(2026).toLocal(),
        ).toJson()['deletedAt'],
        '2026-01-01T00:00:00.000Z',
      );
    });

    test('fromJson refuses invalid tombstones', () {
      for (final json in <Map<String, dynamic>>[
        {},
        {'id': '', 'deletedAt': '2026-10-22T09:30:00.000Z'},
        {'id': 1, 'deletedAt': '2026-10-22T09:30:00.000Z'},
        {'id': '1', 'deletedAt': 'yesterday'},
        {'id': '1', 'deletedAt': 12},
      ]) {
        expect(
          () => HistoryTombstone.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });
}
