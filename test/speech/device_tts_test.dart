import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/browser_voices.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

/// An [AudioOutput] that is never used (no Mozhi instance).
class _NoOutput extends Fake implements AudioOutput {
  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Scriptable stand-in for the `flutter_tts` plugin; records calls.
class _FakeFlutterTts extends Fake implements FlutterTts {
  final List<String> calls = [];
  VoidCallback? completion;
  VoidCallback? cancel;
  ErrorHandler? error;
  ProgressHandler? progress;

  /// Answers per call; an [Exception] answer is thrown.
  Object? Function(String tag) available = (_) => true;
  Object? Function(String tag) installed = (_) => false;
  Object? languages = const <String>[];

  /// `getVoices` answers, one per call (the last one repeats).
  List<Object?> voices = const [<Object?>[]];
  Object? setVoiceResult = 1;
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
  void setProgressHandler(ProgressHandler callback) => progress = callback;

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

  /// The `getEngines` answer; an [Exception] is thrown.
  Object? engines = const <Object?>['org.woheller69.ttsengine'];

  @override
  Future<dynamic> get getEngines async {
    calls.add('getEngines');
    return _answer(engines);
  }

  @override
  Future<dynamic> get getVoices async {
    calls.add('getVoices');
    final answer = voices.first;
    if (voices.length > 1) voices = voices.skip(1).toList();
    return _answer(answer);
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    calls.add('setVoice ${voice['name']} ${voice['locale']}');
    return _answer(setVoiceResult);
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

  /// Holds [speak] until completed (never: the plugin keeps a rejected
  /// `speak` waiting and never answers it).
  Completer<void>? speakGate;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    calls.add('speak $text');
    if (speakGate case final gate?) await gate.future;
    return _answer(speakResult);
  }

  /// The `getDefaultEngine` answer; an [Exception] is thrown.
  Object? defaultEngine = 'org.woheller69.ttsengine';

  /// Runs when `setEngine` binds the engine (e.g. voices appear).
  VoidCallback? onSetEngine;
  Object? setEngineResult = 1;

  @override
  Future<dynamic> get getDefaultEngine async {
    calls.add('getDefaultEngine');
    return _answer(defaultEngine);
  }

