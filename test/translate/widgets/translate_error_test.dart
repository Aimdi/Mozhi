import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// MyMemory request URL as Mozhi echoes it (the user's text in `q`).
Uri _myMemoryUrl(String text) => Uri.https(
  'api.mymemory.translated.net',
  '/get',
  {'langpair': 'en-AU|fr-BE', 'q': text},
);

final Uri _myMemory = _myMemoryUrl('Hello world');

void main() {
  setUpAll(registerTranslateFallbacks);

  // The device is online unless a test says otherwise.
  setUp(() => deviceOfflineCheck = () async => false);

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('describeTranslateError', () {
    test('maps raw Mozhi server messages to friendly text', () {
      final instance = Uri.parse('https://mozhi.example.org/api/translate');
      final table = <(Object, String, TranslateErrorFix)>[
        (
          MozhiApiException(
            'Engine does not exist or has been disabled.',
            statusCode: 500,
            uri: instance,
          ),
          l10n.translateErrorEngineUnavailable,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'Engine nopenot supported or implemented',
            statusCode: 500,
          ),
          l10n.translateErrorEngineUnavailable,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'Target Language Code invalid',
            statusCode: 500,
          ),
          l10n.translateErrorTargetUnsupported,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'Target language code invalid',
            statusCode: 500,
          ),
          l10n.translateErrorTargetUnsupported,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'Source language code invalid',
            statusCode: 500,
          ),
          l10n.translateErrorSourceUnsupported,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'runtime error: invalid memory address or nil pointer dereference',
            statusCode: 500,
          ),
          l10n.translateErrorEngineCrashed,
          TranslateErrorFix.none,
        ),
        (
          MozhiApiException(
            'Get "$_myMemory": Forbidden',
            statusCode: 500,
            uri: instance,
          ),
          l10n.translateErrorUpstreamHost('mozhi.example.org'),
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'Post "https://translate.google.com/_/batchexecute": Forbidden',
            statusCode: 500,
          ),
          l10n.translateErrorUpstream,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'ErrTransport: Get "https://translate.google.com/tts?q=secret": '
            'Forbidden',
            statusCode: 500,
          ),
          l10n.translateErrorUpstream,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException(
            'instance has been rate limited',
            statusCode: 500,
          ),
          l10n.translateErrorRateLimited,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException('Request Entity Too Large', statusCode: 413),
          l10n.translateErrorTooLong,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException('Google returned no result.'),
          l10n.translateErrorEmptyResult,
          TranslateErrorFix.none,
        ),
        (
          const MozhiApiException('Connection refused'),
          l10n.translateErrorUnreachableInstance,
          TranslateErrorFix.instances,
        ),
        (
          const MozhiApiException(
            'from, to, engine, text are required query strings.',
            statusCode: 400,
          ),
          l10n.translateErrorInstance('400'),
          TranslateErrorFix.instances,
        ),
      ];
      for (final (error, message, fix) in table) {
        final info = describeTranslateError(l10n, error);
        expect(info.message, message, reason: '$error');
        expect(info.fix, fix, reason: '$error');
        expect(info.offlineModels, isFalse, reason: '$error');
      }
    });

    test('ignores server-like phrases inside the user text', () {
      final info = describeTranslateError(
        l10n,
        const MozhiApiException(
          'Get "https://api.mymemory.translated.net/get?q=rate+limit+panic": '
          'Forbidden',
          statusCode: 500,
        ),
      );
      expect(info.message, l10n.translateErrorUpstream);
    });

    test('never shows upstream URLs or the user text', () {
      final info = describeTranslateError(
        l10n,
        MozhiApiException(
          'Get "${_myMemoryUrl('my secret text')}": Forbidden',
          statusCode: 500,
        ),
      );
      expect(info.message, isNot(contains('http')));
      expect(info.details, isNotNull);
      expect(info.details, contains('https://api.mymemory.translated.net/…'));
      expect(info.details, isNot(contains('secret')));
      expect(info.details, isNot(contains('langpair')));
      expect(info.details, isNot(contains('Hello')));
    });

    test('maps offline engine failures', () {
      final missing = describeTranslateError(
        l10n,
        const OfflineModelMissingException(['fr', 'xx']),
      );
      expect(
        missing.message,
        l10n.translateErrorOfflineModelMissingFor('French, xx'),
      );
      expect(missing.offlineModels, isTrue);

      final none = describeTranslateError(
        l10n,
        const OfflineModelMissingException([]),
      );
      expect(none.message, l10n.translateErrorOfflineModelMissing);

      final wrapped = describeTranslateError(
        l10n,
        StateError('PlatformException(OfflineModelMissingException(fr))'),
      );
      expect(wrapped.message, l10n.translateErrorOfflineModelMissing);
      expect(wrapped.offlineModels, isTrue);

      final unsupported = describeTranslateError(
        l10n,
        const OfflineLanguageUnsupportedException('tlh'),
      );
      expect(unsupported.message, l10n.translateErrorOfflineUnsupported);
      expect(unsupported.offlineModels, isFalse);
    });

    test('asks for the source language when it cannot be detected', () {
      final direct = describeTranslateError(
        l10n,
        const SourceLanguageRequiredException(engineId: 'offline:bergamot'),
      );
      expect(direct.message, l10n.translateErrorSourceLanguageRequired);
      expect(direct.chooseSourceLanguage, isTrue);
      expect(direct.offlineModels, isFalse);
      expect(direct.fix, TranslateErrorFix.none);
      expect(direct.consent, isNull);

      // A detection that failed on the way (e.g. Mozhi unreachable) too.
      final failed = describeTranslateError(
        l10n,
        const SourceLanguageRequiredException(
          engineId: 'ai:gemma',
          cause: MozhiApiException('Connection refused'),
        ),
      );
      expect(failed.message, l10n.translateErrorSourceLanguageRequired);
      expect(failed.chooseSourceLanguage, isTrue);
      expect(failed.fix, TranslateErrorFix.none);
    });

    test('asks for the source language when the exception is wrapped', () {
      final wrapped = describeTranslateError(
        l10n,
        StateError(
          'PlatformException(${const SourceLanguageRequiredException()})',
        ),
      );
      expect(wrapped.message, l10n.translateErrorSourceLanguageRequired);
      expect(wrapped.chooseSourceLanguage, isTrue);
      expect(wrapped.offlineModels, isFalse);

      // The outer exception wins over a cause named in its message.
      const inner = SourceLanguageRequiredException(
        cause: OfflineModelMissingException(['de']),
      );
      final withCause = describeTranslateError(
        l10n,
        StateError('Wrapped($inner)'),
      );
      expect(withCause.chooseSourceLanguage, isTrue);
      expect(withCause.offlineModels, isFalse);
    });

    test('does not ask for the source language for other errors', () {
      for (final error in <Object?>[
        null,
        StateError('boom'),
        const OfflineModelMissingException(['de']),
        const OfflineLanguageUnsupportedException('tlh'),
        const MozhiApiException('Source language code invalid'),
        const LlmApiException('down'),
      ]) {
        expect(
          describeTranslateError(l10n, error).chooseSourceLanguage,
          isFalse,
          reason: '$error',
        );
      }
    });

    test('keeps the AI provider mapping', () {
      expect(
        describeTranslateError(l10n, const LlmRefusalException('no')).message,
        l10n.translateErrorRefused,
      );
      expect(
        describeTranslateError(
          l10n,
          const LlmApiException('bad key', statusCode: 401),
        ).fix,
        TranslateErrorFix.providers,
      );
      expect(
        describeTranslateError(l10n, TimeoutException('slow')).message,
        l10n.translateErrorTimeout,
      );
      expect(describeTranslateError(l10n, null).details, isNull);
    });
  });

  group('describeTranslateError for AI answers without a status', () {
    TranslateErrorInfo describe(Object error) =>
        describeTranslateError(l10n, error);

    test('a response cut off at the output limit is not the connection', () {
      for (final error in const [
        LlmTruncatedException(partialText: 'Hallo', reason: 'length'),
        LlmTruncatedException(reason: 'model_context_window_exceeded'),
      ]) {
        final info = describe(error);
        expect(info.message, l10n.translateErrorTruncated);
        expect(info.fix, TranslateErrorFix.none);
        expect(info.title, l10n.translateErrorTitleProvider);
        expect(isNetworkFailure(error), isFalse);
      }
    });

    test('a connection dropped while streaming says so', () {
      const error = LlmInterruptedException(partialText: 'Hal');
      final info = describe(error);
      expect(info.message, l10n.translateErrorInterrupted);
      expect(info.fix, TranslateErrorFix.none);
      expect(isNetworkFailure(error), isFalse);
    });

    test("a model that stopped early, with the provider's reason", () {
      const language = LlmStoppedException(
        'Gemini does not support this language.',
        reason: 'LANGUAGE',
      );
      expect(describe(language).message, l10n.translateErrorModelLanguage);
      expect(isNetworkFailure(language), isFalse);

      const other = LlmStoppedException(
        'Gemini stopped without completing the response (OTHER).',
        reason: 'OTHER',
      );
      final info = describe(other);
      expect(info.message, l10n.translateErrorProviderStopped);
      expect(info.details, contains('(OTHER)'));
      expect(info.fix, TranslateErrorFix.none);
      expect(isNetworkFailure(other), isFalse);
    });

    test('other answers are the provider failing, with its detail', () {
      const error = LlmApiException('The model returned an empty response.');
      final info = describe(error);
      expect(info.message, l10n.translateErrorProviderFailed);
      expect(info.details, 'The model returned an empty response.');
      expect(info.fix, TranslateErrorFix.none);
      expect(info.title, l10n.translateErrorTitleProvider);
      expect(isNetworkFailure(error), isFalse);
    });

    test('no answer at all is the connection', () {
      for (final error in const [
        LlmApiException('Could not reach x: refused', unreachable: true),
        LlmApiException('reset', connectionDropped: true),
      ]) {
        final info = describe(error);
        expect(info.message, l10n.translateErrorUnreachableProvider);
        expect(info.fix, TranslateErrorFix.providers);
        expect(info.title, l10n.translateErrorTitleConnection);
        expect(isNetworkFailure(error), isTrue);
      }
    });

    test("Mozhi's validation errors are not the connection", () {
      const error = MozhiApiException(
        'Target language code invalid',
        statusCode: 500,
      );
      expect(isNetworkFailure(error), isFalse);
      final info = describe(error);
      expect(info.message, l10n.translateErrorTargetUnsupported);
      expect(info.title, isNot(l10n.translateErrorTitleConnection));
    });
  });

  group('sanitizeErrorDetails', () {
    test('reduces URLs to scheme and host and drops credentials', () {
      expect(
        sanitizeErrorDetails(
          const MozhiApiException(
            'Get "https://user:pass@lingva.example/api/v1/en/fr/Hello%20you": '
            'EOF',
            statusCode: 502,
          ),
        ),
        'HTTP 502: Get "https://lingva.example/…": EOF',
      );
      expect(
        sanitizeErrorDetails(
          const LlmApiException('see http://host.example', statusCode: 500),
        ),
        'HTTP 500: see http://host.example',
      );
      expect(
        sanitizeErrorDetails(const LlmApiException('socket closed')),
        'socket closed',
      );
    });

    test('collapses whitespace and caps the length', () {
      final long = sanitizeErrorDetails(StateError('a\n\n${'b' * 600}'))!;
      expect(long, startsWith('Bad state: a b'));
      expect(long.length, maxErrorDetailsLength + 1);
      expect(long, endsWith('…'));
      expect(sanitizeErrorDetails(null), isNull);
      expect(sanitizeErrorDetails(const MozhiApiException('  ')), isNull);
    });
  });

  group('TranslateErrorView', () {
    testWidgets('announces the message as a live region', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: MozhiApiException('Connection refused'),
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('translate_error_message'))),
        isSemantics(
          isLiveRegion: true,
          label:
              '${l10n.translateErrorTitleConnection}\n'
              '${l10n.translateErrorUnreachableInstance}',
        ),
      );
      handle.dispose();
    });

    group('title and body', () {
      testWidgets('a short error-coloured title above the message', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const TranslateErrorView(
            error: LlmApiException('bad key', statusCode: 401),
          ),
        );

        final theme = Theme.of(
          tester.element(find.byKey(const Key('translate_error_view'))),
        );
        final title = tester.widget<Text>(
          find.byKey(const Key('translate_error_title')),
        );
        expect(title.data, l10n.translateErrorTitleProvider);
        expect(title.style?.color, theme.colorScheme.error);
        final body = tester.widget<Text>(
          find.byKey(const Key('translate_error_message')),
        );
        expect(body.data, l10n.translateErrorAuth);
        expect(body.style?.color, theme.colorScheme.onSurface);
      });

      testWidgets('dense views show the message alone', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const TranslateErrorView(
            error: LlmApiException('bad key', statusCode: 401),
            dense: true,
          ),
        );

        expect(find.byKey(const Key('translate_error_title')), findsNothing);
        expect(find.text(l10n.translateErrorAuth), findsOneWidget);
      });

      test('names the kind of problem', () {
        String? title(Object error) =>
            describeTranslateError(l10n, error).title;
        expect(
          title(const MozhiApiException('Connection refused')),
          l10n.translateErrorTitleConnection,
        );
        expect(
          title(const MozhiApiException('nope', statusCode: 404)),
          l10n.translateErrorTitleInstance,
        );
        expect(
          title(const LlmRefusalException('no')),
          l10n.translateErrorTitleProvider,
        );
        expect(
          title(const OfflineModelMissingException(['de'])),
          l10n.translateErrorTitleDownload,
        );
        expect(
          title(const SourceLanguageRequiredException()),
          l10n.translateErrorTitleLanguage,
        );
        expect(title(StateError('x')), isNull);
      });

      test('says when another instance may help', () {
        bool mayHelp(Object error) =>
            describeTranslateError(l10n, error).anotherInstanceMayHelp;
        expect(mayHelp(const MozhiApiException('Connection refused')), isTrue);
        expect(
          mayHelp(const MozhiApiException('busy', statusCode: 429)),
          isTrue,
        );
        expect(
          mayHelp(const MozhiApiException('panic: boom', statusCode: 500)),
          isTrue,
        );
        expect(
          mayHelp(
            const MozhiApiException(
              'Engine does not exist or has been disabled.',
              statusCode: 500,
            ),
          ),
          isTrue,
        );
        expect(
          mayHelp(const MozhiApiException('too large', statusCode: 413)),
          isFalse,
        );
        expect(
          mayHelp(
            const MozhiApiException(
              'Target Language Code invalid',
              statusCode: 500,
            ),
          ),
          isFalse,
        );
        expect(mayHelp(const LlmApiException('x')), isFalse);
      });
    });

    group('offline', () {
      testWidgets('says "You\'re offline" when the device has no network', (
        tester,
      ) async {
        deviceOfflineCheck = () async => true;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: const MozhiApiException('Connection refused'),
            onRetry: () {},
          ),
        );
        await tester.pump();

        expect(find.text(l10n.translateErrorTitleOffline), findsOneWidget);
        expect(find.text(l10n.translateErrorOfflineBody), findsOneWidget);
        expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
        // Retry stays; the settings shortcut does not help offline.
        expect(find.byKey(const Key('translate_error_retry')), findsOneWidget);
        expect(find.byKey(const Key('translate_error_fix')), findsNothing);
      });

      testWidgets('is not checked for errors that are not network ones', (
        tester,
      ) async {
        var checks = 0;
        deviceOfflineCheck = () async {
          checks++;
          return true;
        };
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const TranslateErrorView(
            error: LlmApiException('bad key', statusCode: 401),
          ),
        );
        await tester.pump();

        expect(checks, 0);
        expect(find.text(l10n.translateErrorTitleOffline), findsNothing);
      });

      testWidgets('a failing check means online', (tester) async {
        deviceOfflineCheck = () async => throw StateError('no');
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const TranslateErrorView(
            error: MozhiApiException('Connection refused'),
          ),
        );
        await tester.pump();

        expect(find.text(l10n.translateErrorTitleConnection), findsOneWidget);
      });
    });

    group('a way forward on the Translate screen', () {
      const providerFailure = LlmApiException('unreachable', unreachable: true);

      /// A harness whose translation with [engine] failed with [error].
      TranslateHarness failedWith(
        Object error, {
        TranslationEngine engine = claude,
        List<MozhiInstance> instances = const [],
      }) {
        final harness = TranslateHarness(
          state: readyState(
            engine: engine,
            input: 'Hello',
            status: TranslateStatus.failure,
          ).copyWith(error: () => error),
          settings: AppSettings(instances: instances),
        );
        when(
          () => harness.repository.needsConsent(
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenReturn(false);
        when(() => harness.repository.destinationOf(any()))
            .thenAnswer((invocation) {
              final id = invocation.positionalArguments.first as String;
              return id.startsWith('ai:claude')
                  ? const CloudProviderDestination('Claude')
                  : const SelfHostedDestination('localhost');
            });
        return harness;
      }

      testWidgets('offers an allowed engine when an AI provider fails', (
        tester,
      ) async {
        final harness = failedWith(providerFailure);
        var retries = 0;
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: providerFailure,
            onRetry: () => retries++,
          ),
        );

        final use = find.byKey(const Key('translate_error_use_engine'));
        expect(use, findsOneWidget);
        expect(find.text(l10n.translateErrorUseEngine('DeepL')), findsOne);
        // Retry is the secondary action now.
        expect(
          tester.widget(find.byKey(const Key('translate_error_retry'))),
          isA<TextButton>(),
        );
        await tester.tap(use);
        verify(() => harness.translate.selectEngine(deepl)).called(1);
        await tester.tap(find.byKey(const Key('translate_error_retry')));
        expect(retries, 1);
      });

      testWidgets('never offers an engine that needs a new consent', (
        tester,
      ) async {
        final harness = failedWith(providerFailure);
        when(
          () => harness.repository.needsConsent(
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenReturn(true);
        await harness.pump(
          tester,
          child: TranslateErrorView(error: providerFailure, onRetry: () {}),
        );

        expect(
          find.byKey(const Key('translate_error_use_engine')),
          findsNothing,
        );
        expect(
          tester.widget(find.byKey(const Key('translate_error_retry'))),
          isA<FilledButton>(),
        );
      });

      testWidgets('offers nothing for an error of another screen', (
        tester,
      ) async {
        failedWith(providerFailure);
        final harness = failedWith(const LlmApiException('other'));
        await harness.pump(
          tester,
          child: const TranslateErrorView(error: providerFailure),
        );

        expect(
          find.byKey(const Key('translate_error_use_engine')),
          findsNothing,
        );
      });

      testWidgets('offers nothing while offline', (tester) async {
        deviceOfflineCheck = () async => true;
        final harness = failedWith(providerFailure);
        await harness.pump(
          tester,
          child: const TranslateErrorView(error: providerFailure),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('translate_error_use_engine')),
          findsNothing,
        );
      });

      testWidgets('tries the next instance when a Mozhi instance fails', (
        tester,
      ) async {
        const error = MozhiApiException('Connection refused');
        const first = MozhiInstance(url: 'https://a.example');
        const second = MozhiInstance(url: 'https://b.example');
        final harness = failedWith(
          error,
          engine: deepl,
          instances: const [first, second],
        );
        when(() => harness.settings.state)
            .thenReturn(const AppSettings(instances: [first, second]));
        when(() => harness.settings.preferInstance(any())).thenReturn(null);
        await harness.pump(
          tester,
          child: TranslateErrorView(error: error, onRetry: () {}),
        );

        final next = find.byKey(const Key('translate_error_next_instance'));
        expect(next, findsOneWidget);
        expect(find.text(l10n.translateErrorTryNextInstance), findsOneWidget);
        await tester.tap(next);
        // The new order reaches the repository first (a zero delay).
        await tester.pump(Duration.zero);
        verify(() => harness.settings.preferInstance(second.url)).called(1);
        verify(() => harness.repository.preferInstance(second.url)).called(1);
        verify(harness.translate.translate).called(1);
      });

      testWidgets('tries the first server again after a failover moved on, '
          'though it is first already', (tester) async {
        const error = MozhiApiException('Connection refused');
        const first = MozhiInstance(url: 'https://a.example');
        const second = MozhiInstance(url: 'https://b.example');
        final harness = failedWith(
          error,
          engine: deepl,
          instances: const [first, second],
        );
        when(() => harness.settings.state)
            .thenReturn(const AppSettings(instances: [first, second]));
        when(() => harness.settings.preferInstance(any())).thenReturn(null);
        // Requests start at the second: the first failed recently.
        when(() => harness.repository.activeInstance).thenReturn(second);
        await harness.pump(
          tester,
          child: TranslateErrorView(error: error, onRetry: () {}),
        );

        await tester.tap(
          find.byKey(const Key('translate_error_next_instance')),
        );
        await tester.pump(Duration.zero);
        // The list does not change; the repository forgets the failure.
        verify(() => harness.repository.preferInstance(first.url)).called(1);
        verify(harness.translate.translate).called(1);
      });

      testWidgets('does not translate once the screen is gone', (tester) async {
        const error = MozhiApiException('Connection refused');
        const first = MozhiInstance(url: 'https://a.example');
        const second = MozhiInstance(url: 'https://b.example');
        final harness = failedWith(
          error,
          engine: deepl,
          instances: const [first, second],
        );
        when(() => harness.settings.preferInstance(any())).thenReturn(null);
        when(() => harness.translate.isClosed).thenReturn(true);
        await harness.pump(
          tester,
          child: TranslateErrorView(error: error, onRetry: () {}),
        );

        await tester.tap(
          find.byKey(const Key('translate_error_next_instance')),
        );
        await tester.pump(Duration.zero);
        verify(() => harness.settings.preferInstance(second.url)).called(1);
        verifyNever(harness.translate.translate);
      });

      testWidgets('does not offer another instance with only one', (
        tester,
      ) async {
        const error = MozhiApiException('Connection refused');
        final harness = failedWith(
          error,
          engine: deepl,
          instances: const [MozhiInstance(url: 'https://a.example')],
        );
        await harness.pump(
          tester,
          child: TranslateErrorView(error: error, onRetry: () {}),
        );

        expect(
          find.byKey(const Key('translate_error_next_instance')),
          findsNothing,
        );
      });

      testWidgets('does not offer another instance when it would not help', (
        tester,
      ) async {
        const error = MozhiApiException('too large', statusCode: 413);
        final harness = failedWith(
          error,
          engine: deepl,
          instances: const [
            MozhiInstance(url: 'https://a.example'),
            MozhiInstance(url: 'https://b.example'),
          ],
        );
        await harness.pump(
          tester,
          child: TranslateErrorView(error: error, onRetry: () {}),
        );

        expect(
          find.byKey(const Key('translate_error_next_instance')),
          findsNothing,
        );
      });
    });

    group('without the Translate screen around', () {
      testWidgets('shows a network error alone', (tester) async {
        await tester.pumpApp(
          const Scaffold(
            body: TranslateErrorView(
              error: MozhiApiException('Connection refused'),
            ),
          ),
        );
        await tester.pump();

        expect(find.text(l10n.translateErrorTitleConnection), findsOneWidget);
        expect(
          find.byKey(const Key('translate_error_next_instance')),
          findsNothing,
        );
      });

      testWidgets('offers no other instance without the settings', (
        tester,
      ) async {
        const error = MozhiApiException('Connection refused');
        final translate = MockTranslateCubit();
        when(() => translate.state).thenReturn(
          readyState(
            input: 'Hello',
            status: TranslateStatus.failure,
          ).copyWith(error: () => error),
        );
        await tester.pumpApp(
          BlocProvider<TranslateCubit>.value(
            value: translate,
            child: const Scaffold(body: TranslateErrorView(error: error)),
          ),
        );

        expect(
          find.byKey(const Key('translate_error_next_instance')),
          findsNothing,
        );
      });

      testWidgets('offers no other engine without the repository', (
        tester,
      ) async {
        const error = LlmApiException('x', statusCode: 401);
        final translate = MockTranslateCubit();
        when(() => translate.state).thenReturn(
          readyState(
            engine: claude,
            input: 'Hello',
            status: TranslateStatus.failure,
          ).copyWith(error: () => error),
        );
        await tester.pumpApp(
          BlocProvider<TranslateCubit>.value(
            value: translate,
            child: const Scaffold(body: TranslateErrorView(error: error)),
          ),
        );

        expect(
          find.byKey(const Key('translate_error_use_engine')),
          findsNothing,
        );
      });
    });

    group('translateAlternativeEngine', () {
      test('skips the failed, on-device and cloud engines', () {
        final repository = MockTranslationRepository();
        when(
          () => repository.needsConsent(
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenReturn(false);
        when(() => repository.destinationOf(any())).thenThrow(StateError('x'));
        const offline = TranslationEngine(
          id: TranslationEngine.offlineId,
          kind: EngineKind.offline,
          name: 'On device',
        );
        final state = readyState(engine: claude)
            .copyWith(engines: const [claude, offline, ollama, deepl]);
        // Judged by the engine without a destination: the local AI model.
        expect(translateAlternativeEngine(state, repository), ollama);
        expect(translateAlternativeEngine(state, null), isNull);
        expect(
          translateAlternativeEngine(const TranslateState(), repository),
          isNull,
        );
      });

      test('a repository that cannot tell allows nothing', () {
        final repository = MockTranslationRepository();
        expect(
          translateAlternativeEngine(readyState(engine: claude), repository),
          isNull,
        );
      });
    });

    test('nextInstanceUrl wraps around the list', () {
      const a = MozhiInstance(url: 'https://a.example');
      const b = MozhiInstance(url: 'https://b.example');
      expect(nextInstanceUrl(a.url, const [a, b]), b.url);
      expect(nextInstanceUrl(b.url, const [a, b]), a.url);
      expect(nextInstanceUrl(null, const [a, b]), a.url);
      expect(nextInstanceUrl(a.url, const [a]), isNull);
    });

    testWidgets('details reveal the sanitized message only', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: MozhiApiException(
            'Get "https://api.mymemory.translated.net/get?q=Hello+world": '
            'Forbidden',
            statusCode: 500,
          ),
        ),
      );
      expect(find.text(l10n.translateErrorUpstream), findsOneWidget);
      expect(
        find.byKey(const Key('translate_error_details_text')),
        findsNothing,
      );
      await tester.tap(find.text('Details'));
      await tester.pump();
      final details = tester.widget<SelectableText>(
        find.byKey(const Key('translate_error_details_text')),
      );
      expect(
        details.data,
        'HTTP 500: Get "https://api.mymemory.translated.net/…": Forbidden',
      );
      expect(find.textContaining('Hello'), findsNothing);
      await tester.tap(find.text('Hide details'));
      await tester.pump();
      expect(
        find.byKey(const Key('translate_error_details_text')),
        findsNothing,
      );
    });

    testWidgets('offers the offline models page for missing models', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: OfflineModelMissingException(['de']),
        ),
      );
      expect(
        find.text(l10n.translateErrorOfflineModelMissingFor('German')),
        findsOneWidget,
      );
      // The size is unknown without the device's offline engine.
      await tester.tap(find.text('Download German'));
      verify(() => harness.router.push<void>('/settings/offline')).called(1);
    });

    testWidgets('names the download size the offline engine knows', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        offline: fakeBergamot(),
        child: const TranslateErrorView(
          error: OfflineModelMissingException(['de', 'en']),
        ),
      );
      // Both directions; English needs no download.
      expect(find.text('Download German (24.0 MB)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_error_fix')));
      verify(() => harness.router.push<void>('/settings/offline')).called(1);
    });

    testWidgets('missing models without languages keep the generic action', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: OfflineModelMissingException([]),
        ),
      );
      expect(find.text('Download languages'), findsOneWidget);
    });

    group('switch instance', () {
      testWidgets('replaces "Manage instances" for instance errors', (
        tester,
      ) async {
        var switched = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: const MozhiApiException('Connection refused'),
            onRetry: () {},
            onSwitchInstance: () => switched++,
          ),
        );
        expect(find.text('Manage instances'), findsNothing);
        await tester.tap(find.text('Switch instance'));
        expect(switched, 1);
      });

      testWidgets('is not offered for other errors or dense views', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: Column(
            children: [
              TranslateErrorView(
                error: const LlmApiException('down'),
                onSwitchInstance: () {},
              ),
              TranslateErrorView(
                error: const MozhiApiException('Connection refused'),
                dense: true,
                onSwitchInstance: () {},
              ),
            ],
          ),
        );
        expect(
          find.byKey(const Key('translate_error_switch_instance')),
          findsNothing,
        );
      });
    });

    group('source language required', () {
      const undetected = SourceLanguageRequiredException(
        engineId: 'offline:bergamot',
      );
      const german = Language(code: 'de', name: 'German');

      Finder filled(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      Finder text(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is TextButton),
      );

      testWidgets('offers "Choose language" instead of Retry', (tester) async {
        var chosen = 0;
        var retried = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: undetected,
            onRetry: () => retried++,
            onChooseSourceLanguage: () => chosen++,
          ),
        );
        expect(
          find.text(l10n.translateErrorSourceLanguageRequired),
          findsOneWidget,
        );
        // Detection had nothing to go on: retrying fails the same way.
        expect(find.text(l10n.commonRetry), findsNothing);
        expect(filled(l10n.translateChooseSourceLanguage), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('translate_error_choose_source')),
        );
        expect(chosen, 1);
        expect(retried, 0);
      });

      testWidgets('keeps Retry as a secondary action after a failed check', (
        tester,
      ) async {
        var retried = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: const SourceLanguageRequiredException(
              cause: MozhiApiException('Connection refused'),
            ),
            onRetry: () => retried++,
            onChooseSourceLanguage: () {},
            retrySemanticsLabel: 'Retry German',
          ),
        );
        expect(filled(l10n.translateChooseSourceLanguage), findsOneWidget);
        expect(text(l10n.commonRetry), findsOneWidget);
        expect(filled(l10n.commonRetry), findsNothing);
        expect(
          tester.widget<Text>(find.text(l10n.commonRetry)).semanticsLabel,
          'Retry German',
        );
        await tester.tap(find.byKey(const Key('translate_error_retry')));
        expect(retried, 1);
      });

      testWidgets('offers the suggested language as the main action', (
        tester,
      ) async {
        final used = <Language>[];
        var chosen = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: undetected,
            onRetry: () {},
            onChooseSourceLanguage: () => chosen++,
            suggestedSourceLanguage: german,
            onUseSourceLanguage: used.add,
          ),
        );
        final label = l10n.translateUseSourceLanguage('German');
        expect(label, 'Translate from German');
        expect(filled(label), findsOneWidget);
        expect(text(l10n.translateChooseSourceLanguage), findsOneWidget);
        await tester.tap(find.byKey(const Key('translate_error_use_source')));
        expect(used, [german]);
        await tester.tap(
          find.byKey(const Key('translate_error_choose_source')),
        );
        expect(chosen, 1);
      });

      testWidgets('needs a callback for the suggestion', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: undetected,
            onChooseSourceLanguage: () {},
            suggestedSourceLanguage: german,
          ),
        );
        expect(
          find.byKey(const Key('translate_error_use_source')),
          findsNothing,
        );
        expect(filled(l10n.translateChooseSourceLanguage), findsOneWidget);
      });

      testWidgets('dense views offer it too', (tester) async {
        var chosen = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: StateError('Wrapped($undetected)'),
            dense: true,
            onRetry: () {},
            onChooseSourceLanguage: () => chosen++,
          ),
        );
        // Wrapped: whether the check failed is unknown, so Retry stays.
        expect(text(l10n.commonRetry), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('translate_error_choose_source')),
        );
        expect(chosen, 1);
      });

      testWidgets('keeps Retry as the main action without a picker', (
        tester,
      ) async {
        var retried = 0;
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: undetected,
            onRetry: () => retried++,
            suggestedSourceLanguage: german,
            onUseSourceLanguage: (_) {},
          ),
        );
        expect(
          find.byKey(const Key('translate_error_choose_source')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('translate_error_use_source')),
          findsNothing,
        );
        expect(filled(l10n.commonRetry), findsOneWidget);
        await tester.tap(find.byKey(const Key('translate_error_retry')));
        expect(retried, 1);
      });

      testWidgets('is not offered for other errors', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: TranslateErrorView(
            error: const LlmApiException('down'),
            onRetry: () {},
            onChooseSourceLanguage: () {},
            suggestedSourceLanguage: german,
            onUseSourceLanguage: (_) {},
          ),
        );
        expect(
          find.byKey(const Key('translate_error_choose_source')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('translate_error_use_source')),
          findsNothing,
        );
        expect(filled(l10n.commonRetry), findsOneWidget);
      });
    });

    testWidgets('dense errors hide the settings shortcut', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: OfflineModelMissingException(['de']),
          dense: true,
        ),
      );
      expect(find.byKey(const Key('translate_error_fix')), findsNothing);
    });
  });
}
