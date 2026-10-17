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

    test('falls back to the language identified on the device', () {
      const state = QuickTranslateState(
        text: 'Hallo',
        offlineOnly: true,
        identifiedSource: 'de',
      );
      expect(state.detectedSource, 'de');
      expect(
        state.copyWith(result: () => result('Hi')).detectedSource,
        'en',
        reason: 'the translation reports its own detection',
      );
      expect(
        state
            .copyWith(result: () => result('Hi', detectedSource: ' '))
            .detectedSource,
        'de',
      );
      expect(
        const QuickTranslateState(
          text: 'Hallo',
          identifiedSource: ' ',
        ).detectedSource,
        isNull,
      );
    });

    test('is not offline only by default', () {
      const state = QuickTranslateState(text: 'Hello');
      expect(state.offlineOnly, isFalse);
      expect(state.identifiedSource, isNull);
      expect(state.offlineDownloads, isEmpty);
    });

    test('copyWith keeps and replaces the offline fields', () {
      const state = QuickTranslateState(
        text: 'Hallo',
        offlineOnly: true,
        identifiedSource: 'de',
        offlineDownloads: [(code: 'ja', name: 'Japanese', bytes: 25)],
      );
      expect(state.copyWith(), state);
      final next = state.copyWith(status: QuickTranslateStatus.success);
      expect(next.offlineOnly, isTrue);
      expect(next.identifiedSource, 'de');
      expect(next.offlineDownloads, state.offlineDownloads);
      expect(
        state.copyWith(identifiedSource: () => null).identifiedSource,
        isNull,
      );
      expect(state.copyWith(offlineDownloads: const []).offlineDownloads, []);
      expect(state, isNot(state.copyWith(identifiedSource: () => 'fr')));
      expect(state, isNot(const QuickTranslateState(text: 'Hallo')));
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
