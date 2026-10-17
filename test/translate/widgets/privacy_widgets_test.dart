import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _destination = PublicInstanceDestination(
  'mozhi.example.org',
  engine: 'google',
);

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: _destination,
  engineId: 'mozhi:google',
  source: 'en',
  target: 'fr',
);

TranslateState _waiting({bool automatic = false, int id = 1}) =>
    readyState(input: 'Hello world').copyWith(
      consent: () =>
          ConsentRequest(exception: _consent, id: id, automatic: automatic),
    );

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbackValue(_consent);
  });

  TranslateHarness harnessFor(TranslateState state) {
    final harness = TranslateHarness(state: state);
    when(() => harness.repository.instances).thenReturn(const []);
    return harness;
  }

  group('TranslateConsentListener', () {
    testWidgets('asks with a dialog for a translation the user asked for', (
      tester,
    ) async {
      final harness = harnessFor(readyState(input: 'Hello world'));
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        harness.translate,
        states.stream,
        initialState: readyState(input: 'Hello world'),
      );
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
      );
      states.add(_waiting());
      await tester.pumpAndSettle();
      expect(
        find.text('Send this text to Google via mozhi.example.org?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      verify(() => harness.repository.allowOnce(_consent)).called(1);
      verify(harness.translate.retryAfterConsent).called(1);
    });

    testWidgets('never opens it for an instant translation', (tester) async {
      final harness = harnessFor(readyState(input: 'Hello world'));
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        harness.translate,
        states.stream,
        initialState: readyState(input: 'Hello world'),
      );
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
      );
      states.add(_waiting(automatic: true));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('Cancel keeps the request waiting', (tester) async {
      final harness = harnessFor(readyState(input: 'Hello world'));
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        harness.translate,
        states.stream,
        initialState: readyState(input: 'Hello world'),
      );
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
      );
      states.add(_waiting());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(harness.translate.retryAfterConsent);
    });
  });

  group('OutputCard', () {
    testWidgets('shows the inline prompt instead of the output', (
      tester,
    ) async {
      final harness = harnessFor(_waiting(automatic: true));
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      expect(
        find.text(
          'Translating this needs the network. Send it to Google via '
          'mozhi.example.org?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Always for English → French'));
      await tester.pump();
      verify(() => harness.settings.approveNetworkPair('en>fr')).called(1);
      verify(() => harness.repository.allowOnce(_consent)).called(1);
      verify(harness.translate.retryAfterConsent).called(1);
    });

    testWidgets('names where the translation was sent', (tester) async {
      final harness = harnessFor(
        translatedState(
          result: helloResult.copyWith(destination: _destination),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.byKey(const Key('translate_output_destination')),
        findsOneWidget,
      );
      expect(find.text('Google via mozhi.example.org'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_output_destination')));
      await tester.pumpAndSettle();
      expect(find.text('Where your text goes'), findsOneWidget);
    });

    testWidgets('shows why the engine could not load', (tester) async {
      final harness = harnessFor(
        readyState().copyWith(
          enginesStatus: EnginesStatus.failure,
          error: () => Exception('boom'),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_engine_error')), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(harness.translate.loadEngines).called(1);
    });
  });

  group('TranslateView', () {
    testWidgets('asks to choose an engine when none is selected', (
      tester,
    ) async {
      final harness = harnessFor(
        readyState().copyWith(engine: () => null, assistEngine: () => null),
      );
      await harness.pump(tester);
      expect(find.byKey(const Key('translate_choose_engine')), findsOneWidget);
      expect(find.text('Choose a translation engine'), findsOneWidget);
      await tester.tap(find.text('Choose engine'));
      await tester.pumpAndSettle();
      verify(harness.translate.loadDeferredEngines).called(1);
      expect(find.byType(EngineSheet), findsOneWidget);
    });

    testWidgets('explains engine lists kept off the network', (tester) async {
      const lists = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:',
      );
      final harness = harnessFor(
        const TranslateState(
          enginesStatus: EnginesStatus.failure,
          error: lists,
        ),
      );
      await harness.pump(tester);
      expect(
        find.byKey(const Key('translate_no_engines_consent')),
        findsOneWidget,
      );
      expect(find.textContaining('Load the engines'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      verify(harness.repository.allowMetadataRequests).called(1);
      verify(() => harness.translate.loadEngines(refresh: true)).called(1);
    });
  });

  group('errors', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    test('consent and network policy refusals are described', () {
      final consent = describeTranslateError(l10n, _consent);
      expect(consent.consent, _consent);
      expect(consent.message, contains('Google via mozhi.example.org'));
      expect(
        describeTranslateError(
          l10n,
          CleartextRefusedException(Uri.parse('http://mozhi.example.org')),
        ).message,
        l10n.commonErrorCleartextRefused,
      );
    });

    testWidgets('TranslateErrorView asks for consent, then retries', (
      tester,
    ) async {
      final harness = harnessFor(readyState());
      var retried = 0;
      await harness.pump(
        tester,
        child: TranslateErrorView(error: _consent, onRetry: () => retried++),
      );
      expect(find.byKey(const Key('translate_error_consent')), findsOneWidget);
      await tester.tap(find.text('Once'));
      expect(retried, 1);
    });

    testWidgets('a consent prompt without retry does nothing more', (
      tester,
    ) async {
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(error: _consent),
      );
      await tester.tap(find.text('Once'));
      verify(() => harness.repository.allowOnce(_consent)).called(1);
    });

    testWidgets('compare entries refused for consent compare again', (
      tester,
    ) async {
      final harness = harnessFor(
        readyState(input: 'Hello world').copyWith(
          compareMode: true,
          compareEntries: [
            const CompareEntry.failure(
              engineId: 'mozhi:google',
              engineName: 'Google',
              error: _consent,
            ),
          ],
        ),
      );
      await harness.pump(tester, child: const ComparePanel());
      await tester.tap(find.text('Once'));
      verify(harness.translate.runCompare).called(1);
    });

    testWidgets('a refinement refused for consent offers a review', (
      tester,
    ) async {
      final harness = harnessFor(
        translatedState(engine: claude, assistEngine: claude),
      );
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        harness.translate,
        states.stream,
        initialState: translatedState(engine: claude, assistEngine: claude),
      );
      await harness.pump(tester, child: const ExtrasSection());
      states.add(
        translatedState(
          engine: claude,
          assistEngine: claude,
        ).copyWith(refinementError: () => _consent),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Your privacy settings ask'), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(
        find.text('Send this text to Google via mozhi.example.org?'),
        findsOneWidget,
      );
    });
  });

  group('readAloud', () {
    const online = ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: _destination,
      engineId: 'mozhi:google',
      source: 'fr',
      target: 'fr',
    );

    testWidgets('offers to listen through Mozhi with consent', (tester) async {
      final harness = harnessFor(translatedState());
      when(
        () => harness.speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenAnswer((invocation) async {
        if (invocation.namedArguments[#allowOnline] == null) {
          throw const SpeechUnavailableException('fr', cause: online);
        }
      });
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              readAloud(
                context,
                id: 'target',
                text: 'Bonjour',
                languageCode: 'fr',
              ),
            ),
            child: const Text('read'),
          ),
        ),
      );
      await tester.tap(find.text('read'));
      await tester.pumpAndSettle();
      expect(find.text('Listen online'), findsOneWidget);
      await tester.tap(find.text('Listen online'));
      await tester.pumpAndSettle();
      verify(
        () => harness.speech.toggle(
          id: 'target',
          text: 'Bonjour',
          languageCode: 'fr',
          allowOnline: online,
        ),
      ).called(1);
    });

    testWidgets('slow reading with consent refused again says why', (
      tester,
    ) async {
      final harness = harnessFor(translatedState());
      when(
        () => harness.speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenThrow(const SpeechUnavailableException('fr', cause: online));
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              readAloud(
                context,
                id: 'target',
                text: 'Bonjour',
                languageCode: 'fr',
                slow: true,
                allowOnline: online,
              ),
            ),
            child: const Text('read'),
          ),
        ),
      );
      await tester.tap(find.text('read'));
      await tester.pumpAndSettle();
      expect(find.text('Listen online'), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  test('the destination chip is exported with the prompt', () {
    expect(
      const DestinationChip(destination: _destination).destination,
      _destination,
    );
  });
}
