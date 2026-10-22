import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The English (en-US) texts of the template, without metadata.
Map<String, String> _englishTexts() {
  final arb = jsonDecode(
    File('lib/l10n/arb/app_en.arb').readAsStringSync(),
  ) as Map<String, dynamic>;
  return {
    for (final MapEntry(:key, :value) in arb.entries)
      if (!key.startsWith('@') && value is String) key: value,
  };
}

void main() {
  group('English copy', () {
    final texts = _englishTexts();

    test('uses one (US) spelling', () {
      final british = RegExp(
        r'favour|colour|behaviour|\bgrey|cancelled|e-mail|optimis|'
        r'capitalis|customis|organis|recognis|licence|centre\b',
        caseSensitive: false,
      );
      final offending = {
        for (final MapEntry(:key, :value) in texts.entries)
          if (british.hasMatch(value)) key: value,
      };
      expect(offending, isEmpty);
    });

    test('favorites are marked with a heart, as everywhere in the app', () {
      final star = RegExp(r'\bstar\b', caseSensitive: false);
      final offending = {
        for (final MapEntry(:key, :value) in texts.entries)
          if (key.toLowerCase().contains('favorite') && star.hasMatch(value))
            key: value,
      };
      expect(offending, isEmpty);
    });

    test('the dictionary tabs are Meaning, Usage and Examples', () {
      expect(texts['dictionaryTabMeaning'], 'Meaning');
      expect(texts['dictionaryTabUsage'], 'Usage');
      expect(texts['dictionaryTabExamples'], 'Examples');
      expect(texts.containsKey('dictionaryTabMore'), isFalse);
    });
  });
}
