import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import 'translate_cubit_helpers.dart';

final _offline = TranslationEngine.offline();

/// Lets the settings stream, the engine switch and the translation run.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  late StreamController<AppSettings> settings;

  setUp(() {
    mocks = TranslateMocks()..stubTranslate();
    settings = StreamController<AppSettings>.broadcast();
    addTearDown(settings.close);
    whenListen(
      mocks.settings,
      settings.stream,
      initialState: const AppSettings(),
    );
    when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => [google, deepl, _offline]);
  });

  /// Changes the settings to [value], as `SettingsCubit` would.
  Future<void> change(AppSettings value) async {
    settings.add(value);
    await _settle();
  }

  group('the engine follows the privacy mode', () {
    test(
      'Offline first -> Online leaves the on-device engine it picked',
      () async {
        final cubit = mocks.build()
          ..emit(
            readyState(
              engine: _offline,
              engines: [google, deepl, _offline],
              input: 'Hallo',
            ),
          );
        addTearDown(cubit.close);

        await change(const AppSettings(privacyMode: PrivacyMode.online));

        expect(cubit.state.engine, google);
        verify(() => mocks.repository.translate(google, any())).called(1);
        verifyNever(() => mocks.repository.translate(_offline, any()));
        // Not saved: the user chose no engine.
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    test('Online -> Offline only uses the on-device engine', () async {
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(privacyMode: PrivacyMode.online),
      );
      final cubit = mocks.build()
        ..emit(readyState(engines: [google, deepl, _offline], input: 'Hallo'));
      addTearDown(cubit.close);

      await change(const AppSettings(privacyMode: PrivacyMode.offlineOnly));

      expect(cubit.state.engine, _offline);
      verify(() => mocks.repository.translate(_offline, any())).called(1);
      verifyNever(() => mocks.settings.setEngine(any()));

      // Back online: the saved engine (none: the default) again.
      await change(const AppSettings(privacyMode: PrivacyMode.online));
      expect(cubit.state.engine, google);
    });

    test('the saved engine comes back after Offline only', () async {
      const saved = AppSettings(
        privacyMode: PrivacyMode.online,
        engineId: 'mozhi:deepl',
      );
      whenListen(mocks.settings, settings.stream, initialState: saved);
      final cubit = mocks.build()
        ..emit(readyState(engine: deepl, engines: [google, deepl, _offline]));
      addTearDown(cubit.close);

      await change(saved.copyWith(privacyMode: PrivacyMode.offlineOnly));
      expect(cubit.state.engine, _offline);
      await change(saved);
      expect(cubit.state.engine, deepl);
    });

    test('a user who picked the on-device engine keeps it', () async {
      const picked = AppSettings(engineId: TranslationEngine.offlineId);
      whenListen(mocks.settings, settings.stream, initialState: picked);
      final cubit = mocks.build()
        ..emit(readyState(engine: _offline, engines: [google, _offline]));
      addTearDown(cubit.close);

      await change(picked.copyWith(privacyMode: PrivacyMode.online));

      expect(cubit.state.engine, _offline);
    });

    test('other settings changes switch nothing', () async {
      final cubit = mocks.build()
        ..emit(readyState(engine: _offline, engines: [google, _offline]));
      addTearDown(cubit.close);

      await change(const AppSettings(saveHistory: false));

      expect(cubit.state.engine, _offline);
    });

    test(
      'onboarding: the cubit loads first, then the mode is chosen',
      () async {
        final cubit = mocks.build();
        addTearDown(cubit.close);
        await cubit.loadEngines();
        // Offline first (the default) picks the on-device engine.
        expect(cubit.state.engine, _offline);

        await change(const AppSettings(privacyMode: PrivacyMode.online));
        expect(cubit.state.engine, google);
      },
    );

    test('an engine reload in Online does not keep the on-device engine '
        'the app picked', () async {
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(privacyMode: PrivacyMode.online),
      );
      final cubit = mocks.build()
        ..emit(readyState(engine: _offline, engines: [google, _offline]));
      addTearDown(cubit.close);

      // The app reloads the engines when the mode changes.
      await cubit.loadEngines();

      expect(cubit.state.engine, google);
    });

    test('an engine reload in Offline only picks the device first', () async {
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(
          privacyMode: PrivacyMode.offlineOnly,
          engineId: 'mozhi:deepl',
        ),
      );
      final cubit = mocks.build();
      addTearDown(cubit.close);

      await cubit.loadEngines();

      expect(cubit.state.engine, _offline);
    });

    test('nothing switches while a quality mode is on', () async {
      final cubit = mocks.build()
        ..emit(
          readyState(
            engine: _offline,
            engines: [google, _offline],
          ).copyWith(qualityMode: QualityMode.fast),
        );
      addTearDown(cubit.close);

      await change(const AppSettings(privacyMode: PrivacyMode.online));

      expect(cubit.state.engine, _offline);
    });
  });

  group('smart swap with the on-device engine', () {
    const text = 'Das ist ein ziemlich langer deutscher Satz zum Testen.';

    setUp(() {
      // German detected while the target is German: smart swap.
      when(() => mocks.repository.translate(any(), any())).thenAnswer((
        invocation,
      ) {
        final engine = invocation.positionalArguments[0] as TranslationEngine;
        final request = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          resultOf(
            '${request.text}->${request.target.code}',
            engine: engine,
            detected: 'de',
          ),
        );
      });
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(
          target: de,
          // Spanish is the most recent, but not on the device.
          recentLanguages: [es, fr],
        ),
      );
    });

    TranslateCubit build(OfflineTranslator? offline) => TranslateCubit(
      repository: mocks.repository,
      settings: mocks.settings,
      history: mocks.history,
      debounce: fastDebounce,
      aiDebounce: fastAiDebounce,
      deviceLanguages: () => const [],
      offlineTranslator: offline,
    );

    test('only switches to a language that is downloaded', () async {
      final cubit = build(FakeOfflineTranslator(downloaded: {'de', 'fr'}))
        ..emit(
          readyState(
            engine: _offline,
            engines: [google, _offline],
            input: text,
            target: de,
          ),
        );
      addTearDown(cubit.close);
      await _settle();

      await cubit.translate();

      expect(cubit.state.target, fr);
      expect(cubit.state.smartSwapNotice?.newTarget, fr);
    });

    test('English needs no download', () async {
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(target: de, recentLanguages: [es, en]),
      );
      final cubit = build(FakeOfflineTranslator(downloaded: {'de'}))
        ..emit(
          readyState(
            engine: _offline,
            engines: [google, _offline],
            input: text,
            target: de,
          ),
        );
      addTearDown(cubit.close);
      await _settle();

      await cubit.translate();

      expect(cubit.state.target, en);
    });

    test('does not swap when no other language is on the device', () async {
      final cubit = build(FakeOfflineTranslator(downloaded: {'de'}))
        ..emit(
          readyState(
            engine: _offline,
            engines: [google, _offline],
            input: text,
            target: de,
          ).copyWith(targetLanguages: const [de, fr, es]),
        );
      addTearDown(cubit.close);
      await _settle();

      await cubit.translate();

      expect(cubit.state.target, de);
      expect(cubit.state.smartSwapNotice, isNull);
    });

    test('other engines are not limited', () async {
      final cubit = build(
        FakeOfflineTranslator(downloaded: {'de', 'fr'}),
      )..emit(readyState(engines: [google, _offline], input: text, target: de));
      addTearDown(cubit.close);
      await _settle();

      await cubit.translate();

      expect(cubit.state.target, es);
    });
  });

  group('recentSourceLanguagesOf', () {
    test('has the detected and picked sources first, then the recents', () {
      const settings = AppSettings(
        recentPairs: [
          LanguagePair(source: de, target: en),
          LanguagePair(source: Language.auto, target: fr),
          LanguagePair(source: en, target: de),
          LanguagePair(source: de, target: fr),
        ],
        recentLanguages: [fr, en, es],
      );
      expect(TranslateCubit.recentSourceLanguagesOf(settings), [
        de,
        en,
        fr,
        es,
      ]);
    });

    test('keeps at most the usual number', () {
      const many = [en, de, fr, es, ja];
      final settings = AppSettings(
        recentPairs: [for (final l in many) LanguagePair(source: l, target: l)],
        recentLanguages: const [
          Language(code: 'it', name: 'Italian'),
          Language(code: 'pt', name: 'Portuguese'),
          Language(code: 'nl', name: 'Dutch'),
          Language(code: 'pl', name: 'Polish'),
        ],
      );
      expect(TranslateCubit.recentSourceLanguagesOf(settings), hasLength(8));
    });
  });
}
