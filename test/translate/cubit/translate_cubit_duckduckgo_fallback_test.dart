import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

const _one = MozhiInstance(url: 'https://one.example', isCustom: false);
const _two = MozhiInstance(url: 'https://two.example', isCustom: false);

const duckDuckGo = TranslationEngine(
  id: 'mozhi:duckduckgo',
  kind: EngineKind.mozhi,
  name: 'DuckDuckGo',
  mozhiEngine: 'duckduckgo',
);

/// Google's answer on today's public servers.
const _rateLimited = 'request failed with status code: 429';

/// DuckDuckGo's languages on Mozhi (part of libmozhi's list: Bing's codes,
/// `auto` among the sources only).
const _duckDuckGoLanguages = [
  'en',
  'de',
  'fr',
  'zh',
  'zh-TW',
  'he',
  'fil',
  'nb',
  'sr-Cyrl',
  'sr-Latn',
  'mn-Cyrl',
];

/// Every server: Google fails with [googleError] (HTTP 500, as Mozhi
/// reports upstream failures), DuckDuckGo translates (with
/// [duckDuckGoError], fails like that instead) and lists
/// [_duckDuckGoLanguages] (with [listError], fails like that instead).
class _Servers {
  String googleError = _rateLimited;
  String? duckDuckGoError;
  String? listError;
  final List<({String host, String engine, String text})> sent = [];

  /// The `from` > `to` codes of every translation request.
  final List<String> pairs = [];

  /// The language lists asked for (`<endpoint>?<engine>`).
  final List<String> lists = [];

