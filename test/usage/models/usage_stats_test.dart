import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/usage/models/models.dart';

void main() {
  group('UsageStats', () {
    const stats = UsageStats(
      requests: 2,
      inputChars: 100,
      outputChars: 120,
      inputTokens: 25,
      outputTokens: 30,
    );

    test('derives totals', () {
      expect(stats.totalChars, 220);
      expect(stats.estimatedTokens, 55);
      expect(stats.isEmpty, isFalse);
      expect(UsageStats.zero.isEmpty, isTrue);
    });

    test('adds field by field', () {
      expect(
        stats + stats,
        const UsageStats(
          requests: 4,
          inputChars: 200,
          outputChars: 240,
          inputTokens: 50,
          outputTokens: 60,
        ),
      );
    });

    test('round-trips through JSON', () {
      expect(UsageStats.fromJson(stats.toJson()), stats);
    });

    test('fromJson is tolerant', () {
      expect(
        UsageStats.fromJson(const {
          'requests': -3,
          'inputChars': 9,
          'outputChars': 'x',
        }),
        const UsageStats(inputChars: 9, inputTokens: 3),
      );
      expect(
        UsageStats.fromJson(const {'requests': 1.0, 'inputChars': double.nan}),
        const UsageStats(requests: 1),
      );
    });
  });
}