  @override
  Future<dynamic> setEngine(String engine) async {
    calls.add('setEngine $engine');
    onSetEngine?.call();
    return _answer(setEngineResult);
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
    Duration speakTimeout = const Duration(seconds: 5),
    List<BrowserVoice> browserVoices = const [],
  }) => FlutterTtsDeviceTts(
    createTts: () {
      created++;
      return tts;
    },
    platform: platform,
    isWeb: isWeb,
    settleTimeout: settleTimeout,
    speakTimeout: speakTimeout,
    webVoicesDelay: Duration.zero,
    browserVoices: () => browserVoices,
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
      double rate(
        TargetPlatform platform, {
        bool isWeb = false,
        bool slow = false,
      }) => FlutterTtsDeviceTts.speechRate(
        platform: platform,
        isWeb: isWeb,
        slow: slow,
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

      test('uses 1.0 / 0.6 for speechSynthesis on the web', () {
        expect(rate(TargetPlatform.iOS, isWeb: true), 1.0);
        expect(rate(TargetPlatform.android, isWeb: true, slow: true), 0.6);
      });

      double scaled(
        TargetPlatform platform,
        double speed, {
        bool isWeb = false,
        bool slow = false,
      }) => FlutterTtsDeviceTts.speechRate(
        platform: platform,
        isWeb: isWeb,
        slow: slow,
        rate: speed,
      );

      test('scales linearly with the rate on Android and Windows', () {
        for (final platform in [
          TargetPlatform.android,
          TargetPlatform.windows,
        ]) {
          expect(scaled(platform, 0.5), 0.25);
          expect(scaled(platform, 1.5), 0.75);
          expect(scaled(platform, 0.5, slow: true), 0.15);
        }
      });

      test('maps the rate gently around 0.5 on iOS and macOS', () {
        for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
          expect(scaled(platform, 0.5), 0.375);
          expect(scaled(platform, 1.5), 0.6);
          expect(scaled(platform, 1.5, slow: true), 0.475);
          expect(scaled(platform, 0.5, slow: true), 0.325);
        }
      });

      test('passes the rate through on the web', () {
        expect(scaled(TargetPlatform.android, 1.3, isWeb: true), 1.3);
        expect(scaled(TargetPlatform.iOS, 0.5, isWeb: true, slow: true), 0.3);
      });

      test('clamps rates the engines do not accept', () {
        expect(scaled(TargetPlatform.android, 4), 1);
        expect(scaled(TargetPlatform.android, 0), 0.05);
        expect(scaled(TargetPlatform.iOS, 0, isWeb: true), 0.1);
        expect(scaled(TargetPlatform.iOS, 20, isWeb: true), 10);
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
        tts
          ..available = ((_) => false)
          ..setLanguageResult = 0;
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

    group('setLanguage with a voice', () {
      const amelie = DeviceVoice(
        name: 'Amélie',
        locale: 'fr-CA',
        identifier: 'com.apple.voice.Amelie',
      );
      const thomas = DeviceVoice(name: 'Thomas', locale: 'fr-FR');

      late FlutterTtsDeviceTts device;

      setUp(() => device = deviceTts(platform: TargetPlatform.iOS));

      test('selects the voice after the language', () async {
        await device.setLanguage('fr', voice: amelie);

        expect(tts.calls, [
          'isLanguageAvailable fr',
          'setLanguage fr',
          'setVoice Amélie fr-CA',
        ]);
      });

      test('keeps the voice until it changes', () async {
        await device.setLanguage('fr', voice: amelie);
        tts.calls.clear();

        await device.setLanguage('fr', voice: amelie);
        expect(tts.calls, isEmpty);

        await device.setLanguage('fr', voice: thomas);
        expect(tts.calls, ['setVoice Thomas fr-FR']);
      });

      test('re-selects the language to restore the default voice', () async {
        await device.setLanguage('fr', voice: amelie);
        tts.calls.clear();

        await device.setLanguage('fr');
        await device.setLanguage('fr');

        expect(tts.calls, ['setLanguage fr']);
      });

      test('re-applies the voice after another language', () async {
        await device.setLanguage('fr', voice: amelie);
        await device.setLanguage('de');
        tts.calls.clear();

        await device.setLanguage('fr', voice: amelie);

        expect(tts.calls, ['setLanguage fr', 'setVoice Amélie fr-CA']);
      });

      test('falls back to the default voice when one is rejected', () async {
        await device.setLanguage('fr', voice: amelie);
        tts
          ..setVoiceResult = 0
          ..calls.clear();

        await device.setLanguage('fr', voice: thomas);
        expect(tts.calls, ['setVoice Thomas fr-FR', 'setLanguage fr']);

        // The default voice is selected, so the next attempt tries again.
        tts
          ..setVoiceResult = Exception('gone')
          ..calls.clear();
        await device.setLanguage('fr', voice: thomas);
        expect(tts.calls, ['setVoice Thomas fr-FR']);
      });
    });

    group('voices', () {
      test('lists the installed voices of the language, best first', () async {
        tts.voices = [
          [
            {'name': 'Thomas', 'locale': 'fr-FR'},
            {'name': 'Amélie', 'locale': 'fr-CA', 'quality': 'enhanced'},
            {'name': 'Anna', 'locale': 'de-DE'},
            {
              'name': 'fr-fr-x-new',
              'locale': 'fr-FR',
              'features': 'networkTimeoutMs\tnotInstalled',
            },
            {'name': 'Aurélie', 'locale': 'fr_FR'},
            {'locale': 'fr-FR'},
            'junk',
          ],
        ];
        final device = deviceTts();

        final voices = await device.voices('fr-FR');

        expect(voices.map((v) => v.name), ['Aurélie', 'Thomas', 'Amélie']);
        expect(voices.last.isHighQuality, isTrue);
      });

      test('is empty when the engine has no list or fails', () async {
        final device = deviceTts();

        tts.voices = [null];
        expect(await device.voices('fr'), isEmpty);

        tts.voices = [Exception('engine not ready')];
        expect(await device.voices('fr'), isEmpty);
      });

      test('is empty without a speech engine', () async {
        final device = deviceTts(platform: TargetPlatform.linux);

        expect(await device.voices('fr'), isEmpty);
        expect(created, 0);
      });

      test('waits once for the browser to load its voices', () async {
        tts.voices = [
          <Object?>[],
          [
            {'name': 'Google français', 'locale': 'fr-FR'},
          ],
        ];
        final device = deviceTts(isWeb: true);

        final voices = await device.voices('fr');

        expect(voices.single.name, 'Google français');
        expect(tts.calls, ['getVoices', 'getVoices']);
      });
    });

    group('online voices', () {
      const google = (
        name: 'Google français',
        lang: 'fr-FR',
        localService: false,
      );
      const thomas = (name: 'Thomas', lang: 'fr-FR', localService: true);
      Map<String, String> listed(BrowserVoice voice) => {
        'name': voice.name,
        'locale': voice.lang,
      };

      group('on the web', () {
        test('marks the voices that are no local service', () async {
          tts.voices = [
            [listed(google), listed(thomas)],
          ];
          final device = deviceTts(
            isWeb: true,
            browserVoices: [google, thomas],
          );

          final voices = await device.voices('fr');

          expect(
            {for (final v in voices) v.name: v.networkRequired},
            {'Google français': true, 'Thomas': false},
          );
          expect(voices.first.onlineProvider, 'Google');
        });

        test('reads with a voice on the device instead of an online '
            'default', () async {
          tts
            ..voices = [
              [
                listed(google),
                {'name': 'Anna', 'locale': 'de-DE'},
                listed(thomas),
              ],
            ]
            ..languages = const ['fr-FR', 'de-DE'];
          final device = deviceTts(
            isWeb: true,
            browserVoices: [google, thomas],
          );

          await device.setLanguage('fr');

          expect(tts.calls, contains('setVoice Thomas fr-FR'));
          expect(device.activeVoice?.name, 'Thomas');
          expect(device.activeVoice?.networkRequired, isFalse);
        });

        test('names the online default when the language has no other '
            'voice', () async {
          tts.voices = [
            [listed(google)],
          ];
          final device = deviceTts(isWeb: true, browserVoices: [google]);

          await device.setLanguage('fr');

          expect(tts.calls, isNot(contains(startsWith('setVoice'))));
          expect(device.activeVoice?.name, 'Google français');
          expect(device.activeVoice?.networkRequired, isTrue);
        });

        test('keeps a local default', () async {
          tts.voices = [
            [listed(thomas), listed(google)],
          ];
          final device = deviceTts(
            isWeb: true,
            browserVoices: [thomas, google],
          );

          await device.setLanguage('fr');

          expect(tts.calls, isNot(contains(startsWith('setVoice'))));
          expect(device.activeVoice?.name, 'Thomas');
        });

        test('knows whether a chosen voice is online now', () async {
          tts.voices = [
            [listed(google), listed(thomas)],
          ];
          final device = deviceTts(
            isWeb: true,
            browserVoices: [google, thomas],
          );

          // Chosen before online voices were told apart.
          await device.setLanguage(
            'fr',
            voice: const DeviceVoice(name: 'Google français', locale: 'fr-FR'),
          );

          expect(device.activeVoice?.networkRequired, isTrue);

          // Back to the default voice: the one on the device.
          await device.setLanguage('fr');
          expect(device.activeVoice?.name, 'Thomas');
        });

        test('a chosen voice that is not listed stays as it is', () async {
          tts.voices = [
            [listed(thomas)],
          ];
          final device = deviceTts(isWeb: true, browserVoices: [thomas]);
          const gone = DeviceVoice(name: 'Gone', locale: 'fr-FR');

          await device.setLanguage('fr', voice: gone);

          expect(device.activeVoice, gone);
        });

        test('a failing voice list leaves the default unknown', () async {
          tts.voices = [Exception('not ready')];
          final device = deviceTts(isWeb: true, browserVoices: [google]);

          await device.setLanguage('fr');
          expect(device.activeVoice, isNull);

          await device.setLanguage(
            'fr',
            voice: const DeviceVoice(name: 'Thomas', locale: 'fr-FR'),
          );
          expect(device.activeVoice?.name, 'Thomas');
        });
      });

      group('on Android', () {
        const network = {
          'name': 'fr-fr-x-frd-network',
          'locale': 'fr-FR',
          'network_required': '1',
        };

        test('names the online default without voice data', () async {
          tts.voices = [
            [network],
          ];
          final device = deviceTts();

          await device.setLanguage('fr-FR');

          expect(device.activeVoice?.name, 'fr-fr-x-frd-network');
          expect(device.activeVoice?.onlineProvider, 'Google');
        });

        test('trusts installed voice data', () async {
          tts
            ..installed = ((_) => true)
            ..voices = [
              [network],
            ];
          final device = deviceTts();

          await device.setLanguage('fr-FR');

          expect(device.activeVoice, isNull);
          expect(tts.calls, isNot(contains('getVoices')));
        });

        test('leaves the default unknown with a voice on the device', () async {
          tts.voices = [
            [
              network,
              {'name': 'fr-fr-x-frd-local', 'locale': 'fr-FR'},
            ],
          ];
          final device = deviceTts();

          await device.setLanguage('fr-FR');

          expect(device.activeVoice, isNull);
        });
      });

      test('elsewhere, a chosen voice is taken as it is', () async {
        final device = deviceTts(platform: TargetPlatform.iOS);
        const amelie = DeviceVoice(name: 'Amélie', locale: 'fr-CA');

        await device.setLanguage('fr');
        expect(device.activeVoice, isNull);

        await device.setLanguage('fr', voice: amelie);
        expect(device.activeVoice, amelie);
        expect(tts.calls, isNot(contains('getVoices')));
      });
    });

    test('setSpeechRate applies the platform rate once per change', () async {
      final device = deviceTts();

      await device.setSpeechRate(slow: false);
      await device.setSpeechRate(slow: false);
      await device.setSpeechRate(slow: true);
      await device.setSpeechRate(slow: false, rate: 1.2);

      expect(tts.calls, [
        'setSpeechRate 0.5',
        'setSpeechRate 0.3',
        'setSpeechRate 0.6',
      ]);
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

    group('progress', () {
      test('reports the word being read', () async {
        final device = deviceTts();
        final ranges = <SpokenRange>[];
        device.onProgress.listen(ranges.add);
        await device.speak('Hello world');
        tts.progress!('Hello world', 0, 5, 'Hello');
        tts.progress!('Hello world', 6, 11, 'world');
        await flush();

        expect(ranges, [const SpokenRange(0, 5), const SpokenRange(6, 11)]);
      });

      test('ends a web word at punctuation', () async {
        final device = deviceTts(isWeb: true);
        final ranges = <SpokenRange>[];
        device.onProgress.listen(ranges.add);
        await device.speak('我们今天去公园。明天');
        // The web plugin runs the word on to the next ASCII separator.
        tts.progress!('我们今天去公园。明天', 2, 10, '今天去公园。明天');
        await flush();

        expect(ranges, [const SpokenRange(2, 7)]);
      });

      test('drops Android 7’s report of the whole text', () async {
        final device = deviceTts();
        final ranges = <SpokenRange>[];
        device.onProgress.listen(ranges.add);
        await device.speak('Hello world');
        tts.progress!('Hello world', 0, 11, 'Hello world');
        await flush();

        expect(ranges, isEmpty);
      });

      test('ignores other texts and reports while nothing speaks', () async {
        final device = deviceTts();
        final ranges = <SpokenRange>[];
        device.onProgress.listen(ranges.add);
        await device.speak('one two');
        tts.progress!('another text', 0, 7, 'another');
        tts.completion!();
        tts.progress!('one two', 4, 7, 'two');
        await device.speak('three four');
        await device.stop();
        tts.progress!('three four', 0, 5, 'three');
        await flush();

        expect(ranges, isEmpty);
      });

      test('the stream closes with the engine', () async {
        final device = deviceTts();
        final done = Completer<void>();
        device.onProgress.listen(null, onDone: done.complete);
        await device.speak('one');
        await device.dispose();
        tts.progress!('one', 0, 3, 'one');
        await done.future;
      });
    });
    group('hasEngine', () {
      test('tells whether Android lists any speech engine', () async {
        final device = deviceTts();

        expect(await device.hasEngine(), isTrue);
        tts.engines = const <Object?>[];
        expect(await device.hasEngine(), isFalse);
        expect(tts.calls, ['getEngines', 'getEngines']);
      });

      test('is unknown when the list fails or is not a list', () async {
        final device = deviceTts();

        tts.engines = Exception('no engine service');
        expect(await device.hasEngine(), isNull);
        tts.engines = null;
        expect(await device.hasEngine(), isNull);
      });

      test('is unknown off Android, without touching the plugin', () async {
        for (final device in [
          deviceTts(platform: TargetPlatform.iOS),
          deviceTts(isWeb: true),
          deviceTts(platform: TargetPlatform.linux),
        ]) {
          expect(await device.hasEngine(), isNull);
        }
        expect(created, 0);
      });
    });
  });

  group('a speech engine installed while the app runs (Android)', () {
    const sherpa = 'org.woheller69.ttsengine';
    const voice = {'name': 'de-thorsten', 'locale': 'de-DE'};

    /// The plugin's instance from the app's start, bound to no engine:
    /// nothing is available or listed until it is bound again.
    void deadUntilBound() {
      var bound = false;
      tts
        ..available = ((_) => bound)
        ..voices = const [<Object?>[]]
        ..onSetEngine = () {
          bound = true;
          tts.voices = const [
            [voice],
          ];
        };
    }

    test('binds the engine again and finds the language', () async {
      deadUntilBound();
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isTrue);
      expect(
        tts.calls,
        containsAllInOrder(['getEngines', 'setEngine $sherpa']),
      );
      expect(tts.calls.last, 'isLanguageAvailable de');
    });

    test('lists the voices after binding again', () async {
      deadUntilBound();
      final device = deviceTts();

      final voices = await device.voices('de');

      expect(voices.map((v) => v.name), ['de-thorsten']);
      expect(tts.calls, contains('setEngine $sherpa'));
    });

    test('binds once per set of engines', () async {
      tts
        ..available = ((_) => false)
        ..voices = const [<Object?>[]];
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isFalse);
      expect(await device.isLanguageAvailable('xx'), isFalse);
      expect(tts.calls.where((c) => c.startsWith('setEngine')), hasLength(1));

      // Another engine installed: bound again.
      tts.engines = const [sherpa, 'com.k2fsa.sherpa.onnx.tts.engine'];
      expect(await device.isLanguageAvailable('de'), isFalse);
      expect(tts.calls.where((c) => c.startsWith('setEngine')), hasLength(2));
    });

    test('binds the engine installed after there was none', () async {
      deadUntilBound();
      tts.engines = const <Object?>[];
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isFalse);
      expect(tts.calls.where((c) => c.startsWith('setEngine')), isEmpty);

      tts.engines = const [sherpa];
      expect(await device.isLanguageAvailable('de'), isTrue);
    });

    test('picks the first engine when the default is not installed', () async {
      deadUntilBound();
      tts
        ..defaultEngine = 'com.google.android.tts'
        ..engines = const ['org.rhvoice', sherpa];
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isTrue);
      expect(tts.calls, contains('setEngine org.rhvoice'));
    });

    test('keeps an instance that works', () async {
      tts
        ..available = ((tag) => tag == 'fr')
        ..voices = const [
          [voice],
        ];
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isFalse);
      expect(tts.calls.where((c) => c.startsWith('setEngine')), isEmpty);
    });

