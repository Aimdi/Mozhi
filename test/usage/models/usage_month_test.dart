import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/usage/models/models.dart';

void main() {
  group('UsageMonth', () {
    test('of takes year and month of a date', () {
      expect(UsageMonth.of(DateTime(2026, 10, 31, 23, 59)), UsageMonth(2026, 10));
    });

    test('key is zero padded', () {
      expect(const UsageMonth(2026, 3).key, '2026-03');
      expect(const UsageMonth(987, 12).key, '0987-12');
    });

    test('tryParse round-trips keys and rejects garbage', () {
      expect(UsageMonth.tryParse('2026-03'), const UsageMonth(2026, 3));
      expect(UsageMonth.tryParse('2026-13'), isNull);
      expect(UsageMonth.tryParse('2026-00'), isNull);
      expect(UsageMonth.tryParse('2026-3'), isNull);
      expect(UsageMonth.tryParse('x'), isNull);
    });

    test('previous and next cross year boundaries', () {
      expect(const UsageMonth(2026, 1).previous, const UsageMonth(2025, 12));
      expect(const UsageMonth(2025, 12).next, const UsageMonth(2026, 1));
      expect(const UsageMonth(2026, 10).shift(-10), const UsageMonth(2025, 12));
      expect(const UsageMonth(2026, 10).shift(3), const UsageMonth(2027, 1));
    });

    test('index, fromIndex and start agree', () {
      const month = UsageMonth(2026, 10);
      expect(UsageMonth.fromIndex(month.index), month);
      expect(month.start, DateTime(2026, 10));
    });

    test('compares chronologically', () {
      final months = [
        const UsageMonth(2026, 2),
        const UsageMonth(2025, 12),
        const UsageMonth(2026, 1),
      ]..sort();
      expect(months, [
        const UsageMonth(2025, 12),
        const UsageMonth(2026, 1),
        const UsageMonth(2026, 2),
      ]);
    });

    test('toString shows the key', () {
      expect(const UsageMonth(2026, 4).toString(), 'UsageMonth(2026-04)');
    });
  });
}
