// Not required for test files
// ignore_for_file: prefer_const_constructors

import 'package:flutter_test/flutter_test.dart';
import 'package:mlkit_translator/mlkit_translator.dart';

void main() {
  group('MlkitTranslator', () {
    test('can be instantiated', () {
      expect(MlkitTranslator(), isNotNull);
    });
  });
}
