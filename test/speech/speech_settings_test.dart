import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/speech/speech_settings.dart';

void main() {
  group(SpeechSettings, () {
    const amelie = DeviceVoice(name: 'Amélie', locale: 'fr-CA');
    const yossi = DeviceVoice(name: 'Yossi', locale: 'he-IL');

    test('defaults to normal speed and default voices', () {
      const settings = SpeechSettings();

      expect(settings.rate, 1.0);
      expect(settings.voices, isEmpty);
      expect(settings.speed(), 1.0);
      expect(settings.speed(slow: true), SpeechSettings.slowFactor);
    });

    group('normalizeRate', () {
      test('clamps to 0.5x - 1.5x', () {
        expect(SpeechSettings.normalizeRate(0.1), 0.5);
        expect(SpeechSettings.normalizeRate(3), 1.5);
      });

      test('rounds to 0.1 steps', () {
        expect(SpeechSettings.normalizeRate(0.74), 0.7);
        expect(SpeechSettings.normalizeRate(1.25), 1.3);
        expect(SpeechSettings.normalizeRate(1.0000001), 1.0);
      });

      test('falls back to the default for NaN and infinity', () {
        expect(SpeechSettings.normalizeRate(double.nan), 1.0);
        expect(SpeechSettings.normalizeRate(double.infinity), 1.0);
      });
    });

    test('speed slows down relative to the rate', () {
      const settings = SpeechSettings(rate: 1.5);

      expect(settings.speed(), 1.5);
      expect(settings.speed(slow: true), closeTo(0.9, 1e-9));
    });

    group('voices', () {
      test('are looked up by device tag', () {
        const settings = SpeechSettings(voices: {'he': yossi});

        expect(settings.voiceFor('iw'), yossi);
        expect(settings.voiceFor('he'), yossi);
        expect(settings.voiceFor('fr'), isNull);
        expect(settings.voiceFor('auto'), isNull);
      });

      test('withVoice sets and clears the voice of a language', () {
        final settings = const SpeechSettings()
            .withVoice('iw', yossi)
            .withVoice('fr', amelie);

        expect(settings.voices, {'he': yossi, 'fr': amelie});
        expect(settings.withVoice('he', null).voices, {'fr': amelie});
        expect(() => settings.voices['de'] = amelie, throwsUnsupportedError);
      });

      test('withVoice ignores unspeakable languages', () {
        const settings = SpeechSettings();

        expect(settings.withVoice('Pirate speak', amelie), same(settings));
      });
    });

    test('copyWith replaces fields and normalises the rate', () {
      const settings = SpeechSettings(voices: {'fr': amelie});

      expect(settings.copyWith(), settings);
      expect(settings.copyWith(rate: 1.24).rate, 1.2);
      expect(settings.copyWith(rate: 1.24).voices, {'fr': amelie});
      expect(settings.copyWith(voices: const {}).voices, isEmpty);
    });

    group('JSON', () {
      test('round-trips through a string', () {
        const settings = SpeechSettings(
          rate: 0.8,
          voices: {'fr': amelie, 'he': yossi},
        );

        final json = jsonDecode(jsonEncode(settings.toJson()));

        expect(SpeechSettings.fromJson(json as Map<String, dynamic>), settings);
        expect(json['version'], SpeechSettings.schemaVersion);
      });

      test('falls back to defaults for missing or invalid fields', () {
        expect(SpeechSettings.fromJson(const {}), const SpeechSettings());
        expect(
          SpeechSettings.fromJson(const {'rate': 'fast', 'voices': 'none'}),
          const SpeechSettings(),
        );
      });

      test('clamps rates and accepts integers', () {
        expect(SpeechSettings.fromJson(const {'rate': 9}).rate, 1.5);
        expect(SpeechSettings.fromJson(const {'rate': 1}).rate, 1.0);
      });

      test('skips invalid voices and canonicalises their keys', () {
        final settings = SpeechSettings.fromJson({
          'voices': {
            'fr': amelie.toJson(),
            'iw': yossi.toJson(),
            'de': const {'name': 'Anna'},
            'Pirate speak': amelie.toJson(),
            'auto': amelie.toJson(),
          },
        });

        expect(settings.voices, {'fr': amelie, 'he': yossi});
      });
    });

    test('equality compares the voices deeply', () {
      expect(
        const SpeechSettings(voices: {'fr': amelie}),
        SpeechSettings(voices: Map.of(const {'fr': amelie})),
      );
      expect(
        const SpeechSettings(voices: {'fr': amelie}),
        isNot(const SpeechSettings(voices: {'fr': yossi})),
      );
    });
  });

  group('online voices', () {
    const google = DeviceVoice(
      name: 'Google français',
      locale: 'fr-FR',
      networkRequired: true,
    );

    test('are allowed one by one and saved', () {
      const settings = SpeechSettings();
      expect(settings.allowsOnlineVoice(google), isFalse);
      expect(settings.toJson(), isNot(contains('onlineVoices')));

      final allowed = settings.withOnlineVoice(google);
      expect(allowed.allowsOnlineVoice(google), isTrue);
      expect(allowed.toJson()['onlineVoices'], [google.id]);
      expect(SpeechSettings.fromJson(allowed.toJson()), allowed);
      expect(allowed, isNot(settings));
      expect(allowed.copyWith(rate: 1.2).onlineVoices, {google.id});
    });

    test('skip ids that are not strings', () {
      expect(
        SpeechSettings.fromJson(const {
          'onlineVoices': ['a', 1, '', null],
        }).onlineVoices,
        {'a'},
      );
      expect(
        SpeechSettings.fromJson(const {'onlineVoices': 'a'}).onlineVoices,
        isEmpty,
      );
    });
  });
}
