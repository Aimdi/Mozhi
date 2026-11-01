import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/widgets/decimal_format.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

void main() {
  group('formatDecimal', () {
    test('uses the decimal separator of the locale', () {
      expect(formatDecimal(0.75, 'en'), '0.8');
      expect(formatDecimal(0.75, 'de'), '0,8');
      expect(formatDecimal(1.25, 'fr'), '1,3');
      expect(formatDecimal(2, 'de'), '2,0');
      expect(formatDecimal(0.7, 'ta'), '0.7');
    });

    test('can leave whole numbers without decimals', () {
      expect(formatDecimal(2, 'de', trimZero: true), '2');
      expect(formatDecimal(2.5, 'de', trimZero: true), '2,5');
    });

    test('falls back to English for unknown locales', () {
      expect(formatDecimal(0.5, 'xx'), '0.5');
    });
  });

  group('formatSeconds', () {
    test('formats in the UI language', () {
      const latency = Duration(milliseconds: 820);
      expect(formatSeconds(latency), '0.8');
      expect(formatSeconds(latency, locale: 'de'), '0,8');
    });
  });
}
