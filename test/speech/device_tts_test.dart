import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/device_tts.dart';

/// Scriptable stand-in for the `flutter_tts` plugin; records calls.
class _FakeFlutterTts extends Fake implements FlutterTts {
  final List<String> calls = [];
  VoidCallback? completion;
  VoidCallback? cancel;
  ErrorHandler? error;

  /// Answers per call; an [Exception] answer is thrown.
  Object? Function(String tag) available = (_) => true;
  Object? Function(String tag) installed = (_) => false;
  Object? languages = const <String>[];
  Object? setLanguageResult = 1;
  Object? speakResult = 1;
  Exception? audioCategoryError;

  Object? _answer(Object? value) {
    if (value is Exception) throw value;
    return value;
  }

  @override
  void setCompletionHandler(VoidCallback callback) => completion = callback;

  @override
  void setCancelHandler(VoidCallback callback) => cancel = callback;

  @override
  void setErrorHandler(ErrorHandler handler) => error = handler;

  @override
  Future<dynamic> isLanguageAvailable(String language) async {
    calls.add('isLanguageAvailable $language');
    return _answer(available(language));
  }

  @override
  Future<dynamic> isLanguageInstalled(String language) async {
    calls.add('isLanguageInstalled $language');
    return _answer(installed(language));
  }

  @override
  Future<dynamic> get getLanguages async {
    calls.add('getLanguages');
    return _answer(languages);
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    calls.add('setLanguage $language');
    return setLanguageResult;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    calls.add('setSpeechRate $rate');
    return 1;
  }

  @override
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) async {
    calls.add(
      'setIosAudioCategory ${category.name} '
      '${options.map((o) => o.name).join(',')} ${mode.name}',
    );
    return _answer(audioCategoryError ?? 1);
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    calls.add('speak $text');
    return _answer(speakResult);
  }

  @override
  Future<dynamic> stop() async {
    calls.add('stop');
    return 1;
  }
}

