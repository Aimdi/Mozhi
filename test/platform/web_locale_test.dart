import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/web_locale.dart';

void main() {
  group('setWebDocumentLocale', () {
    test('forwards trimmed language tag to update callback', () {
      String? recorded;
      setWebDocumentLocale(' de-DE ', update: (tag) => recorded = tag);
      expect(recorded, 'de-DE');
    });

    test('ignores blank language tags', () {
      var called = false;
      setWebDocumentLocale('   ', update: (_) => called = true);
      expect(called, isFalse);
    });

    test('stub implementation is a safe no-op', () {
      expect(() => setWebDocumentLocale('en'), returnsNormally);
    });
  });
}
