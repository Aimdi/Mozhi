import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

final _offline = TranslationEngine.offline();

const _instance = MozhiInstance(url: 'https://mozhi.example', isCustom: false);

/// The first run's defaults: Offline first, no engine chosen.
const _firstRun = AppSettings(instances: [_instance]);

/// What the repository stops when the device lacks French: "Detect
/// language" into English, for Google on the instance.
const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example', engine: 'google'),
  engineId: 'mozhi:google',
  source: 'auto',
  target: 'en',
);

/// The on-device engine selected by the app, "Detect language" into
/// English.
TranslateState _onDevice({
  List<TranslationEngine> engines = const [],
  ConsentRequest? consent,
}) => readyState(
  engine: _offline,
  target: english,
  input: 'Bonjour tout le monde',
).copyWith(engines: [...engines, _offline], consent: () => consent);

ConsentRequest _routed({bool automatic = true, String? source = 'fr'}) =>
    ConsentRequest(
      exception: _consent,
      id: 1,
      automatic: automatic,
      fromOnDevice: true,
      onDeviceSource: source,
    );

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbackValue(_consent);
  });

  TranslateHarness harnessFor(
    TranslateState state, {
    AppSettings settings = _firstRun,
  }) {
    final harness = TranslateHarness(state: state, settings: settings);
    when(() => harness.repository.instances).thenReturn(const [_instance]);
    return harness;
  }

  group('EngineSelectorButton', () {
    testWidgets('says the device tries first and who is asked about next', (
      tester,
    ) async {
      final harness = harnessFor(_onDevice());
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('On device + Google'), findsOneWidget);
      expect(find.text('Offline (on-device)'), findsNothing);
      expect(
        find.byTooltip(
          'Translates on this device when the language is downloaded. '
          'Otherwise asks before sending your text to Google.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('names the on-device engine the user chose', (tester) async {
      final harness = harnessFor(
        _onDevice(),
        settings: _firstRun.copyWith(engineId: () => _offline.id),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('Offline (on-device)'), findsOneWidget);
      expect(find.byTooltip('Choose translation engine'), findsOneWidget);
    });

    testWidgets('names it in Online mode', (tester) async {
      final harness = harnessFor(
        _onDevice(),
        settings: _firstRun.copyWith(privacyMode: PrivacyMode.online),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('Offline (on-device)'), findsOneWidget);
    });

    testWidgets('names the engine without the settings', (tester) async {
      final translate = MockTranslateCubit();
      when(() => translate.state).thenReturn(_onDevice());
      await tester.pumpWidget(
        BlocProvider<TranslateCubit>.value(
          value: translate,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: EngineSelectorButton()),
          ),
        ),
      );
      expect(find.text('Offline (on-device)'), findsOneWidget);
    });

    testWidgets('the sheet says when the online engine is asked about', (
      tester,
    ) async {
      final harness = harnessFor(_onDevice(engines: const [google]));
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1200),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Asks before sending to Google when a language isn’t downloaded',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the sheet has no such note for a chosen engine', (
      tester,
    ) async {
      final harness = harnessFor(
        _onDevice(engines: const [google]),
        settings: _firstRun.copyWith(engineId: () => _offline.id),
      );
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1200),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Asks before sending to'), findsNothing);
    });
  });

  group('OutputCard', () {
    testWidgets('offers the recognised language next to Once, with the '
        'first-use hint', (tester) async {
      final harness = harnessFor(_onDevice(consent: _routed()));
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      // Not "Translate on this device": English is there, French isn't.
      expect(find.text('Download French'), findsOneWidget);
      expect(find.byKey(const Key('translate_offline_use')), findsNothing);
      expect(
        find.text(
          'Download keeps your text on this phone. Once sends only this '
          'text to Google via mozhi.example.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Once'));
      await tester.pump();
      verify(() => harness.repository.allowOnce(_consent)).called(1);
      verify(harness.translate.retryAfterConsent).called(1);
    });

    testWidgets('offers the target when only it is missing', (tester) async {
      final harness = harnessFor(
        _onDevice(consent: _routed(source: null)).copyWith(target: german),
      );
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      // The stopped request's target.
      expect(find.text('Download English'), findsNothing);
      expect(find.byKey(const Key('translate_offline_use')), findsOneWidget);
    });

    testWidgets('a prompt the device did not try first has no hint', (
      tester,
    ) async {
      final harness = harnessFor(
        _onDevice(consent: const ConsentRequest(exception: _consent, id: 1)),
      );
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      expect(find.byKey(const Key('translate_first_use_hint')), findsNothing);
    });
  });

  group('OfflinePairOffer', () {
    testWidgets('downloads the language right here, then translates on '
        'the device', (tester) async {
      final harness = harnessFor(_onDevice(consent: _routed()));
      final translator = FakeOfflineTranslator();
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: translator,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('translate_offline_download')));
      await tester.pumpAndSettle();
      verifyNever(() => harness.router.push<void>(AppRoutes.offline));
      // The prompt to send the text online goes: no "Once" is left for a
      // text the device translates.
      verify(harness.translate.dismissConsent).called(1);
      // The on-device engine is selected: the same text again, on the
      // device (no consent needed, nothing sent).
      verify(harness.translate.translate).called(1);
      verifyNever(harness.translate.retryAfterConsent);
      verifyNever(() => harness.translate.selectEngine(any()));
    });

    testWidgets('after Manage languages, with the language there, it puts '
        'the prompt away and translates on the device', (tester) async {
      final harness = harnessFor(_onDevice(consent: _routed()));
      final translator = FakeOfflineTranslator();
      final pushed = Completer<void>();
      when(() => harness.router.push<void>(AppRoutes.offline))
          .thenAnswer((_) => pushed.future);
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: translator,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('translate_offline_manage')));
      await tester.pump();

      // Downloaded on the offline languages page, then back.
      translator.downloaded.add('fr');
      pushed.complete();
      await tester.pumpAndSettle();

      verify(harness.translate.dismissConsent).called(1);
      verify(harness.translate.translate).called(1);
      verifyNever(harness.translate.retryAfterConsent);
      verifyNever(() => harness.translate.selectEngine(any()));
      verifyNever(() => harness.repository.allowOnce(any()));

      // The double keeps its state: the device is offered.
      final use = find.byKey(const Key('translate_offline_use'));
      expect(use, findsOneWidget);
      await tester.tap(use);
      await tester.pump();
      verify(harness.translate.translate).called(1);
    });

    testWidgets('after Manage languages without the language the prompt '
        'stays', (tester) async {
      final harness = harnessFor(_onDevice(consent: _routed()));
      final pushed = Completer<void>();
      when(() => harness.router.push<void>(AppRoutes.offline))
          .thenAnswer((_) => pushed.future);
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('translate_offline_manage')));
      await tester.pump();
      pushed.complete();
      await tester.pumpAndSettle();

      verifyNever(harness.translate.dismissConsent);
      verifyNever(harness.translate.translate);
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
    });

    testWidgets('after Manage languages a prompt for an engine the user '
        'chose stays next to the device offer', (tester) async {
      const intoGerman = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example',
          engine: 'google',
        ),
        engineId: 'mozhi:google',
        source: 'auto',
        target: 'de',
      );
      final harness = harnessFor(
        readyState(target: german, input: 'Hello everyone').copyWith(
          engines: [google, _offline],
          consent: () => const ConsentRequest(exception: intoGerman, id: 1),
        ),
      );
      final translator = FakeOfflineTranslator();
      final pushed = Completer<void>();
      when(() => harness.router.push<void>(AppRoutes.offline))
          .thenAnswer((_) => pushed.future);
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: translator,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('translate_offline_manage')));
      await tester.pump();
      translator.downloaded.add('de');
      pushed.complete();
      await tester.pumpAndSettle();

      // Google is the user's engine: "Once" sends this text there.
      verifyNever(harness.translate.dismissConsent);
      verifyNever(harness.translate.translate);
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      expect(find.byKey(const Key('translate_offline_use')), findsOneWidget);
    });
  });

  group('TranslateConsentListener', () {
    testWidgets('the dialog offers the recognised language and puts the '
        'hint away', (tester) async {
      final harness = harnessFor(_onDevice());
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(harness.translate, states.stream, initialState: _onDevice());
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
        offline: FakeOfflineTranslator(),
      );
      states.add(_onDevice(consent: _routed(automatic: false)));
      await tester.pumpAndSettle();
      expect(
        find.text('Send this text to Google via mozhi.example?'),
        findsOneWidget,
      );
      expect(find.text('Download French for offline use'), findsOneWidget);
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      verify(() => harness.repository.allowOnce(_consent)).called(1);
      verify(harness.translate.retryAfterConsent).called(1);
    });

    testWidgets('Download opens the offline languages', (tester) async {
      final harness = harnessFor(_onDevice());
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(harness.translate, states.stream, initialState: _onDevice());
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
        offline: FakeOfflineTranslator(),
      );
      states.add(_onDevice(consent: _routed(automatic: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download French for offline use'));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>(AppRoutes.offline)).called(1);
      verifyNever(harness.translate.retryAfterConsent);
    });

    testWidgets('without a download Cancel keeps it waiting', (tester) async {
      final harness = harnessFor(_onDevice());
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(harness.translate, states.stream, initialState: _onDevice());
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
      );
      states.add(_onDevice(consent: _routed(automatic: false)));
      await tester.pumpAndSettle();
      expect(find.textContaining('for offline use'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(harness.translate.retryAfterConsent);
    });
  });

  group('onDeviceDownloadLanguage', () {
    test('names the first language that is not English', () {
      final translator = FakeOfflineTranslator();
      expect(
        onDeviceDownloadLanguage(translator, source: 'fr', target: 'en'),
        'French',
      );
      expect(
        onDeviceDownloadLanguage(translator, source: 'auto', target: 'de'),
        'German',
      );
      expect(
        onDeviceDownloadLanguage(translator, source: 'en', target: 'ja'),
        'Japanese',
      );
    });

    test('is null when there is nothing to name', () {
      final translator = FakeOfflineTranslator();
      expect(
        onDeviceDownloadLanguage(translator, source: null, target: 'en'),
        isNull,
      );
      expect(
        onDeviceDownloadLanguage(translator, source: 'ta', target: 'en'),
        isNull,
      );
      expect(
        onDeviceDownloadLanguage(translator, source: 'fr', target: null),
        isNull,
      );
      expect(
        onDeviceDownloadLanguage(null, source: 'fr', target: 'en'),
        isNull,
      );
      expect(
        onDeviceDownloadLanguage(
          FakeOfflineTranslator(isAvailable: false),
          source: 'fr',
          target: 'en',
        ),
        isNull,
      );
    });
  });

  group('TranslateFirstUseHint', () {
    Future<void> pumpHint(WidgetTester tester, KeyValueStore store) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TranslateFirstUseHint(consent: _consent, store: store),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows until the user answered once', (tester) async {
      final store = MemoryStore();
      await pumpHint(tester, store);
      expect(find.byKey(const Key('translate_first_use_hint')), findsOne);

      await TranslateFirstUseHint.markSeen(
        tester.element(find.byType(TranslateFirstUseHint)),
        store: store,
      );
      expect(store.values[TranslateFirstUseHint.storeKey], 'seen');

      await tester.pumpWidget(const SizedBox());
      await pumpHint(tester, store);
      expect(find.byKey(const Key('translate_first_use_hint')), findsNothing);
    });

    testWidgets('shows when the preference can not be read', (tester) async {
      await pumpHint(tester, _FailingStore());
      expect(find.byKey(const Key('translate_first_use_hint')), findsOne);
      // Remembering fails quietly.
      await TranslateFirstUseHint.markSeen(
        tester.element(find.byType(TranslateFirstUseHint)),
        store: _FailingStore(),
      );
    });

    testWidgets('remembers nothing without a store', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TranslateFirstUseHint(consent: _consent)),
        ),
      );
      expect(find.byKey(const Key('translate_first_use_hint')), findsOne);
      await TranslateFirstUseHint.markSeen(
        tester.element(find.byType(TranslateFirstUseHint)),
      );
    });
  });
}

class _FailingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('locked'));

  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('locked'));

  @override
  Future<void> delete(String key) async {}
}
