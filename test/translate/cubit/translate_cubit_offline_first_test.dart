import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

final offline = TranslationEngine.offline();

const _instance = MozhiInstance(url: 'https://mozhi.example', isCustom: false);

/// The first run's defaults: Offline first, no engine chosen.
const _firstRun = AppSettings(instances: [_instance]);

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example', engine: 'google'),
  engineId: 'mozhi:google',
  source: 'auto',
  target: 'en',
);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks()..stubSettings(_firstRun);
  });

  /// The on-device engine selected (as the app picks it), [engines] listed.
  TranslateState onDevice({
    List<TranslationEngine> engines = const [],
    Language source = Language.auto,
    Language target = en,
    String input = 'Bonjour tout le monde',
  }) => readyState(
    engine: offline,
    engines: [...engines, offline],
    assistEngine: null,
    source: source,
    target: target,
    input: input,
  );

  /// The on-device engine fails with [deviceError]; the online engine
  /// answers with [onlineAnswers] in turn (a [ConsentRequiredException] is
  /// thrown as a stream error, a string becomes the translation).
  void answer(Object deviceError, List<Object> onlineAnswers) {
    final answers = [...onlineAnswers];
    when(() => mocks.repository.translate(any(), any())).thenAnswer((call) {
      final engine = call.positionalArguments[0] as TranslationEngine;
      if (engine.isOffline) return Stream.error(deviceError);
      final next = answers.isEmpty ? 'unexpected' : answers.removeAt(0);
      if (next is String) return Stream.value(resultOf(next, engine: engine));
      return Stream.error(next);
    });
  }

  List<TranslationEngine> translatedWith() =>
      verify(() => mocks.repository.translate(captureAny(), any())).captured
          .cast<TranslationEngine>();

  group('onlineFallbackOf', () {
    test('is the listed default engine', () {
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice(engines: [deepl, google]),
          _firstRun,
        ),
        google,
      );
    });

    test('is Google on the first instance before the lists load', () {
      final engine = TranslateCubit.onlineFallbackOf(onDevice(), _firstRun);
      expect(engine?.id, 'mozhi:google');
      expect(engine?.name, 'Google');
      expect(engine?.kind, EngineKind.mozhi);
      expect(engine?.mozhiEngine, 'google');
      expect(engine?.subtitle, 'mozhi.example');
    });

    test('is null unless the app picked the on-device engine in Offline '
        'first', () {
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice(),
          _firstRun.copyWith(privacyMode: PrivacyMode.online),
        ),
        isNull,
      );
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice(),
          _firstRun.copyWith(privacyMode: PrivacyMode.offlineOnly),
        ),
        isNull,
      );
      // The user picked the on-device engine: the text stays there.
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice(),
          _firstRun.copyWith(engineId: () => offline.id),
        ),
        isNull,
      );
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice().copyWith(qualityMode: QualityMode.fast),
          _firstRun,
        ),
        isNull,
      );
      expect(
        TranslateCubit.onlineFallbackOf(
          onDevice(),
          _firstRun.copyWith(instances: const []),
        ),
        isNull,
      );
      expect(TranslateCubit.onlineFallbackOf(readyState(), _firstRun), isNull);
      expect(
        TranslateCubit.onlineFallbackOf(const TranslateState(), _firstRun),
        isNull,
      );
    });
  });

  group('Offline first without the language on the device', () {
    test('asks before sending to the online engine', () async {
      answer(const OfflineModelMissingException(['fr']), [_consent]);
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(translatedWith(), [offline, isA<TranslationEngine>()]);
      final consent = cubit.state.consent;
      expect(consent?.exception, _consent);
      expect(consent?.fromOnDevice, isTrue);
      expect(consent?.onDeviceSource, 'fr');
      expect(consent?.automatic, isFalse);
      expect(cubit.state.error, isNull);
      expect(cubit.state.status, TranslateStatus.idle);
      verifyNever(() => mocks.history.add(any()));
    });

    test('an instant translation asks inline', () async {
      answer(const OfflineModelMissingException(['fr']), [_consent]);
      final cubit = mocks.build()..emit(onDevice(input: ''));
      addTearDown(cubit.close);

      cubit.setInput('Bonjour tout le monde');
      await Future<void>.delayed(afterDebounce);

      expect(cubit.state.consent?.fromOnDevice, isTrue);
      expect(cubit.state.consent?.automatic, isTrue);
    });

    test('translates online once allowed and records the engine that '
        'did', () async {
      answer(const OfflineModelMissingException(['fr']), [
        _consent,
        'Hello everyone',
      ]);
      final cubit = mocks.build()..emit(onDevice(engines: [google]));
      addTearDown(cubit.close);
      await cubit.translate();

      await cubit.retryAfterConsent();

      expect(cubit.state.consent, isNull);
      expect(cubit.state.status, TranslateStatus.success);
      expect(cubit.state.result?.text, 'Hello everyone');
      expect(cubit.state.result?.engineId, google.id);
      // The on-device engine stays selected for the next text.
      expect(cubit.state.engine, offline);
      final entry = mocks.historyEntries().single;
      expect(entry.engineId, google.id);
      expect(entry.engineName, 'Google');
    });

    test('an allowed pair goes online without asking', () async {
      answer(const OfflineLanguageUnsupportedException('xx'), ['Hello']);
      final cubit = mocks.build()..emit(onDevice(engines: [google]));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.result?.engineId, google.id);
      expect(cubit.state.consent, isNull);
    });

    test('a language pack that is there translates on the device', () async {
      mocks.stubTranslate(resultOf('Hello', engine: offline));
      final cubit = mocks.build()..emit(onDevice(engines: [google]));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(translatedWith(), [offline]);
      expect(cubit.state.result?.engineId, offline.id);
      expect(mocks.historyEntries().single.engineId, offline.id);
    });

    test('names the chosen source language for the download', () async {
      answer(const OfflineModelMissingException(['fr']), [_consent]);
      final cubit = mocks.build()..emit(onDevice(source: fr));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.consent?.onDeviceSource, 'fr');
    });

    test('names no source when only the target is missing', () async {
      answer(const OfflineModelMissingException(['de']), [_consent]);
      final cubit = mocks.build()..emit(onDevice(target: de));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.consent?.fromOnDevice, isTrue);
      expect(cubit.state.consent?.onDeviceSource, isNull);
    });

    test('names no source for a language without a model', () async {
      answer(const OfflineLanguageUnsupportedException('ta'), [_consent]);
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.consent?.fromOnDevice, isTrue);
      expect(cubit.state.consent?.onDeviceSource, isNull);
    });

    test('understands the exception wrapped by the platform', () async {
      answer(
        PlatformException(
          code: 'error',
          message: 'OfflineModelMissingException(fr)',
        ),
        [_consent],
      );
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.consent?.fromOnDevice, isTrue);
      expect(cubit.state.consent?.onDeviceSource, isNull);
    });

    test('other failures of the device are reported', () async {
      answer(StateError('engine crashed'), [_consent]);
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(translatedWith(), [offline]);
      expect(cubit.state.status, TranslateStatus.failure);
      expect(cubit.state.error, isA<StateError>());
      expect(cubit.state.consent, isNull);
    });

    test('a failure of the online engine is reported', () async {
      answer(const OfflineModelMissingException(['fr']), [
        const MozhiApiException('down', statusCode: 500),
      ]);
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.status, TranslateStatus.failure);
      expect(cubit.state.error, isA<MozhiApiException>());
    });

    test('an online request that throws at once is reported', () async {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((call) {
        final engine = call.positionalArguments[0] as TranslationEngine;
        if (engine.isOffline) {
          return Stream.error(const OfflineModelMissingException(['fr']));
        }
        throw StateError('no client');
      });
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(cubit.state.status, TranslateStatus.failure);
      expect(cubit.state.error, isA<StateError>());
    });

    test('the on-device engine the user chose never sends text', () async {
      mocks.stubSettings(_firstRun.copyWith(engineId: () => offline.id));
      answer(const OfflineModelMissingException(['fr']), [_consent]);
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(translatedWith(), [offline]);
      expect(cubit.state.status, TranslateStatus.failure);
      expect(cubit.state.error, isA<OfflineModelMissingException>());
      expect(cubit.state.consent, isNull);
    });

    for (final mode in [PrivacyMode.online, PrivacyMode.offlineOnly]) {
      test('${mode.name} reports the missing language', () async {
        mocks.stubSettings(_firstRun.copyWith(privacyMode: mode));
        answer(const OfflineModelMissingException(['fr']), [_consent]);
        final cubit = mocks.build()..emit(onDevice());
        addTearDown(cubit.close);

        await cubit.translate();

        expect(translatedWith(), [offline]);
        expect(cubit.state.error, isA<OfflineModelMissingException>());
      });
    }

    test('a mode change while the device works is a plain failure', () async {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
        // The user turns on Offline only while the device tries.
        mocks.stubSettings(
          _firstRun.copyWith(privacyMode: PrivacyMode.offlineOnly),
        );
        return Stream.error(const OfflineModelMissingException(['fr']));
      });
      final cubit = mocks.build()..emit(onDevice());
      addTearDown(cubit.close);

      await cubit.translate();

      expect(translatedWith(), [offline]);
      expect(cubit.state.error, isA<OfflineModelMissingException>());
    });
  });
}
