import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  late MockTranslationRepository repository;
  late MockSettingsCubit settings;
  late MockHistoryCubit history;
  late MockOfflineTranslator translator;

  final translated = result(
    'Bonjour le monde',
    engineId: TranslationEngine.offlineId,
    engineName: 'Offline (on-device)',
    detectedSource: 'de',
  );

  setUp(() {
    repository = MockTranslationRepository();
    settings = mockSettings(const AppSettings(target: french));
    history = MockHistoryCubit();
    translator = MockOfflineTranslator();
    when(() => history.add(any())).thenAnswer((_) async {});
    when(() => repository.hasOfflineEngine).thenReturn(true);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => mozhiTargets);
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(translated));
    when(() => translator.isAvailable).thenReturn(true);
    when(() => translator.supportedLanguages)
        .thenReturn(const {'en', 'fr', 'de', 'ja'});
    when(translator.downloadedLanguages)
        .thenAnswer((_) async => const {'en', 'fr', 'de'});
    when(() => translator.identifyLanguage(any()))
        .thenAnswer((_) async => 'de');
  });

  QuickTranslateCubit build({
    String text = 'Hallo Welt',
    Language? target,
    bool withOffline = true,
  }) => QuickTranslateCubit(
    repository: repository,
    settings: settings,
    history: history,
    offline: withOffline ? translator : null,
    offlineOnly: true,
    text: text,
    target: target,
  );

  QuickTranslateState loaded({Language target = french}) => QuickTranslateState(
    text: 'Hallo Welt',
    target: target,
    engines: [offlineEngine],
    engine: offlineEngine,
    targetLanguages: mozhiTargets,
    offlineOnly: true,
  );

  QuickTranslateState identified({
    Language target = french,
    String source = 'de',
    QuickTranslateStatus status = QuickTranslateStatus.translating,
  }) =>
      loaded(target: target)
          .copyWith(status: status, identifiedSource: () => source);

  const unavailable = QuickTranslateState(
    text: 'Hallo Welt',
    target: french,
    status: QuickTranslateStatus.offlineUnavailable,
    offlineOnly: true,
  );

  void verifyNothingSent() {
    verifyNever(() => repository.translate(any(), any()));
    verifyNever(() => repository.getEngines(refresh: any(named: 'refresh')));
  }

  group('QuickTranslateCubit offline only', () {
    test('starts offline only', () {
      final cubit = build();
      expect(cubit.state.offlineOnly, isTrue);
      expect(cubit.state.isLoading, isTrue);
    });

    group('installed pair', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'identifies the language and translates on the device',
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          loaded(),
          loaded().copyWith(status: QuickTranslateStatus.translating),
          identified(),
          identified(status: QuickTranslateStatus.success)
              .copyWith(result: () => translated),
        ],
        verify: (cubit) {
          verify(
            () => repository.translate(
              offlineEngine,
              const TranslationRequest(
                text: 'Hallo Welt',
                source: Language.auto,
                target: french,
              ),
            ),
          ).called(1);
          verify(() => translator.identifyLanguage('Hallo Welt')).called(1);
          verify(() => repository.getTargetLanguages(offlineEngine)).called(1);
          verifyNever(
            () => repository.getEngines(refresh: any(named: 'refresh')),
          );
          expect(cubit.state.detectedSource, 'de');
          expect(cubit.state.hasTranslation, isTrue);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'uses the on-device engine whatever the privacy mode and engine',
        setUp: () {
          when(() => settings.state).thenReturn(
            const AppSettings(
              target: french,
              engineId: 'mozhi:google',
              privacyMode: PrivacyMode.online,
            ),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.engine, offlineEngine);
          expect(cubit.state.engines, [offlineEngine]);
          verify(() => repository.translate(offlineEngine, any())).called(1);
          verifyNever(
            () => repository.getEngines(refresh: any(named: 'refresh')),
          );
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'adds the translation to history',
        build: build,
        act: (cubit) => cubit.start(),
        verify: (_) {
          final entry =
              verify(() => history.add(captureAny())).captured.single
                  as HistoryEntry;
          expect(entry.engineId, TranslationEngine.offlineId);
          expect(entry.source, Language.auto);
          expect(entry.detectedSource, 'de');
          expect(entry.translation, 'Bonjour le monde');
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'maps the target onto the on-device languages',
        build: () => build(target: const Language.custom('Pirate speak')),
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, english),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'treats blank text as nothing to translate',
        build: () => build(text: '  '),
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.result, isNull);
          verifyNever(() => translator.identifyLanguage(any()));
          verifyNothingSent();
        },
      );
    });

    group('missing model', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'lists the target language to download and translates nothing',
        build: () => build(target: japanese),
        act: (cubit) => cubit.start(),
        expect: () => [
          loaded(target: japanese),
          loaded(target: japanese)
              .copyWith(status: QuickTranslateStatus.translating),
          identified(target: japanese),
          identified(
            target: japanese,
            status: QuickTranslateStatus.offlineModelsMissing,
          ).copyWith(
            offlineDownloads: const [
              (code: 'ja', name: 'Japanese', bytes: null),
            ],
          ),
        ],
        verify: (_) => verifyNothingSent(),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'lists the source language to download',
        setUp: () {
          when(() => translator.identifyLanguage(any()))
              .thenAnswer((_) async => 'ja');
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.offlineModelsMissing);
          expect(cubit.state.detectedSource, 'ja');
          expect(cubit.state.offlineDownloads, const [
            (code: 'ja', name: 'Japanese', bytes: null),
          ]);
          verifyNothingSent();
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'lists both languages when only English is on the device',
        setUp: () {
          when(translator.downloadedLanguages)
              .thenAnswer((_) async => const {'en'});
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.offlineModelsMissing);
          expect(cubit.state.offlineDownloads, const [
            (code: 'de', name: 'German', bytes: null),
            (code: 'fr', name: 'French', bytes: null),
          ]);
          verifyNothingSent();
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'translates once the user picks an installed target, without '
        'identifying the text again',
        build: () => build(target: japanese),
        act: (cubit) async {
          await cubit.start();
          await cubit.setTarget(french);
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.offlineDownloads, isEmpty);
          expect(cubit.state.translation, 'Bonjour le monde');
          verify(() => translator.identifyLanguage(any())).called(1);
          verify(() => repository.translate(offlineEngine, any())).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'a model the engine reports missing lists it too',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.error(const OfflineModelMissingException(['de'])),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.offlineModelsMissing);
          expect(cubit.state.error, isNull);
          expect(cubit.state.offlineDownloads, const [
            (code: 'de', name: 'German', bytes: null),
          ]);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'a missing English model is a failure (English is no download)',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.error(const OfflineModelMissingException(['en'])),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, isA<OfflineModelMissingException>());
        },
      );
    });

    group('unsupported pair', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'says so for a language the on-device engine has no model for',
        setUp: () {
          when(() => translator.identifyLanguage(any()))
              .thenAnswer((_) async => 'ko');
        },
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          loaded(),
          loaded().copyWith(status: QuickTranslateStatus.translating),
          identified(source: 'ko'),
          identified(
            source: 'ko',
            status: QuickTranslateStatus.offlineUnsupported,
          ),
        ],
        verify: (_) => verifyNothingSent(),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'an unsupported language reported by the engine',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) =>
                Stream.error(const OfflineLanguageUnsupportedException('de')),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.offlineUnsupported);
          expect(cubit.state.error, isNull);
          expect(cubit.state.result, isNull);
        },
      );
    });

    group('no engine', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'without an on-device engine',
        build: () => build(withOffline: false),
        act: (cubit) => cubit.start(),
        expect: () => [unavailable],
        verify: (_) {
          verifyNothingSent();
          verifyNever(() => repository.getTargetLanguages(any()));
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'when the on-device engine is not available',
        setUp: () => when(() => translator.isAvailable).thenReturn(false),
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [unavailable],
        verify: (_) => verifyNothingSent(),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'when the repository has no on-device engine',
        setUp: () => when(() => repository.hasOfflineEngine).thenReturn(false),
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [unavailable],
        verify: (_) => verifyNothingSent(),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'retry checks again and still sends nothing',
        build: () => build(withOffline: false),
        act: (cubit) async {
          await cubit.start();
          await cubit.retry();
        },
        expect: () => [
          unavailable,
          unavailable.copyWith(status: QuickTranslateStatus.loading),
          unavailable,
        ],
        verify: (_) => verifyNothingSent(),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'translate does nothing before the engine is loaded',
        build: build,
        act: (cubit) => cubit.translate(),
        expect: () => <QuickTranslateState>[],
      );
    });

    group('detection', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'switches the target once when the text is in the target language',
        setUp: () {
          when(() => settings.state).thenReturn(
            const AppSettings(target: french, recentLanguages: [german]),
          );
          when(() => translator.identifyLanguage(any()))
              .thenAnswer((_) async => 'fr');
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.target, german);
          expect(cubit.state.detectedSource, 'de');
          expect(cubit.state.identifiedSource, 'fr');
          verify(
            () => repository.translate(
              offlineEngine,
              const TranslationRequest(
                text: 'Hallo Welt',
                source: Language.auto,
                target: german,
              ),
            ),
          ).called(1);
          verifyNever(
            () => settings.setLanguages(
              source: any(named: 'source'),
              target: any(named: 'target'),
            ),
          );
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'keeps a target the user picked',
        setUp: () {
          when(() => translator.identifyLanguage(any()))
              .thenAnswer((_) async => 'fr');
        },
        build: build,
        seed: () => loaded(target: german),
        act: (cubit) => cubit.setTarget(french),
        verify: (cubit) {
          expect(cubit.state.target, french);
          expect(cubit.state.identifiedSource, 'fr');
          expect(cubit.state.status, QuickTranslateStatus.success);
          verify(
            () => repository.translate(
              offlineEngine,
              const TranslationRequest(
                text: 'Hallo Welt',
                source: Language.auto,
                target: french,
              ),
            ),
          ).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'normalises the identified code',
        setUp: () {
          when(() => translator.identifyLanguage(any()))
              .thenAnswer((_) async => ' iw ');
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.identifiedSource, 'he'),
      );

      for (final code in [null, '', 'und']) {
        blocTest<QuickTranslateCubit, QuickTranslateState>(
          'says when it cannot tell the language ($code)',
          setUp: () {
            when(() => translator.identifyLanguage(any()))
                .thenAnswer((_) async => code);
          },
          build: build,
          act: (cubit) => cubit.start(),
          expect: () => [
            loaded(),
            loaded().copyWith(status: QuickTranslateStatus.translating),
            loaded().copyWith(status: QuickTranslateStatus.offlineUnsupported),
          ],
          verify: (cubit) {
            expect(cubit.state.detectedSource, isNull);
            verifyNothingSent();
          },
        );
      }

      final failure = StateError('identification failed');

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'fails when identifying throws, and identifies again on retry',
        setUp: () {
          var calls = 0;
          when(() => translator.identifyLanguage(any())).thenAnswer((_) async {
            if (++calls == 1) throw failure;
            return 'de';
          });
        },
        build: build,
        act: (cubit) async {
          await cubit.start();
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, failure);
          verifyNothingSent();
          await cubit.retry();
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          verify(() => translator.identifyLanguage(any())).called(2);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'fails when checking the models throws',
        setUp: () {
          when(() => translator.supportedLanguages).thenThrow(failure);
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, failure);
          verifyNothingSent();
        },
      );

      late Completer<String?> identifying;

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores an identification superseded by a new target',
        setUp: () {
          identifying = Completer<String?>();
          var calls = 0;
          when(() => translator.identifyLanguage(any())).thenAnswer((_) {
            if (++calls == 1) return identifying.future;
            return Future.value('de');
          });
        },
        build: build,
        act: (cubit) async {
          final first = cubit.start();
          await pumpEventQueue();
          await cubit.setTarget(german);
          identifying.complete('ja');
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.target, german);
          expect(cubit.state.status, QuickTranslateStatus.success);
          verify(() => repository.translate(offlineEngine, any())).called(1);
        },
      );

      late Completer<Set<String>> checking;

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores a model check superseded by a new target',
        setUp: () {
          checking = Completer<Set<String>>();
          var calls = 0;
          when(translator.downloadedLanguages).thenAnswer((_) {
            if (++calls == 1) return checking.future;
            return Future.value(const {'en', 'fr', 'de'});
          });
        },
        build: build,
        act: (cubit) async {
          final first = cubit.start();
          await pumpEventQueue();
          await cubit.setTarget(german);
          checking.complete(const {'en'});
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.target, german);
          expect(cubit.state.status, QuickTranslateStatus.success);
          verify(() => repository.translate(offlineEngine, any())).called(1);
        },
      );
    });

    group('errors', () {
      final failure = Exception('engine crashed');

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'other translation errors are failures',
        setUp: () {
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.error(failure));
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, failure);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'fails when the on-device languages cannot be loaded, and loads '
        'them again on retry',
        setUp: () {
          var calls = 0;
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async {
                if (++calls == 1) throw failure;
                return mozhiTargets;
              });
        },
        build: build,
        act: (cubit) async {
          await cubit.start();
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.engine, isNull);
          await cubit.retry();
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.engine, offlineEngine);
          verifyNever(
            () => repository.getEngines(refresh: any(named: 'refresh')),
          );
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores a load superseded by a newer one',
        setUp: () {
          var calls = 0;
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async {
                if (++calls == 1) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                  throw failure;
                }
                return mozhiTargets;
              });
        },
        build: build,
        act: (cubit) async {
          final first = cubit.start();
          await cubit.start(refresh: true);
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.error, isNull);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores languages loaded for a superseded load',
        setUp: () {
          var calls = 0;
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async {
                if (++calls == 1) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                  return const [english];
                }
                return mozhiTargets;
              });
        },
        build: build,
        act: (cubit) async {
          final first = cubit.start();
          await cubit.start(refresh: true);
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.targetLanguages, mozhiTargets);
          expect(cubit.state.target, french);
        },
      );
    });

    blocTest<QuickTranslateCubit, QuickTranslateState>(
      'selectEngine does nothing: the on-device engine is the only one',
      build: build,
      seed: loaded,
      act: (cubit) => cubit.selectEngine(google),
      expect: () => <QuickTranslateState>[],
      verify: (_) {
        verifyNever(() => settings.setEngine(any()));
        verifyNothingSent();
      },
    );
  });
}
