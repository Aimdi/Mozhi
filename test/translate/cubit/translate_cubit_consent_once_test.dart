import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

const _instance = MozhiInstance(url: 'https://mozhi.example', isCustom: false);

/// The first run's defaults: Offline first, no engine chosen.
const _firstRun = AppSettings(instances: [_instance]);

const _french = 'Bonjour tout le monde';
const _spanish = 'Hola a todos mis amigos';

/// The device: French and Spanish can be downloaded; [hold] keeps a
/// translation waiting.
class _Device implements OfflineTranslator {
  final Set<String> downloaded = {'en'};
  Completer<void>? hold;

  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'fr', 'es', 'de'};

  @override
  Future<Set<String>> downloadedLanguages() async => {...downloaded};

  @override
  Future<String?> identifyLanguage(String text) async => switch (text) {
    _french => 'fr',
    _spanish => 'es',
    _ => null,
  };

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    await hold?.future;
    final missing = [
      for (final code in {source, target})
        if (!downloaded.contains(code)) code,
    ];
    if (missing.isNotEmpty) throw OfflineModelMissingException(missing);
    return 'device: $text';
  }

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async =>
      downloaded.add(code);

  @override
  Future<void> deleteLanguage(String code) async => downloaded.remove(code);

  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(registerTranslateFallbacks);

  final offline = TranslationEngine.offline();

  group('a one-request approval ("Once") is used by its retry only', () {
    late TranslateMocks mocks;
    late _Device device;
    late TranslationRepository repository;
    late List<String> sent;

    setUp(() {
      mocks = TranslateMocks()..stubSettings(_firstRun);
      device = _Device();
      sent = [];
      final client = MockClient((request) async {
        final text = request.bodyFields['text']!;
        sent.add(text);
        return http.Response(
          jsonEncode({'engine': 'google', 'translated-text': 'google: $text'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      repository = TranslationRepository(
        mozhiClientFactory: (uri) =>
            MozhiApiClient(baseUrl: uri, httpClient: client),
        offline: device,
        cache: TranslationCache(maxEntries: 0),
      )..updateConfiguration(instances: const [_instance], providers: const []);
    });

    /// The app's pick: the on-device engine, "Detect language" into
    /// English, [text] typed.
    Future<TranslateCubit> start(String text) async {
      final cubit = TranslateCubit(
        repository: repository,
        settings: mocks.settings,
        history: mocks.history,
        debounce: fastDebounce,
        aiDebounce: fastAiDebounce,
      );
      addTearDown(cubit.close);
      cubit.emit(
        readyState(
          engine: offline,
          engines: [google, offline],
          assistEngine: null,
          input: text,
        ),
      );
      await cubit.translate();
      return cubit;
    }

    /// "Once" on the prompt (`grantConsent`), then the retry.
    Future<void> once(TranslateCubit cubit) {
      final consent = cubit.state.consent!;
      expect(consent.fromOnDevice, isTrue);
      repository.allowOnce(consent.exception);
      return cubit.retryAfterConsent();
    }

    /// Types [text] and waits for the instant translation.
    Future<void> type(TranslateCubit cubit, String text) async {
      cubit.setInput(text);
      await Future<void>.delayed(afterDebounce);
    }

    test('the device lacking French asks before Google', () async {
      final cubit = await start(_french);
      expect(cubit.state.consent?.exception.engineId, google.id);
      expect(sent, isEmpty);
    });

    test(
      'a retry that went online used it: the next text asks again',
      () async {
        final cubit = await start(_french);
        await once(cubit);
        expect(cubit.state.result?.text, 'google: $_french');
        expect(sent, [_french]);

        await type(cubit, _spanish);

        expect(cubit.state.consent?.exception.engineId, google.id);
        expect(sent, [_french]);
      },
    );

    test('a retry the device translates after all (French downloaded '
        'meanwhile) leaves nothing for a later text', () async {
      final cubit = await start(_french);
      // Downloaded through "Manage languages" or the dialog's Download
      // while the prompt stayed up.
      device.downloaded.add('fr');
      await once(cubit);
      expect(cubit.state.result?.text, 'device: $_french');
      expect(cubit.state.result?.engineId, offline.id);

      // Spanish is not on the device: asked again, nothing sent.
      await type(cubit, _spanish);

      expect(cubit.state.consent?.exception.engineId, google.id);
      expect(cubit.state.result, isNull);
      expect(sent, isEmpty);
    });

    test('a retry cancelled by more typing before the device answered '
        'leaves nothing for the new text', () async {
      final cubit = await start(_french);
      final hold = device.hold = Completer<void>();
      unawaited(once(cubit));
      await Future<void>.delayed(Duration.zero);

      cubit.setInput(_spanish);
      await Future<void>.delayed(afterDebounce);
      hold.complete();
      await Future<void>.delayed(afterDebounce);

      expect(cubit.state.consent?.exception.engineId, google.id);
      expect(cubit.state.consent?.exception.source, 'auto');
      expect(sent, isEmpty);
    });

    test('a retry stopped with Stop leaves nothing behind', () async {
      final cubit = await start(_french);
      final hold = device.hold = Completer<void>();
      unawaited(once(cubit));
      await Future<void>.delayed(Duration.zero);
      cubit.stopTranslation();
      hold.complete();
      await Future<void>.delayed(Duration.zero);

      await cubit.translate();

      expect(cubit.state.consent?.exception.engineId, google.id);
      expect(sent, isEmpty);
    });
  });

  group('retryAfterConsent with a repository double', () {
    late TranslateMocks mocks;

    const consent = ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: PublicInstanceDestination('mozhi.example', engine: 'google'),
      engineId: 'mozhi:google',
      source: 'auto',
      target: 'en',
    );

    setUp(() {
      registerFallbackValue(consent);
      mocks = TranslateMocks();
    });

    test('withdraws the approval once the retry finished', () async {
      var calls = 0;
      when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
        if (calls++ == 0) return Stream.error(consent);
        return Stream.value(resultOf('Hello'));
      });
      final cubit = mocks.build()..emit(readyState(input: 'Hallo'));
      addTearDown(cubit.close);
      await cubit.translate();
      expect(cubit.state.consent, isNotNull);

      await cubit.retryAfterConsent();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.result?.text, 'Hello');
      verify(() => mocks.repository.revokeOnce(consent)).called(1);
    });

    test('withdraws it at once when the retry fails right away', () async {
      var calls = 0;
      when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
        if (calls++ == 0) return Stream.error(consent);
        throw StateError('broken');
      });
      final cubit = mocks.build()..emit(readyState(input: 'Hallo'));
      addTearDown(cubit.close);
      await cubit.translate();

      await cubit.retryAfterConsent();

      expect(cubit.state.status, TranslateStatus.failure);
      verify(() => mocks.repository.revokeOnce(consent)).called(1);
    });

    test('a retry without a stopped request withdraws nothing', () async {
      mocks.stubTranslate();
      final cubit = mocks.build()..emit(readyState(input: 'Hallo'));
      addTearDown(cubit.close);

      await cubit.retryAfterConsent();

      verifyNever(() => mocks.repository.revokeOnce(any()));
    });
  });

  group('a result Google made after the device lacked the language', () {
    late TranslateMocks mocks;

    /// The default engine as a list could name it, with a provider for
    /// usage counting.
    const counted = TranslationEngine(
      id: 'mozhi:google',
      kind: EngineKind.mozhi,
      name: 'Google',
      mozhiEngine: 'google',
      providerId: 'google-usage',
    );

    /// A second on-device engine, the fallback after a suspect result.
    const otherDevice = TranslationEngine(
      id: 'offline:other',
      kind: EngineKind.offline,
      name: 'Other device engine',
      isLocal: true,
    );

    const sentence = 'Le temps est beau aujourd’hui et nous sortons.';

    setUp(() {
      mocks = TranslateMocks()..stubSettings(_firstRun);
    });

    void answer(TranslationResult online, [TranslationResult? device]) {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((call) {
        final engine = call.positionalArguments[0] as TranslationEngine;
        if (engine.id == offline.id) {
          return Stream.error(const OfflineModelMissingException(['fr']));
        }
        if (engine.id == otherDevice.id) return Stream.value(device!);
        return Stream.value(online);
      });
    }

    TranslateCubit build(List<TranslationEngine> engines) {
      final cubit = mocks.build()
        ..emit(
          readyState(
            engine: offline,
            engines: [...engines, offline],
            assistEngine: null,
            input: sentence,
          ),
        );
      addTearDown(cubit.close);
      return cubit;
    }

    test('counts usage for Google, not the on-device engine', () async {
      final tracker = _MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      mocks.usageTracker = tracker;
      answer(resultOf('The weather is nice', engine: counted));
      final cubit = build([counted]);

      await cubit.translate();

      expect(cubit.state.result?.engineId, counted.id);
      verify(
        () => tracker.recordText(
          'google-usage',
          input: sentence,
          output: 'The weather is nice',
        ),
      ).called(1);
    });

    test('a fallback notice names Google as the engine that was '
        'suspect', () async {
      answer(
        resultOf(sentence).copyWith(
          warnings: [const TranslationWarning(TranslationWarningKind.echo)],
        ),
        resultOf('The weather is nice', engine: otherDevice),
      );
      final cubit = build([google, otherDevice]);

      await cubit.translate();

      expect(cubit.state.result?.engineId, otherDevice.id);
      expect(
        cubit.state.fallback,
        const TranslationFallback(
          fromEngineName: 'Google',
          reason: TranslationWarningKind.echo,
          engineName: 'Other device engine',
          onDevice: true,
        ),
      );
    });

    test('a suspect result of the device itself still names it', () async {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((call) {
        final engine = call.positionalArguments[0] as TranslationEngine;
        if (engine.id == offline.id) {
          return Stream.value(
            resultOf(sentence, engine: offline).copyWith(
              warnings: [const TranslationWarning(TranslationWarningKind.echo)],
            ),
          );
        }
        return Stream.value(resultOf('The weather is nice', engine: engine));
      });
      final cubit = build([google, otherDevice]);

      await cubit.translate();

      expect(cubit.state.fallback?.fromEngineName, offline.name);
      expect(cubit.state.fallback?.engineName, otherDevice.name);
    });
  });
}
