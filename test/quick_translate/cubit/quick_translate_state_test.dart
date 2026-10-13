import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('QuickTranslateState', () {
    test('starts loading into English', () {
      const state = QuickTranslateState(text: 'Hello');
      expect(state.isLoading, isTrue);
      expect(state.isTranslating, isFalse);
      expect(state.target, const Language(code: 'en', name: 'English'));
      expect(state.translation, isEmpty);
      expect(state.detectedSource, isNull);
      expect(state.allowsCustomTarget, isFalse);
    });

    test('ignores a blank detected language', () {
      final state = readyState(
        translation: result('Hallo', detectedSource: ' '),
      );
      expect(state.detectedSource, isNull);
    });

    test('has a translation only when complete and not blank', () {
      expect(readyState(translation: result('Hallo')).hasTranslation, isTrue);
      expect(readyState(translation: result(' ')).hasTranslation, isFalse);
      expect(
        readyState(translation: result('Hal', isComplete: false))
            .hasTranslation,
        isFalse,
      );
      expect(
        readyState(
          status: QuickTranslateStatus.failure,
          translation: result('Hallo'),
        ).hasTranslation,
        isFalse,
      );
    });

    test('copyWith keeps and clears values', () {
      final state = readyState(
        translation: result('Hallo'),
        error: StateError('x'),
      );
      expect(state.copyWith(), state);
      final cleared = state.copyWith(
        result: () => null,
        error: () => null,
        engine: () => null,
      );
      expect(cleared.result, isNull);
      expect(cleared.error, isNull);
      expect(cleared.engine, isNull);
      expect(cleared.text, state.text);
      expect(cleared.target, state.target);
    });
  });
}
