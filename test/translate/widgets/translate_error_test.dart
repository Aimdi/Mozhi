import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

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
          label: l10n.translateErrorUnreachableInstance,
        ),
      );
      handle.dispose();
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
