import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

const _unreachable = MozhiApiException('connection refused');

final _offline = TranslationEngine.offline();

/// A failed English -> French translation on [engine] with [error].
TranslateState _failed(Object error, {TranslationEngine engine = deepl}) =>
    readyState(
      engine: engine,
      source: english,
      input: 'Hello world',
      status: TranslateStatus.failure,
    ).copyWith(engines: [deepl, _offline], error: () => error);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('isNetworkFailure', () {
    test('is true when the server could not answer or failed', () {
      for (final error in <Object>[
        _unreachable,
        const MozhiApiException('Internal error', statusCode: 500),
        const MozhiApiException('Bad gateway', statusCode: 502),
        const LlmApiException('connection reset'),
        const LlmApiException('overloaded', statusCode: 503),
        const MtApiException('offline', kind: MtErrorKind.network),
        const MtApiException('slow', kind: MtErrorKind.timeout),
        const MtApiException('down', kind: MtErrorKind.server, statusCode: 500),
        TimeoutException('slow'),
      ]) {
        expect(isNetworkFailure(error), isTrue, reason: '$error');
      }
    });

    test('is false for answers, refusals and everything else', () {
      for (final error in <Object?>[
        null,
        const MozhiApiException('Bad request', statusCode: 400),
        const MozhiApiException('Too many', statusCode: 429),
        const LlmApiException('Unauthorized', statusCode: 401),
        const LlmRefusalException('no'),
        const MtApiException('quota', kind: MtErrorKind.quotaExceeded),
        const OfflineModelMissingException(['fr']),
        StateError('bug'),
      ]) {
        expect(isNetworkFailure(error), isFalse, reason: '$error');
      }
    });
  });

  group('TranslateErrorView on a network failure', () {
    Future<TranslateHarness> pump(
      WidgetTester tester,
      TranslateState state, {
      Object? shown,
      bool dense = false,
      FakeOfflineTranslator? offline,
    }) async {
      final harness = TranslateHarness(state: state);
      await harness.pump(
        tester,
        child: TranslateErrorView(
          error: shown ?? state.error,
          dense: dense,
          onRetry: () {},
        ),
        offline: offline ?? FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pump();
      return harness;
    }

    testWidgets('offers to translate on this device', (tester) async {
      final harness = await pump(tester, _failed(_unreachable));

      final use = find.byKey(const Key('translate_offline_use'));
      expect(use, findsOneWidget);
      expect(find.text('Translate on this device'), findsOneWidget);
      // Retry is still there.
      expect(find.byKey(const Key('translate_error_retry')), findsOneWidget);

      await tester.tap(use);
      verify(() => harness.translate.selectEngine(_offline)).called(1);
    });

    testWidgets('offers the download when a model is missing', (tester) async {
      final harness = await pump(
        tester,
        _failed(const MozhiApiException('Bad gateway', statusCode: 502)),
        offline: FakeOfflineTranslator(),
      );

      expect(
        find.byKey(const Key('translate_offline_download')),
        findsOneWidget,
      );
      expect(find.text('Download French'), findsOneWidget);

      await tester.tap(find.text('Manage languages'));
      verify(() => harness.router.push<void>(AppRoutes.offline)).called(1);
    });

    testWidgets('only for the translation of the Translate screen', (
      tester,
    ) async {
      // Another error object than the screen's (e.g. a compare card).
      await pump(
        tester,
        _failed(_unreachable),
        shown: const MozhiApiException('connection reset'),
      );
      expect(find.byKey(const Key('translate_error_offline')), findsNothing);
    });

    testWidgets('not when the device cannot help or it is not the network', (
      tester,
    ) async {
      for (final (state, dense, offline) in [
        (_failed(_unreachable), true, null),
        (_failed(_unreachable, engine: _offline), false, null),
        (
          _failed(const MozhiApiException('Bad request', statusCode: 400)),
          false,
          null,
        ),
        (
          _failed(_unreachable),
          false,
          FakeOfflineTranslator(supportedLanguages: const {'en', 'de'}),
        ),
        (
          _failed(_unreachable),
          false,
          FakeOfflineTranslator(isAvailable: false),
        ),
      ]) {
        await pump(tester, state, dense: dense, offline: offline);
        expect(
          find.byKey(const Key('translate_offline_use')),
          findsNothing,
          reason: '$state',
        );
        expect(
          find.byKey(const Key('translate_offline_download')),
          findsNothing,
        );
      }
    });

    testWidgets('nothing outside the Translate screen', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(body: TranslateErrorView(error: _unreachable)),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('translate_error_offline')), findsNothing);
    });
  });

  group('OfflinePairOffer', () {
    test('takes its pair from the consent or as given', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:google',
        source: 'de',
        target: 'ja',
      );

      const fromConsent = OfflinePairOffer(consent: consent);
      expect(fromConsent.pairSource, 'de');
      expect(fromConsent.pairTarget, 'ja');

      const pair = OfflinePairOffer.pair(source: 'auto', target: 'fr');
      expect(pair.consent, isNull);
      expect(pair.pairSource, 'auto');
      expect(pair.pairTarget, 'fr');
    });

    testWidgets('follows a new pair', (tester) async {
      final harness = TranslateHarness(
        state: readyState().copyWith(engines: [deepl, _offline]),
      );
      final offline = FakeOfflineTranslator(downloaded: {'fr'});
      Widget offer(String target) =>
          OfflinePairOffer.pair(source: 'en', target: target);

      await harness.pump(tester, child: offer('fr'), offline: offline);
      await tester.pump();
      expect(find.text('Translate on this device'), findsOneWidget);

      await harness.pump(tester, child: offer('de'), offline: offline);
      await tester.pump();
      expect(find.text('Download German'), findsOneWidget);
    });
  });
}
