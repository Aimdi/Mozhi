import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_bindings.dart';

void main() {
  late FakeBindings bindings;
  late MlKitOfflineTranslator translator;

  MlKitOfflineTranslator create({
    bool available = true,
    Set<String> downloaded = const {'en', 'de', 'fr', 'es', 'pt', 'zh'},
  }) {
    bindings = FakeBindings(downloaded: downloaded);
    return translator = MlKitOfflineTranslator(
      bindings: bindings,
      isAvailable: available,
    );
  }

  setUp(create);

  group('MlKitOfflineTranslator', () {
    group('isAvailable', () {
      test('honours the injected value', () {
        expect(create().isAvailable, isTrue);
        expect(create(available: false).isAvailable, isFalse);
      });

      test('is true on Android and iOS only by default', () {
        final defaults = MlKitOfflineTranslator(bindings: FakeBindings());
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        for (final platform in TargetPlatform.values) {
          debugDefaultTargetPlatformOverride = platform;
          final expected =
              platform == TargetPlatform.android ||
              platform == TargetPlatform.iOS;
          expect(defaults.isAvailable, expected, reason: '$platform');
          expect(MlKitOfflineTranslator.isPlatformSupported, expected);
        }
      });
    });

    test('supportedLanguages are the ML Kit model codes', () {
      expect(translator.supportedLanguages, MlKitLanguageCodes.supported);
      expect(translator.supportedLanguages, hasLength(59));
    });

    group('downloadedLanguages', () {
      test('checks every supported model', () async {
        expect(await translator.downloadedLanguages(), {
          'en',
          'de',
          'fr',
          'es',
          'pt',
          'zh',
        });
        expect(
          bindings.calls.where((c) => c.startsWith('check:')),
          hasLength(59),
        );
      });

      test('is empty without touching the plugin when unavailable', () async {
        create(available: false);
        expect(await translator.downloadedLanguages(), isEmpty);
        expect(bindings.calls, isEmpty);
      });
    });

    group('downloadLanguage', () {
      test('downloads the mapped model over Wi-Fi by default', () async {
        await translator.downloadLanguage('nb-NO');
        expect(bindings.calls, ['download:no:wifi=true']);
        expect(bindings.downloaded, contains('no'));
      });

      test('passes wifiOnly: false', () async {
        await translator.downloadLanguage('zh-TW', wifiOnly: false);
        expect(bindings.calls, ['download:zh:wifi=false']);
      });

      test('throws MlKitModelException when the plugin fails', () async {
        bindings.downloadResult = false;
        await expectLater(
          translator.downloadLanguage('ja'),
          throwsA(
            isA<MlKitModelException>()
                .having((e) => e.operation, 'operation', 'download')
                .having((e) => e.language, 'language', 'ja')
                .having((e) => '$e', 'toString', contains('download ja')),
          ),
        );
      });

      test('rejects unsupported languages', () async {
        await expectLater(
          translator.downloadLanguage('sr-Latn'),
          throwsA(
            isA<OfflineLanguageUnsupportedException>().having(
              (e) => e.language,
              'language',
              'sr-Latn',
            ),
          ),
        );
        expect(bindings.calls, isEmpty);
      });

      test('throws UnsupportedError when unavailable', () async {
        create(available: false);
        await expectLater(
          translator.downloadLanguage('de'),
          throwsUnsupportedError,
        );
        expect(bindings.calls, isEmpty);
      });
    });

    group('deleteLanguage', () {
      test('deletes the mapped model', () async {
        await translator.deleteLanguage('iw');
        expect(bindings.calls, ['delete:he']);
      });

      test('closes cached translators that use the model', () async {
        await translator.translate('a', source: 'en', target: 'de');
        await translator.translate('b', source: 'fr', target: 'es');
        await translator.translate('c', source: 'de', target: 'fr');
        await translator.deleteLanguage('de');
        expect(bindings.translators.map((t) => t.closed), [true, false, true]);
        expect(translator.cachedTranslatorCount, 1);
        expect(bindings.downloaded, isNot(contains('de')));
      });

      test('throws MlKitModelException when the plugin fails', () async {
        bindings.deleteResult = false;
        await expectLater(
          translator.deleteLanguage('fr'),
          throwsA(
            isA<MlKitModelException>()
                .having((e) => e.operation, 'operation', 'delete')
                .having((e) => e.language, 'language', 'fr'),
          ),
        );
      });

      test('rejects unsupported languages', () async {
        await expectLater(
          translator.deleteLanguage('xx'),
          throwsA(isA<OfflineLanguageUnsupportedException>()),
        );
      });

      test('throws UnsupportedError when unavailable', () async {
        create(available: false);
        await expectLater(
          translator.deleteLanguage('de'),
          throwsUnsupportedError,
        );
      });
    });

    group('translate', () {
      test('translates with the mapped codes', () async {
        expect(
          await translator.translate('Hello', source: 'en-GB', target: 'pt-BR'),
          '[en>pt] Hello',
        );
        expect(bindings.calls, ['check:en', 'check:pt', 'create:en>pt']);
      });

      test('throws OfflineModelMissingException without downloading', () async {
        create(downloaded: {'en'});
        await expectLater(
          translator.translate('Hallo', source: 'de', target: 'en'),
          throwsA(
            isA<OfflineModelMissingException>().having(
              (e) => e.languages,
              'languages',
              ['de'],
            ),
          ),
        );
        expect(bindings.calls, ['check:de', 'check:en']);
        expect(bindings.translators, isEmpty);
      });

      test('lists every missing model', () async {
        create(downloaded: {});
        await expectLater(
          translator.translate('x', source: 'ja', target: 'zh-Hant'),
          throwsA(
            isA<OfflineModelMissingException>().having(
              (e) => e.languages,
              'languages',
              ['ja', 'zh'],
            ),
          ),
        );
        expect(bindings.calls.where((c) => !c.startsWith('check:')), isEmpty);
      });

      test('rejects unsupported languages', () async {
        await expectLater(
          translator.translate('x', source: 'en', target: 'Pirate speak'),
          throwsA(
            isA<OfflineLanguageUnsupportedException>().having(
              (e) => e.language,
              'language',
              'Pirate speak',
            ),
          ),
        );
        await expectLater(
          translator.translate('x', source: 'la', target: 'en'),
          throwsA(isA<OfflineLanguageUnsupportedException>()),
        );
        expect(bindings.calls, isEmpty);
      });

      test('returns blank text and same-language text unchanged', () async {
        expect(
          await translator.translate('  ', source: 'en', target: 'de'),
          '  ',
        );
        expect(
          await translator.translate('Hi', source: 'en-US', target: 'en-GB'),
          'Hi',
        );
        expect(bindings.calls, isEmpty);
      });

      test('throws UnsupportedError when unavailable', () async {
        create(available: false);
        await expectLater(
          translator.translate('x', source: 'en', target: 'de'),
          throwsUnsupportedError,
        );
      });

      group('with source auto', () {
        test('identifies the source language first', () async {
          bindings.identified = 'fr';
          expect(
            await translator.translate('Bonjour', source: 'auto', target: 'de'),
            '[fr>de] Bonjour',
          );
          expect(bindings.identifiers.single.texts, ['Bonjour']);
        });

        test('treats an empty source like auto', () async {
          create(downloaded: {'he', 'en'});
          bindings.identified = 'iw';
          expect(
            await translator.translate('שלום', source: '', target: 'en'),
            '[he>en] שלום',
          );
        });

        test('throws when the language is undetermined', () async {
          bindings.identified = 'und';
          await expectLater(
            translator.translate('???', source: 'auto', target: 'de'),
            throwsA(
              isA<OfflineLanguageUnsupportedException>().having(
                (e) => e.language,
                'language',
                'auto',
              ),
            ),
          );
        });

        test('throws when the detected language has no model', () async {
          bindings.identified = 'yo';
          await expectLater(
            translator.translate('Ẹ n lẹ', source: 'auto', target: 'en'),
            throwsA(
              isA<OfflineLanguageUnsupportedException>().having(
                (e) => e.language,
                'language',
                'yo',
              ),
            ),
          );
        });

        test('returns text unchanged when it already is the target', () async {
          bindings.identified = 'de';
          expect(
            await translator.translate('Hallo', source: 'auto', target: 'de'),
            'Hallo',
          );
          expect(bindings.translators, isEmpty);
        });
      });

      group('translator cache', () {
        test('reuses the translator of a pair', () async {
          await translator.translate('a', source: 'en', target: 'de');
          await translator.translate('b', source: 'en-US', target: 'de-AT');
          expect(bindings.translators, hasLength(1));
          expect(bindings.translators.single.texts, ['a', 'b']);
        });

        test('keeps the three most recently used pairs', () async {
          await translator.translate('1', source: 'en', target: 'de');
          await translator.translate('2', source: 'en', target: 'fr');
          await translator.translate('3', source: 'en', target: 'es');
          // Touch en>de so en>fr becomes the least recently used pair.
          await translator.translate('4', source: 'en', target: 'de');
          await translator.translate('5', source: 'de', target: 'en');
          await pumpEventQueue();

          final [enDe, enFr, enEs, deEn] = bindings.translators;
          expect(enFr.closed, isTrue);
          expect([enDe, enEs, deEn].map((t) => t.closed), everyElement(false));
          expect(translator.cachedTranslatorCount, 3);

          await translator.translate('6', source: 'en', target: 'fr');
          expect(bindings.translators, hasLength(5));
        });

        test('honours maxCachedTranslators', () async {
          bindings = FakeBindings(downloaded: {'en', 'de', 'fr'});
          translator = MlKitOfflineTranslator(
            bindings: bindings,
            isAvailable: true,
            maxCachedTranslators: 1,
          );
          await translator.translate('1', source: 'en', target: 'de');
          await translator.translate('2', source: 'en', target: 'fr');
          await pumpEventQueue();
          expect(bindings.translators.first.closed, isTrue);
          expect(translator.cachedTranslatorCount, 1);
        });

        test('closes an evicted translator only after it finished', () async {
          bindings = FakeBindings(downloaded: {'en', 'de', 'fr'});
          translator = MlKitOfflineTranslator(
            bindings: bindings,
            isAvailable: true,
            maxCachedTranslators: 1,
          );
          final gate = bindings.translateGate = Completer<void>();
          final running = translator.translate('1', source: 'en', target: 'de');
          await pumpEventQueue();
          bindings.translateGate = null;
          await translator.translate('2', source: 'en', target: 'fr');
          await pumpEventQueue();
          expect(bindings.translators.first.closed, isFalse);

          gate.complete();
          expect(await running, '[en>de] 1');
          await pumpEventQueue();
          expect(bindings.translators.first.closed, isTrue);
        });

        test('reports close errors instead of throwing them', () async {
          final reported = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = reported.add;
          addTearDown(() => FlutterError.onError = previous);

          bindings.closeError = Exception('boom');
          await translator.translate('1', source: 'en', target: 'de');
          await translator.dispose();
          expect(reported, hasLength(1));
          expect(reported.single.library, 'mlkit_translator');
        });
      });
    });

    group('identifyLanguage', () {
      test('normalises the identified code', () async {
        bindings.identified = 'iw';
        expect(await translator.identifyLanguage('שלום'), 'he');
        bindings.identified = 'ja-Latn';
        expect(await translator.identifyLanguage('konnichiwa'), 'ja-Latn');
        expect(bindings.calls.where((c) => c.startsWith('identifier:')), [
          'identifier:0.5',
        ]);
      });

      test("maps 'und' to null", () async {
        bindings.identified = 'und';
        expect(await translator.identifyLanguage('1234'), isNull);
      });

      test('uses the confidence threshold', () async {
        bindings = FakeBindings();
        translator = MlKitOfflineTranslator(
          bindings: bindings,
          isAvailable: true,
          confidenceThreshold: 0.8,
        );
        await translator.identifyLanguage('Hello there');
        expect(bindings.calls, ['identifier:0.8']);
      });

      test('returns null for blank text or when unavailable', () async {
        expect(await translator.identifyLanguage(' \n'), isNull);
        create(available: false);
        expect(await translator.identifyLanguage('Hello'), isNull);
        expect(bindings.calls, isEmpty);
      });
    });

    group('dispose', () {
      test('closes translators and the identifier', () async {
        await translator.translate('a', source: 'en', target: 'de');
        await translator.translate('b', source: 'de', target: 'en');
        await translator.identifyLanguage('c');
        await translator.dispose();

        expect(bindings.translators.map((t) => t.closed), [true, true]);
        expect(bindings.identifiers.single.closed, isTrue);
        expect(translator.cachedTranslatorCount, 0);
      });

      test('can be called without native resources', () async {
        await translator.dispose();
        expect(bindings.calls, isEmpty);
      });

      test('leaves the translator usable', () async {
        await translator.translate('a', source: 'en', target: 'de');
        await translator.identifyLanguage('a');
        await translator.dispose();
        await translator.translate('b', source: 'en', target: 'de');
        await translator.identifyLanguage('b');
        expect(bindings.translators, hasLength(2));
        expect(bindings.identifiers, hasLength(2));
      });
    });
  });
}