  http.Client get client => MockClient((request) async {
    if (request.method == 'GET') {
      final endpoint = request.url.pathSegments.last;
      final engine = request.url.queryParameters['engine']!;
      lists.add('$endpoint?$engine');
      if (listError case final error?) return http.Response(error, 500);
      return http.Response(
        jsonEncode([
          if (endpoint == 'source_languages') {'Id': 'auto', 'Name': 'Detect'},
          for (final code in _duckDuckGoLanguages) {'Id': code, 'Name': code},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final fields = request.bodyFields;
    final engine = fields['engine']!;
    sent.add((host: request.url.host, engine: engine, text: fields['text']!));
    pairs.add('${fields['from']}>${fields['to']}');
    if (engine == 'google') return http.Response(googleError, 500);
    if (duckDuckGoError case final error?) return http.Response(error, 500);
    return http.Response(
      jsonEncode({
        'engine': engine,
        'translated-text': '$engine: ${fields['text']}',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  List<String> get engines => [for (final request in sent) request.engine];
}

AllInstancesFailedException _googleFailed({
  Object cause = const MozhiApiException(_rateLimited, statusCode: 500),
  List<Object>? failures,
}) => AllInstancesFailedException.from(
  cause,
  engine: google,
  instances: const [_one, _two],
  failures: failures ?? [cause],
);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('duckDuckGoFallbackApplies', () {
    const on = AppSettings(privacyMode: PrivacyMode.online);

    bool applies(
      Object error, {
      TranslationEngine engine = google,
      AppSettings settings = on,
      PrivacyMode? privacyMode,
    }) => TranslateCubit.duckDuckGoFallbackApplies(
      error,
      engine: engine,
      settings: settings,
      privacyMode: privacyMode,
    );

    test('when Google failed on every server and the user turned it on', () {
      expect(applies(_googleFailed()), isTrue);
      expect(applies(_googleFailed(), privacyMode: PrivacyMode.online), isTrue);
      expect(
        applies(
          _googleFailed(),
          settings: on.copyWith(privacyMode: PrivacyMode.offlineFirst),
        ),
        isTrue,
      );
    });

    test('by default (on, unless the user turns it off)', () {
      expect(const AppSettings().fallbackToDuckDuckGo, isTrue);
      expect(applies(_googleFailed()), isTrue);
    });

    test('never while the user turned it off', () {
      expect(
        applies(
          _googleFailed(),
          settings: on.copyWith(
            fallbackToDuckDuckGo: false,
            fallbackToDuckDuckGoChosen: true,
          ),
        ),
        isFalse,
      );
    });

    test('never in Offline only', () {
      expect(
        applies(
          _googleFailed(),
          settings: on.copyWith(privacyMode: PrivacyMode.offlineOnly),
        ),
        isFalse,
      );
      expect(
        applies(_googleFailed(), privacyMode: PrivacyMode.offlineOnly),
        isFalse,
      );
    });

    test('only for Google', () {
      expect(applies(_googleFailed(), engine: duckDuckGo), isFalse);
      expect(applies(_googleFailed(), engine: deepl), isFalse);
      expect(applies(_googleFailed(), engine: claude), isFalse);
      final deeplFailed = AllInstancesFailedException.from(
        const MozhiApiException('boom', statusCode: 500),
        engine: deepl,
        instances: const [_one],
      );
      expect(applies(deeplFailed, engine: deepl), isFalse);
    });

    test('only when every server failed', () {
      expect(
        applies(const MozhiApiException(_rateLimited, statusCode: 500)),
        isFalse,
      );
      expect(applies(TimeoutException('slow')), isFalse);
      expect(
        applies(
          SourceLanguageRequiredException(
            engineId: google.id,
            cause: _googleFailed(),
          ),
        ),
        isFalse,
      );
    });

    test('never for a consent refusal', () {
      expect(
        applies(
          ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: const PublicInstanceDestination(
              'one.example',
              engine: 'google',
            ),
            engineId: google.id,
          ),
        ),
        isFalse,
      );
    });

    test('never for a network policy refusal', () {
      final refused = MozhiApiException(
        CleartextRefusedException(Uri.parse('http://one.example')).message,
      );
      expect(
        applies(_googleFailed(cause: refused, failures: [refused])),
        isFalse,
      );
      // Even when another server answered: the reported failure decides.
      expect(
        applies(
          _googleFailed(
            cause: refused,
            failures: [
              const MozhiApiException(_rateLimited, statusCode: 500),
              refused,
            ],
          ),
        ),
        isFalse,
      );
    });

    test('not when no server could be reached', () {
      const unreachable = MozhiApiException('Connection refused');
      expect(
        applies(_googleFailed(cause: unreachable, failures: [unreachable])),
        isFalse,
      );
    });
  });

  group('the DuckDuckGo fallback', () {
    late TranslateMocks mocks;
    late _Servers servers;
    late EgressLedger ledger;
    late TranslationRepository repository;
    late List<HistoryEntry> saved;

    setUp(() {
      mocks = TranslateMocks();
      servers = _Servers();
      ledger = EgressLedger();
      saved = [];
      when(() => mocks.history.add(any())).thenAnswer((invocation) async {
        saved.add(invocation.positionalArguments.single as HistoryEntry);
      });
      final client = EgressRecordingClient(servers.client, ledger: ledger);
      repository =
          TranslationRepository(
            mozhiClientFactory: (uri) =>
                MozhiApiClient(baseUrl: uri, httpClient: client),
            cache: TranslationCache(maxEntries: 0),
          )..updateConfiguration(
            instances: const [_one, _two],
            providers: const [],
          );
    });

    /// [settings] in the settings cubit and the repository.
    void use(AppSettings settings) {
      mocks.stubSettings(settings);
      repository.updatePrivacy(
        mode: settings.privacyMode,
        approvedPairs: settings.networkPairs,
      );
    }

    Future<TranslateCubit> start({
      TranslationEngine engine = google,
      String input = 'Hallo',
      Language source = de,
      Language target = en,
      List<Language> extraTargets = const [],
    }) async {
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
          engine: engine,
          engines: const [google, duckDuckGo, deepl],
          assistEngine: null,
          input: input,
          source: source,
          target: target,
        ).copyWith(
          extraTargets: extraTargets,
          targetLanguages: {...targets, target, ...extraTargets}.toList(),
        ),
      );
      return cubit;
    }

    const online = AppSettings(
      instances: [_one, _two],
      engineId: 'mozhi:google',
      privacyMode: PrivacyMode.online,
    );

    group('when it applies', () {
      test('DuckDuckGo translates through the same servers, after Google '
          'failed on every one', () async {
        use(online);
        final cubit = await start();
        await cubit.translate();

        expect(servers.engines, ['google', 'google', 'duckduckgo']);
        expect(
          [for (final request in servers.sent) request.host],
          ['one.example', 'two.example', 'one.example'],
        );
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.error, isNull);
        expect(cubit.state.result?.text, 'duckduckgo: Hallo');
        // The selection stays Google.
        expect(cubit.state.engine, google);
      });

      test('the result, its chip and its note name DuckDuckGo', () async {
        use(online);
        final cubit = await start();
        await cubit.translate();

        final result = cubit.state.result!;
        expect(result.engineId, duckDuckGo.id);
        expect(result.engineName, 'DuckDuckGo');
        expect(
          result.destination,
          const PublicInstanceDestination('one.example', engine: 'duckduckgo'),
        );
        expect(
          cubit.state.fallback,
          const TranslationFallback(
            fromEngineName: 'Google',
            engineName: 'DuckDuckGo',
            onDevice: false,
            allServersFailed: true,
          ),
        );
      });

      test('the history entry names DuckDuckGo', () async {
        use(online);
        final cubit = await start();
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);

        expect(saved, hasLength(1));
        expect(saved.single.engineId, duckDuckGo.id);
        expect(saved.single.engineName, 'DuckDuckGo');
        expect(saved.single.translation, 'duckduckgo: Hallo');
      });

      test('the network log names the engine of every request', () async {
        use(online);
        final cubit = await start();
        await cubit.translate();

        final translations = [
          for (final entry in ledger.entries)
            if (entry.method == 'POST') entry,
        ];
        expect(
          [for (final entry in translations) entry.engine],
          ['google', 'google', 'duckduckgo'],
        );
        expect(
          [for (final entry in translations) entry.outcome],
          [
            EgressOutcome.httpError,
            EgressOutcome.httpError,
            EgressOutcome.succeeded,
          ],
        );
      });

      test('extra targets fall back too', () async {
        use(online);
        final cubit = await start(extraTargets: const [fr]);
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);

        final extra = cubit.state.extraTranslationFor(fr)!;
        expect(extra.status, TranslateStatus.success);
        expect(extra.result?.engineId, duckDuckGo.id);
        expect(extra.result?.text, 'duckduckgo: Hallo');
      });

      test('a DuckDuckGo failure is shown as it is', () async {
        use(online);
        servers.duckDuckGoError = 'upstream down';
        final cubit = await start();
        await cubit.translate();

        expect(servers.engines, [
          'google',
          'google',
          'duckduckgo',
          'duckduckgo',
        ]);
        expect(cubit.state.status, TranslateStatus.failure);
        expect(
          cubit.state.error,
          isA<AllInstancesFailedException>().having(
            (e) => e.engine.id,
            'engine',
            duckDuckGo.id,
          ),
        );
      });
    });

    group("Google's languages", () {
      const chinese = Language(code: 'zh-CN', name: 'Chinese (Simplified)');
      const hebrew = Language(code: 'iw', name: 'Hebrew');
      const filipino = Language(code: 'tl', name: 'Filipino');
      const norwegian = Language(code: 'no', name: 'Norwegian');
      const serbian = Language(code: 'sr', name: 'Serbian');
      const mongolian = Language(code: 'mn', name: 'Mongolian');
      const javanese = Language(code: 'jw', name: 'Javanese');

      Matcher googleFailure() => isA<AllInstancesFailedException>()
          .having((e) => e.engine.id, 'engine', google.id)
          .having((e) => e.rateLimited, 'rateLimited', isTrue);

      test('are sent to DuckDuckGo by its own codes', () async {
        use(online);
        for (final (source, target, pair) in [
          (hebrew, chinese, 'he>zh'),
          (filipino, norwegian, 'fil>nb'),
          (Language.auto, serbian, 'auto>sr-Cyrl'),
          (de, mongolian, 'de>mn-Cyrl'),
        ]) {
          servers.pairs.clear();
          final cubit = await start(source: source, target: target);
          await cubit.translate();

          expect(servers.pairs.last, pair);
          expect(cubit.state.result?.engineId, duckDuckGo.id);
          // The selection keeps Google's codes.
          expect(cubit.state.source, source);
          expect(cubit.state.target, target);
        }
        // DuckDuckGo's lists are loaded once.
        expect(servers.lists, [
          'source_languages?duckduckgo',
          'target_languages?duckduckgo',
        ]);
      });

      test("that DuckDuckGo lacks: no fallback, Google's failure is "
          'shown', () async {
        use(online);
        final cubit = await start(target: javanese);
        await cubit.translate();

        expect(servers.engines, ['google', 'google']);
        expect(cubit.state.status, TranslateStatus.failure);
        expect(cubit.state.error, googleFailure());
        expect(cubit.state.fallback, isNull);
        expect(cubit.state.engine, google);
      });

      test(
        "when DuckDuckGo still rejects them, Google's failure is shown",
        () async {
          use(online);
          servers.duckDuckGoError = 'Target language code invalid';
          final cubit = await start();
          await cubit.translate();

          expect(servers.engines, ['google', 'google', 'duckduckgo']);
          expect(cubit.state.error, googleFailure());
        },
      );

      test(
        "an instance without DuckDuckGo: Google's failure is shown",
        () async {
          use(online);
          servers.duckDuckGoError =
              'Engine does not exist or has been disabled';
          final cubit = await start();
          await cubit.translate();
          expect(cubit.state.error, googleFailure());
        },
      );

      for (final listError in [
        'Engine does not exist or has been disabled',
        'upstream down',
      ]) {
        test("when DuckDuckGo's lists cannot be loaded ($listError), "
            "Google's failure is shown", () async {
          use(online);
          servers.listError = listError;
          final cubit = await start();
          await cubit.translate();

          expect(servers.engines, ['google', 'google']);
          expect(cubit.state.error, googleFailure());
        });
      }

      test("extra targets DuckDuckGo lacks keep Google's failure", () async {
        use(online);
        final cubit = await start(extraTargets: const [javanese, chinese]);
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);

        expect(
          cubit.state.extraTranslationFor(javanese)?.error,
          googleFailure(),
        );
        final chineseResult = cubit.state.extraTranslationFor(chinese)!;
        expect(chineseResult.result?.engineId, duckDuckGo.id);
        expect(servers.pairs, contains('de>zh'));
      });

      test('"Use DuckDuckGo when Google fails" maps them too', () async {
        when(
          () => mocks.settings.setFallbackToDuckDuckGo(
            enabled: any(named: 'enabled'),
          ),
        ).thenAnswer((invocation) {
          mocks.stubSettings(
            mocks.settings.state.copyWith(fallbackToDuckDuckGo: true),
          );
        });
        use(online.copyWith(fallbackToDuckDuckGo: false));
        final cubit = await start(target: chinese);
        await cubit.translate();
        await cubit.useDuckDuckGoWhenGoogleFails();

        expect(servers.pairs.last, 'de>zh');
        expect(cubit.state.result?.engineId, duckDuckGo.id);

        // Into a language DuckDuckGo lacks, Google's failure stays.
        final other = await start(target: javanese);
        await other.translate();
        await other.useDuckDuckGoWhenGoogleFails();
        expect(other.state.error, googleFailure());
      });
    });

    group('never', () {
      Future<TranslateCubit> failsWithGoogle(AppSettings settings) async {
        use(settings);
        final cubit = await start();
        await cubit.translate();
        return cubit;
      }

      test('while it is off', () async {
        final cubit = await failsWithGoogle(
          online.copyWith(fallbackToDuckDuckGo: false),
        );
        expect(servers.engines, ['google', 'google']);
        expect(cubit.state.error, isA<AllInstancesFailedException>());
        expect(cubit.state.result, isNull);
        expect(saved, isEmpty);
      });

      test('in Offline only', () async {
        final cubit = await failsWithGoogle(
          online.copyWith(privacyMode: PrivacyMode.offlineOnly),
        );
        expect(servers.sent, isEmpty);
        expect(cubit.state.consent?.exception.kind, ConsentKind.offlineOnly);
        expect(cubit.state.consent?.exception.engineId, google.id);
      });

      test('with another engine', () async {
        use(online);
        final cubit = await start(engine: deepl);
        servers.googleError = 'unused';
        await cubit.translate();
        // DeepL answers like DuckDuckGo here: no fallback was needed.
        expect(servers.engines, ['deepl']);
        expect(cubit.state.fallback, isNull);
      });

      test('when DuckDuckGo is the engine already', () async {
        use(online);
        final cubit = await start(engine: duckDuckGo);
        await cubit.translate();
        expect(servers.engines, ['duckduckgo']);
        expect(cubit.state.fallback, isNull);
        expect(cubit.state.result?.engineId, duckDuckGo.id);
      });
    });

    group('consent', () {
      const offlineFirst = AppSettings(
        instances: [_one, _two],
        engineId: 'mozhi:google',
      );

      test(
        'an approved pair covers DuckDuckGo, as when the user picks it',
        () async {
          use(offlineFirst.copyWith(networkPairs: ['de>en']));
          final cubit = await start();
          await cubit.translate();
          expect(servers.engines, ['google', 'google', 'duckduckgo']);
          expect(cubit.state.result?.engineId, duckDuckGo.id);
        },
      );

      test('"Once" for Google does not cover DuckDuckGo: it is asked for, '
          'and its retry goes straight there', () async {
        use(offlineFirst);
        final cubit = await start();
        await cubit.translate();
        final forGoogle = cubit.state.consent!.exception;
        expect(forGoogle.engineId, google.id);
        expect(servers.sent, isEmpty);

        repository.allowOnce(forGoogle);
        await cubit.retryAfterConsent();

        // Google failed on both servers; nothing went to DuckDuckGo.
        expect(servers.engines, ['google', 'google']);
        final forDuckDuckGo = cubit.state.consent!.exception;
        expect(forDuckDuckGo.kind, ConsentKind.pair);
        expect(forDuckDuckGo.engineId, duckDuckGo.id);
        expect(
          forDuckDuckGo.destination,
          const PublicInstanceDestination('one.example', engine: 'duckduckgo'),
        );
        expect(cubit.state.result, isNull);

        repository.allowOnce(forDuckDuckGo);
        await cubit.retryAfterConsent();

        // Google is not asked again.
        expect(servers.engines, ['google', 'google', 'duckduckgo']);
        expect(cubit.state.consent, isNull);
        expect(cubit.state.result?.engineId, duckDuckGo.id);
        expect(cubit.state.fallback?.allServersFailed, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(saved.single.engineId, duckDuckGo.id);
      });

      test('a dismissed DuckDuckGo prompt sends nothing to it', () async {
        use(offlineFirst);
        final cubit = await start();
        await cubit.translate();
        repository.allowOnce(cubit.state.consent!.exception);
        await cubit.retryAfterConsent();
        cubit.dismissConsent();

        expect(servers.engines, ['google', 'google']);
        expect(cubit.state.consent, isNull);
        expect(cubit.state.result, isNull);
      });
    });

    group('useDuckDuckGoWhenGoogleFails', () {
      setUp(() {
        when(
          () => mocks.settings.setFallbackToDuckDuckGo(
            enabled: any(named: 'enabled'),
          ),
        ).thenAnswer((invocation) {
          final enabled = invocation.namedArguments[#enabled] as bool;
          mocks.stubSettings(
            mocks.settings.state.copyWith(fallbackToDuckDuckGo: enabled),
          );
        });
      });

      test('turns it on and translates with DuckDuckGo without asking Google '
          'again', () async {
        use(online.copyWith(fallbackToDuckDuckGo: false));
        final cubit = await start();
        await cubit.translate();
        expect(cubit.state.error, isA<AllInstancesFailedException>());
        expect(servers.engines, ['google', 'google']);

        await cubit.useDuckDuckGoWhenGoogleFails();

        verify(() => mocks.settings.setFallbackToDuckDuckGo(enabled: true))
            .called(1);
        expect(servers.engines, ['google', 'google', 'duckduckgo']);
        expect(cubit.state.result?.engineId, duckDuckGo.id);
        expect(cubit.state.fallback?.allServersFailed, isTrue);

        // From now on it takes over by itself.
        cubit.setInput('Tschüss');
        await cubit.translate();
        expect(servers.engines.skip(3), ['google', 'google', 'duckduckgo']);
      });

      test(
        'after another error it only turns it on and translates again',
        () async {
          use(online.copyWith(fallbackToDuckDuckGo: false));
          final cubit = await start();
          servers.googleError = 'unused';
          await cubit.useDuckDuckGoWhenGoogleFails();
          expect(servers.engines, ['google', 'google', 'duckduckgo']);
        },
      );

      test('still asks for consent where it is needed', () async {
        use(
          const AppSettings(
            instances: [_one, _two],
            engineId: 'mozhi:google',
            fallbackToDuckDuckGo: false,
          ),
        );
        final cubit = await start();
        await cubit.translate();
        repository.allowOnce(cubit.state.consent!.exception);
        await cubit.retryAfterConsent();
        expect(cubit.state.error, isA<AllInstancesFailedException>());

        await cubit.useDuckDuckGoWhenGoogleFails();

        expect(servers.engines, ['google', 'google']);
        expect(cubit.state.consent?.exception.engineId, duckDuckGo.id);
      });
    });
  });
}
