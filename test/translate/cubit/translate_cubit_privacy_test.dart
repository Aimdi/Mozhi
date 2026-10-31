import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org', engine: 'google'),
  engineId: 'mozhi:google',
  source: 'auto',
  target: 'en',
);

const _deeplApi = TranslationEngine(
  id: 'mt:deepl',
  kind: EngineKind.mt,
  name: 'DeepL API',
  providerId: 'deepl',
);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() => mocks = TranslateMocks());

  /// The first translate call is refused for [consent]; later ones answer.
  void refuseFirst([ConsentRequiredException consent = _consent]) {
    var calls = 0;
    when(() => mocks.repository.translate(any(), any())).thenAnswer((
      invocation,
    ) {
      final engine = invocation.positionalArguments[0] as TranslationEngine;
      final request = invocation.positionalArguments[1] as TranslationRequest;
      if (calls++ == 0) return Stream.error(consent);
      return Stream.value(
        resultOf('${request.text}->${request.target.code}', engine: engine),
      );
    });
  }

  test('ConsentRequest compares by value', () {
    expect(
      const ConsentRequest(exception: _consent, id: 1),
      const ConsentRequest(exception: _consent, id: 1),
    );
    expect(
      const ConsentRequest(exception: _consent, id: 1),
      isNot(const ConsentRequest(exception: _consent, id: 1, automatic: true)),
    );
  });

  group('consent', () {
    blocTest<TranslateCubit, TranslateState>(
      'a translation the user asked for asks with a dialog',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        final consent = cubit.state.consent;
        expect(consent?.exception, _consent);
        expect(consent?.automatic, isFalse);
        expect(cubit.state.status, TranslateStatus.idle);
        expect(cubit.state.error, isNull);
        expect(cubit.state.result, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'instant translation only asks inline',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('Hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.consent?.automatic, isTrue);
        verifyNever(() => mocks.history.add(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a language change only asks inline',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.setTarget(de),
      verify: (cubit) => expect(cubit.state.consent?.automatic, isTrue),
    );

    blocTest<TranslateCubit, TranslateState>(
      'retryAfterConsent translates again, as asked by the user',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        cubit.setInput('Hallo!');
        await Future<void>.delayed(afterDebounce);
        expect(cubit.state.consent?.automatic, isTrue);
        await cubit.retryAfterConsent();
      },
      verify: (cubit) {
        expect(cubit.state.consent, isNull);
        expect(cubit.state.result?.text, 'Hallo!->en');
        expect(mocks.translateRequests(), hasLength(2));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a new id for every refusal',
      setUp: () =>
          when(() => mocks.repository.translate(any(), any()))
              .thenAnswer((_) => Stream.error(_consent)),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await cubit.translate();
        final first = cubit.state.consent!.id;
        await cubit.translate();
        expect(cubit.state.consent!.id, isNot(first));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'retryAfterConsent without a refusal translates the input',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.retryAfterConsent(),
      verify: (cubit) => expect(cubit.state.result?.text, 'Hallo->en'),
    );

    blocTest<TranslateCubit, TranslateState>(
      'dismissConsent hides the prompt',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await cubit.translate();
        cubit
          ..dismissConsent()
          // Nothing to hide any more.
          ..dismissConsent();
      },
      verify: (cubit) {
        expect(cubit.state.consent, isNull);
        expect(mocks.translateRequests(), hasLength(1));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'editing the input drops the prompt',
      setUp: refuseFirst,
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await cubit.translate();
        cubit.setInput('Hallo Welt');
      },
      verify: (cubit) => expect(cubit.state.consent, isNull),
    );
  });

  group('incognito', () {
    blocTest<TranslateCubit, TranslateState>(
      'records no history',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(incognito: true))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.result?.text, 'Hallo->en');
        verifyNever(() => mocks.history.add(any()));
      },
    );
  });

  group('loadDeferredEngines', () {
    blocTest<TranslateCubit, TranslateState>(
      'lets offline first load the Mozhi lists',
      setUp: () =>
          when(() => mocks.repository.metadataDeferred).thenReturn(true),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadDeferredEngines(),
      verify: (cubit) {
        verify(() => mocks.repository.allowMetadataRequests()).called(1);
        verify(() => mocks.repository.getEngines()).called(1);
        expect(cubit.state.engines, allEngines);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing when the lists are not deferred',
      setUp: () =>
          when(() => mocks.repository.metadataDeferred).thenReturn(false),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadDeferredEngines(),
      verify: (_) {
        verifyNever(() => mocks.repository.allowMetadataRequests());
        verifyNever(() => mocks.repository.getEngines());
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing with a repository without privacy settings',
      build: () => mocks.build(),
      act: (cubit) => cubit.loadDeferredEngines(),
      verify: (_) => verifyNever(() => mocks.repository.getEngines()),
    );
  });

  group('picking an engine without a saved one', () {
    final offline = TranslationEngine.offline();

    void engines(List<TranslationEngine> engines) =>
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => engines);

    blocTest<TranslateCubit, TranslateState>(
      'offline first starts on the device',
      setUp: () => engines([google, claude, offline]),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) => expect(cubit.state.engine, offline),
    );

    blocTest<TranslateCubit, TranslateState>(
      'online starts with the default engine',
      setUp: () {
        mocks.stubSettings(const AppSettings(privacyMode: PrivacyMode.online));
        engines([claude, google, offline]);
      },
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) => expect(cubit.state.engine, google),
    );

    blocTest<TranslateCubit, TranslateState>(
      'never a cloud provider: the user picks',
      setUp: () => engines([claude, _deeplApi]),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.engine, isNull);
        expect(cubit.state.engines, [claude, _deeplApi]);
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a local engine may be the default',
      setUp: () => engines([claude, local]),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) => expect(cubit.state.engine, local),
    );

    blocTest<TranslateCubit, TranslateState>(
      'asks the repository where an engine sends text',
      setUp: () {
        engines([_deeplApi, claude]);
        when(() => mocks.repository.destinationOf(_deeplApi.id))
            .thenReturn(const SelfHostedDestination('deepl.lan'));
        when(() => mocks.repository.destinationOf(claude.id))
            .thenReturn(const CloudProviderDestination('Claude'));
      },
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) => expect(cubit.state.engine, _deeplApi),
    );
  });

  group('leaving a quality mode', () {
    blocTest<TranslateCubit, TranslateState>(
      'never falls back to a cloud provider',
      setUp: () {
        mocks.stubSettings(
          const AppSettings(
            fastEngineId: 'ai:claude',
            qualityMode: QualityMode.fast,
          ),
        );
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [claude, _deeplApi]);
      },
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        expect(cubit.state.engine, claude);
        await cubit.setQualityMode(QualityMode.off);
      },
      // Nothing that is not a cloud provider: the mode's engine stays.
      verify: (cubit) => expect(cubit.state.engine, claude),
    );
  });

  group('text from outside the app (share, link)', () {
    final offline = TranslationEngine.offline();
    const offlineOnly = AppSettings(privacyMode: PrivacyMode.offlineOnly);

    blocTest<TranslateCubit, TranslateState>(
      'in Offline only is not sent to a network engine on its own',
      setUp: () {
        mocks
          ..stubSettings(offlineOnly)
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Bonjour', engines: [google, offline]),
      act: (cubit) => cubit.setExternalInput('Le chat dort'),
      verify: (cubit) {
        // The text is there, for the user to translate (or not).
        expect(cubit.state.input, 'Le chat dort');
        expect(cubit.state.result, isNull);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'in Offline only is translated on the device on its own',
      setUp: () {
        mocks
          ..stubSettings(offlineOnly)
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: offline, engines: [google, offline]),
      act: (cubit) => cubit.setExternalInput('Le chat dort'),
      verify: (cubit) {
        expect(cubit.state.input, 'Le chat dort');
        expect(cubit.state.result?.text, 'Le chat dort->en');
        verify(() => mocks.repository.translate(offline, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'waits for the engines that load, then uses the one they pick',
      setUp: () {
        mocks
          ..stubSettings(
            const AppSettings(
              privacyMode: PrivacyMode.offlineOnly,
              engineId: TranslationEngine.offlineId,
            ),
          )
          ..stubTranslate();
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [google, offline]);
      },
      build: () => mocks.build(),
      // The engine of the online mode, while the engines reload for
      // Offline only.
      seed: () =>
          readyState(engines: [google, offline])
              .copyWith(enginesStatus: EnginesStatus.loading),
      act: (cubit) async {
        cubit.setExternalInput('Le chat dort');
        expect(cubit.state.input, 'Le chat dort');
        verifyNever(() => mocks.repository.translate(any(), any()));
        await cubit.loadEngines();
      },
      verify: (cubit) {
        expect(cubit.state.engine, offline);
        expect(cubit.state.result?.text, 'Le chat dort->en');
        verify(() => mocks.repository.translate(offline, any())).called(1);
        verifyNever(() => mocks.repository.translate(google, any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is still put into the input when the engines never finish loading',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          readyState(input: 'Bonjour')
              .copyWith(enginesStatus: EnginesStatus.loading),
      act: (cubit) => cubit.setExternalInput('Le chat dort'),
      verify: (cubit) {
        expect(cubit.state.input, 'Le chat dort');
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );
  });
}