    test('a failing binding is not fatal', () async {
      tts
        ..available = ((_) => false)
        ..setEngineResult = Exception('TtsError');
      final device = deviceTts();

      expect(await device.isLanguageAvailable('de'), isFalse);
      tts.engines = Exception('no package manager');
      expect(await device.isLanguageAvailable('de'), isFalse);
    });
  });

  group('a speak the engine never answers', () {
    test('fails after the timeout instead of waiting for ever', () async {
      tts.speakGate = Completer<void>();
      final device = deviceTts(speakTimeout: const Duration(milliseconds: 10));

      await expectLater(
        device.speak('Hallo'),
        throwsA(isA<DeviceTtsNoAnswerException>()),
      );
    });

    test('binds the engine again before the next language and stops what it '
        'held back', () async {
      tts.speakGate = Completer<void>();
      final device = deviceTts(speakTimeout: const Duration(milliseconds: 10));
      await device.setLanguage('de');
      await expectLater(
        device.speak('Hallo'),
        throwsA(isA<DeviceTtsNoAnswerException>()),
      );
      tts
        ..speakGate = null
        ..calls.clear();

      await device.setLanguage('de');
      await device.speak('Hallo');

      expect(tts.calls, [
        'getEngines',
        'getDefaultEngine',
        'setEngine org.woheller69.ttsengine',
        'stop',
        'isLanguageInstalled de',
        'isLanguageAvailable de',
        'setLanguage de',
        'getVoices',
        'speak Hallo',
      ]);
    });
  });

  group("Listen with the app's speech service (Android)", () {
    late _MockTranslationRepository repository;
    final l10n = lookupAppLocalizations(const Locale('en'));

    setUp(() {
      repository = _MockTranslationRepository();
      when(() => repository.instances).thenReturn(const []);
    });

    SpeechService service({
      Duration speakTimeout = const Duration(seconds: 5),
    }) {
      final created = SpeechService(
        repository: repository,
        output: _NoOutput(),
        deviceTts: deviceTts(speakTimeout: speakTimeout),
      );
      addTearDown(created.dispose);
      return created;
    }

    test('reads with a speech engine installed while the app ran', () async {
      var bound = false;
      tts
        ..available = ((_) => bound)
        ..onSetEngine = () => bound = true;
      final speech = service();

      await speech.toggle(id: 'target', text: 'Hallo', languageCode: 'de');

      expect(tts.calls, contains('speak Hallo'));
      expect(speech.current, 'target');
    });

    test('an engine that never answers ends with a message, not a stuck '
        'Stop', () async {
      tts.speakGate = Completer<void>();
      final speech = service(speakTimeout: const Duration(milliseconds: 10));

      Object? error;
      try {
        await speech.toggle(id: 'target', text: 'Hallo', languageCode: 'de');
      } on Object catch (caught) {
        error = caught;
      }

      expect(error, isA<SpeechUnavailableException>());
      expect(speechErrorMessage(l10n, error!), l10n.speechEngineNoAnswer);
      expect(speech.current, isNull);
    });
  });
}