void main() {
  late _FakeFlutterTts tts;
  late int created;

  FlutterTtsDeviceTts deviceTts({
    TargetPlatform platform = TargetPlatform.android,
    bool isWeb = false,
    Duration settleTimeout = const Duration(seconds: 5),
  }) => FlutterTtsDeviceTts(
    createTts: () {
      created++;
      return tts;
    },
    platform: platform,
    isWeb: isWeb,
    settleTimeout: settleTimeout,
    webVoicesDelay: Duration.zero,
  );

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tts = _FakeFlutterTts();
    created = 0;
  });

  group(FlutterTtsDeviceTts, () {
    test('can be created and disposed without touching the plugin', () async {
      final device = FlutterTtsDeviceTts();

      await device.stop();
      await device.dispose();
    });

    group('speechRate', () {
      double rate(TargetPlatform platform, {bool isWeb = false, bool? slow}) =>
          FlutterTtsDeviceTts.speechRate(
            platform: platform,
            isWeb: isWeb,
            slow: slow ?? false,
          );

      test('uses 0.5 / 0.3 on Android and Windows', () {
        for (final platform in [
          TargetPlatform.android,
          TargetPlatform.windows,
        ]) {
          expect(rate(platform), 0.5);
          expect(rate(platform, slow: true), 0.3);
        }
      });

      test('uses 0.5 / 0.4 for AVSpeechSynthesizer on iOS and macOS', () {
        for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
          expect(rate(platform), 0.5);
          expect(rate(platform, slow: true), 0.4);
        }
      });

      test('uses 1.0 / 0.7 for speechSynthesis on the web', () {
        expect(rate(TargetPlatform.iOS, isWeb: true), 1.0);
        expect(rate(TargetPlatform.android, isWeb: true, slow: true), 0.7);
      });
    });

    test('is supported where flutter_tts has an implementation', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        expect(deviceTts(platform: platform).isSupported, isTrue);
      }
      expect(
        deviceTts(platform: TargetPlatform.linux, isWeb: true).isSupported,
        isTrue,
      );
      expect(deviceTts(platform: TargetPlatform.linux).isSupported, isFalse);
      expect(deviceTts(platform: TargetPlatform.fuchsia).isSupported, isFalse);
    });

    group('on an unsupported platform', () {
      late FlutterTtsDeviceTts device;

      setUp(() => device = deviceTts(platform: TargetPlatform.linux));

      test('reports no language without creating the plugin', () async {
        expect(await device.isLanguageAvailable('en'), isFalse);
        expect(created, 0);
      });

      test('throws when asked to speak', () async {
        await expectLater(
          device.speak('Hello'),
          throwsA(isA<DeviceTtsException>()),
        );
        expect(created, 0);
      });
    });

    test('creates the plugin lazily, once, and registers handlers', () async {
      final device = deviceTts(platform: TargetPlatform.iOS);
      expect(created, 0);

      await device.isLanguageAvailable('en');
      await device.setSpeechRate(slow: false);

      expect(created, 1);
      expect(tts.completion, isNotNull);
      expect(tts.cancel, isNotNull);
      expect(tts.error, isNotNull);
    });

    group('isLanguageAvailable', () {
      test('asks the engine on iOS and macOS', () async {
        tts.available = (tag) => tag == 'fr';
        final device = deviceTts(platform: TargetPlatform.macOS);

        expect(await device.isLanguageAvailable('fr'), isTrue);
        expect(await device.isLanguageAvailable('de'), isFalse);
        expect(tts.calls, ['isLanguageAvailable fr', 'isLanguageAvailable de']);
      });

      test('caches available languages but re-checks missing ones', () async {
        tts.available = (tag) => tag == 'fr';
        final device = deviceTts(platform: TargetPlatform.iOS);

        await device.isLanguageAvailable('fr');
        await device.isLanguageAvailable('fr');
        await device.isLanguageAvailable('de');
        await device.isLanguageAvailable('de');

        expect(tts.calls, [
          'isLanguageAvailable fr',
          'isLanguageAvailable de',
          'isLanguageAvailable de',
        ]);
      });

      test('is false when the engine fails', () async {
        tts.available = (_) => Exception('engine not ready');
        final device = deviceTts(platform: TargetPlatform.iOS);

        expect(await device.isLanguageAvailable('fr'), isFalse);
      });

      group('on Android', () {
        test('prefers installed (offline) voices', () async {
          tts.installed = (_) => true;
          final device = deviceTts();

          expect(await device.isLanguageAvailable('fr-FR'), isTrue);
          expect(tts.calls, ['isLanguageInstalled fr-FR']);
        });

        test('falls back to isLanguageAvailable', () async {
          tts.available = (tag) => tag == 'fr';
          final device = deviceTts();

          expect(await device.isLanguageAvailable('fr'), isTrue);
          expect(await device.isLanguageAvailable('de'), isFalse);
          expect(tts.calls, [
            'isLanguageInstalled fr',
            'isLanguageAvailable fr',
            'isLanguageInstalled de',
            'isLanguageAvailable de',
          ]);
        });

        test('treats a failing installed check as not installed', () async {
          tts.installed = (_) => Exception('voices not loaded');
          final device = deviceTts();

          expect(await device.isLanguageAvailable('fr'), isTrue);
        });
      });

      group('on Windows', () {
        test('matches the tag against the engine languages', () async {
          tts.languages = ['en-US', 'fr-FR', 42];
          final device = deviceTts(platform: TargetPlatform.windows);

          expect(await device.isLanguageAvailable('fr'), isTrue);
          expect(await device.isLanguageAvailable('de'), isFalse);
          expect(tts.calls, ['getLanguages', 'getLanguages']);
        });

        test('handles a missing language list', () async {
          tts.languages = null;
          final device = deviceTts(platform: TargetPlatform.windows);

          expect(await device.isLanguageAvailable('en'), isFalse);
        });

        test('selects the matching engine language', () async {
          tts.languages = ['en-US', 'en-GB'];
          final device = deviceTts(platform: TargetPlatform.windows);

          await device.setLanguage('en');

          expect(tts.calls, ['getLanguages', 'setLanguage en-US']);
        });
      });

      group('on the web', () {
        test('re-checks once while the browser loads voices', () async {
          var answers = [false, true];
          tts.available = (_) {
            final answer = answers.first;
            answers = answers.skip(1).toList();
            return answer;
          };
          final device = deviceTts(isWeb: true);

          expect(await device.isLanguageAvailable('fr'), isTrue);
          expect(tts.calls, [
            'isLanguageAvailable fr',
            'isLanguageAvailable fr',
          ]);
        });

        test('stops re-checking once voices have loaded', () async {
          tts.available = (tag) => tag == 'fr';
          final device = deviceTts(isWeb: true);

          await device.isLanguageAvailable('fr');
          tts.calls.clear();
          expect(await device.isLanguageAvailable('de'), isFalse);

          expect(tts.calls, ['isLanguageAvailable de']);
        });

        test('re-checks every miss while no voice was found', () async {
          tts.available = (_) => false;
          final device = deviceTts(isWeb: true);

          expect(await device.isLanguageAvailable('de'), isFalse);
          expect(await device.isLanguageAvailable('de'), isFalse);

          expect(tts.calls, hasLength(4));
        });
      });
    });

    group('setLanguage', () {
      test('sets the tag once until it changes', () async {
        final device = deviceTts(platform: TargetPlatform.iOS);

        await device.setLanguage('fr');
        await device.setLanguage('fr');
        await device.setLanguage('de');

        expect(tts.calls, [
          'isLanguageAvailable fr',
          'setLanguage fr',
          'isLanguageAvailable de',
          'setLanguage de',
        ]);
      });

      test('passes unknown tags through and throws when rejected', () async {
        tts..available = (_) => false..setLanguageResult = 0;
        final device = deviceTts(platform: TargetPlatform.iOS);

        await expectLater(
          device.setLanguage('xx'),
          throwsA(
            isA<DeviceTtsException>().having(
              (e) => e.toString(),
              'toString',
              contains('xx'),
            ),
          ),
        );
        expect(tts.calls.last, 'setLanguage xx');

        tts.setLanguageResult = 1;
        await device.setLanguage('xx');
        expect(tts.calls.last, 'setLanguage xx');
      });
    });

    test('setSpeechRate applies the platform rate once per change', () async {
      final device = deviceTts();

      await device.setSpeechRate(slow: false);
      await device.setSpeechRate(slow: false);
      await device.setSpeechRate(slow: true);

      expect(tts.calls, ['setSpeechRate 0.5', 'setSpeechRate 0.3']);
    });

    group('speak', () {
      test('hands the text to the engine', () async {
        final device = deviceTts();

        await device.speak('Bonjour');

        expect(tts.calls, ['speak Bonjour']);
      });

      test('uses the speaker session on iOS', () async {
        final device = deviceTts(platform: TargetPlatform.iOS);

        await device.speak('Bonjour');

        expect(tts.calls, [
          'setIosAudioCategory playback duckOthers spokenAudio',
          'speak Bonjour',
        ]);
      });

      test('still speaks when the iOS session cannot be set', () async {
        tts.audioCategoryError = Exception('session busy');
        final device = deviceTts(platform: TargetPlatform.iOS);

        await device.speak('Bonjour');

        expect(tts.calls.last, 'speak Bonjour');
      });

      test('throws when the engine rejects the text', () async {
        tts.speakResult = 0;
        final device = deviceTts();
        final events = <void>[];
        device.onComplete.listen(events.add);

        await expectLater(
          device.speak('Bonjour'),
          throwsA(isA<DeviceTtsException>()),
        );
        tts.error!('failed');
        await flush();

        expect(events, isEmpty);
      });

      test('rethrows engine errors', () async {
        tts.speakResult = Exception('channel');
        final device = deviceTts();

        await expectLater(device.speak('Bonjour'), throwsException);
      });
    });

    group('onComplete', () {
      late FlutterTtsDeviceTts device;
      late List<void> events;

      setUp(() async {
        device = deviceTts();
        events = [];
        device.onComplete.listen(events.add);
        await device.speak('Bonjour');
      });

      test('emits when the utterance finishes', () async {
        tts.completion!();
        await flush();

        expect(events, hasLength(1));
      });

      test('emits when the engine fails mid-utterance', () async {
        tts.error!('synthesis failed');
        await flush();

        expect(events, hasLength(1));
      });

      test('emits once per utterance', () async {
        tts
          ..error!('interrupted')
          ..completion!();
        await flush();

        expect(events, hasLength(1));
      });

      test('swallows the cancel event of a stopped utterance', () async {
        await device.stop();
        tts.cancel!();
        await flush();

        expect(events, isEmpty);
        expect(tts.calls.last, 'stop');
      });

      test('is quiet after dispose', () async {
        await device.dispose();
        tts.completion!();

        expect(events, isEmpty);
        expect(tts.calls.last, 'stop');
      });
    });

    group('after stop', () {
      test('speak waits for the stopped utterance to end', () async {
        final device = deviceTts(isWeb: true);
        final events = <void>[];
        device.onComplete.listen(events.add);
        await device.speak('one');
        await device.stop();

        final speaking = device.speak('two');
        await flush();
        expect(tts.calls.last, 'stop');

        tts.error!('interrupted');
        await speaking;
        expect(tts.calls.last, 'speak two');

        tts.completion!();
        await flush();
        expect(events, hasLength(1));
      });

      test('speak gives up waiting after the settle timeout', () async {
        final device = deviceTts(settleTimeout: Duration.zero);
        final events = <void>[];
        device.onComplete.listen(events.add);
        await device.speak('one');
        await device.stop();

        await device.speak('two');
        expect(tts.calls.last, 'speak two');

        tts.completion!();
        await flush();
        expect(events, hasLength(1));
      });

      test('stop while idle expects no cancel event', () async {
        final device = deviceTts();
        final events = <void>[];
        device.onComplete.listen(events.add);
        await device.speak('one');
        tts.completion!();
        await device.stop();

        await device.speak('two');
        tts.completion!();
        await flush();

        expect(events, hasLength(2));
      });
    });

    test('dispose of an idle engine does not stop it', () async {
      final device = deviceTts();
      await device.speak('one');
      tts.completion!();

      await device.dispose();

      expect(tts.calls, ['speak one']);
    });
  });
}
