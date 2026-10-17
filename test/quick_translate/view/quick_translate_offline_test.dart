import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/consent_prompt.dart' show DestinationChip;
import 'package:mozhi/core/widgets/x_ui.dart' show XActionButton;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// A finished on-device translation (German -> French).
QuickTranslateState _offlineState({
  QuickTranslateStatus status = QuickTranslateStatus.success,
  TranslationResult? translation,
  String? identifiedSource = 'de',
  Language target = french,
  List<({String code, String name, int? bytes})> downloads = const [],
}) => QuickTranslateState(
  text: 'Hallo Welt',
  target: target,
  status: status,
  engines: [offlineEngine],
  engine: offlineEngine,
  targetLanguages: mozhiTargets,
  result: translation,
  offlineOnly: true,
  identifiedSource: identifiedSource,
  offlineDownloads: downloads,
);

final TranslationResult _onDevice = result(
  'Bonjour le monde',
  engineId: TranslationEngine.offlineId,
  engineName: 'Offline (on-device)',
  detectedSource: 'de',
).copyWith(destination: const OnDeviceDestination());

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  Finder byKey(String key) => find.byKey(Key(key));

  group('QuickTranslateView offline only', () {
    late MockQuickTranslateCubit cubit;

    setUp(() {
      cubit = MockQuickTranslateCubit();
      when(() => cubit.retry()).thenAnswer((_) async {});
      when(() => cubit.setTarget(any())).thenAnswer((_) async {});
    });

    void stub(QuickTranslateState state) => whenListen(
      cubit,
      const Stream<QuickTranslateState>.empty(),
      initialState: state,
    );

    testWidgets('shows the on-device destination instead of the engine '
        'picker', (tester) async {
      stub(_offlineState(translation: _onDevice));
      await tester.pumpQuick(quickView(cubit));

      expect(find.text('Translate offline'), findsOneWidget);
      expect(find.text('Quick translate'), findsNothing);
      expect(find.text('Detected: German'), findsOneWidget);
      expect(byKey('quick_translate_target_chip'), findsOneWidget);
      expect(byKey('quick_translate_engine_chip'), findsNothing);
      expect(byKey('quick_translate_on_device'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('quick_translate_on_device'),
          matching: find.text('On device'),
        ),
        findsOneWidget,
      );
      // Named once, next to the target.
      expect(find.byType(DestinationChip), findsOneWidget);
      expect(byKey('quick_translate_destination'), findsNothing);
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('shows the destination before anything is translated', (
      tester,
    ) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.translating,
          identifiedSource: null,
        ),
      );
      await tester.pumpQuick(quickView(cubit));
      expect(byKey('quick_translate_on_device'), findsOneWidget);
      expect(byKey('quick_translate_progress'), findsOneWidget);
    });

    testWidgets('explains where the text goes', (tester) async {
      stub(_offlineState(translation: _onDevice));
      await tester.pumpQuick(quickView(cubit));
      await tester.tap(byKey('quick_translate_on_device'));
      await tester.pumpAndSettle();
      expect(
        find.text('Translated on this device. Your text isn’t sent anywhere.'),
        findsOneWidget,
      );
    });

    testWidgets('a missing language offers its download', (tester) async {
      final calls = <String>[];
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineModelsMissing,
          target: japanese,
          downloads: const [
            (code: 'ja', name: 'Japanese', bytes: 25 * 1024 * 1024),
          ],
        ),
      );
      await tester.pumpQuick(
        quickView(
          cubit,
          onClose: () => calls.add('close'),
          onOpenOfflineModels: () => calls.add('offline'),
        ),
      );

      expect(find.text('Download needed'), findsOneWidget);
      expect(
        find.text(
          'To translate this on your device, download Japanese in Offline '
          'languages first. Your text wasn’t sent anywhere.',
        ),
        findsOneWidget,
      );
      expect(find.text('Detected: German'), findsOneWidget);
      expect(find.textContaining('Download Japanese ('), findsOneWidget);
      // Nothing to copy or replace.
      expect(
        tester.widget<XActionButton>(byKey('quick_translate_copy')).onPressed,
        isNull,
      );

      await tester.tap(byKey('quick_translate_offline_download'));
      expect(calls, ['close', 'offline']);
    });

    testWidgets('names every language to download', (tester) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineModelsMissing,
          downloads: const [
            (code: 'de', name: 'German', bytes: null),
            (code: 'fr', name: 'French', bytes: null),
          ],
        ),
      );
      await tester.pumpQuick(quickView(cubit, onOpenOfflineModels: () {}));
      expect(find.textContaining('download German, French in'), findsOne);
      expect(find.text('Download German, French'), findsOneWidget);
    });

    testWidgets('without a way to the offline languages, only explains', (
      tester,
    ) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineModelsMissing,
          downloads: const [(code: 'ja', name: 'Japanese', bytes: null)],
        ),
      );
      await tester.pumpQuick(quickView(cubit));
      expect(find.text('Download needed'), findsOneWidget);
      expect(byKey('quick_translate_offline_download'), findsNothing);
    });

    testWidgets('says when the pair is not available offline', (tester) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineUnsupported,
          identifiedSource: 'ko',
        ),
      );
      await tester.pumpQuick(quickView(cubit));
      expect(find.text('Not available offline'), findsOneWidget);
      expect(
        find.text(
          'Korean can’t be translated into French on this device. Your '
          'text wasn’t sent anywhere.',
        ),
        findsOneWidget,
      );
      expect(byKey('quick_translate_retry'), findsNothing);
      // The target can still be changed.
      expect(byKey('quick_translate_target_chip'), findsOneWidget);
    });

    testWidgets('says when the language could not be identified', (
      tester,
    ) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineUnsupported,
          identifiedSource: null,
        ),
      );
      await tester.pumpQuick(quickView(cubit));
      expect(
        find.text(
          'Couldn’t tell on this device which language this is. Your text '
          'wasn’t sent anywhere.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says when the device has no on-device engine', (tester) async {
      stub(
        const QuickTranslateState(
          text: 'Hallo Welt',
          target: french,
          status: QuickTranslateStatus.offlineUnavailable,
          offlineOnly: true,
        ),
      );
      await tester.pumpQuick(quickView(cubit, onOpenInApp: () {}));
      expect(find.text('Can’t translate on this device'), findsOneWidget);
      expect(
        find.text(
          'This device has no on-device translation engine, so nothing was '
          'translated. Your text wasn’t sent anywhere.',
        ),
        findsOneWidget,
      );
      expect(byKey('quick_translate_target_chip'), findsNothing);
      expect(byKey('quick_translate_on_device'), findsNothing);
      expect(byKey('quick_translate_open_in_app'), findsOneWidget);
    });

    testWidgets('Replace and Open in app keep working', (tester) async {
      String? replaced;
      var opened = 0;
      stub(_offlineState(translation: _onDevice));
      await tester.pumpQuick(
        quickView(
          cubit,
          canReplace: true,
          onReplace: (text) => replaced = text,
          onOpenInApp: () => opened++,
        ),
      );
      await tester.tap(byKey('quick_translate_replace'));
      expect(replaced, 'Bonjour le monde');
      await tester.tap(byKey('quick_translate_open_in_app'));
      expect(opened, 1);
    });

    testWidgets('renders in dark mode', (tester) async {
      stub(
        _offlineState(
          status: QuickTranslateStatus.offlineModelsMissing,
          downloads: const [(code: 'ja', name: 'Japanese', bytes: null)],
        ),
      );
      await tester.pumpQuick(
        quickView(cubit, onOpenOfflineModels: () {}),
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      expect(find.text('Download needed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('listen', () {
      late MockSpeechService speech;

      const online = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:google',
        source: 'fr',
        target: 'fr',
      );

      setUp(() {
        speech = MockSpeechService();
        when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
        when(() => speech.preferDeviceVoice).thenReturn(false);
      });

      Widget withPrivacy(Widget child, PrivacyMode mode) =>
          BlocProvider<SettingsCubit>.value(
            value: mockSettings(AppSettings(privacyMode: mode)),
            child: child,
          );

      testWidgets('is hidden when reading aloud could use a server', (
        tester,
      ) async {
        stub(_offlineState(translation: _onDevice));
        await tester.pumpQuick(
          withPrivacy(quickView(cubit, speech: speech), PrivacyMode.online),
        );
        expect(byKey('quick_translate_listen'), findsNothing);
        expect(byKey('quick_translate_copy'), findsOneWidget);
      });

      testWidgets('is offered with "device voice only"', (tester) async {
        when(() => speech.preferDeviceVoice).thenReturn(true);
        stub(_offlineState(translation: _onDevice));
        await tester.pumpQuick(quickView(cubit, speech: speech));
        expect(byKey('quick_translate_listen'), findsOneWidget);
      });

      testWidgets('is offered in the offline-only privacy mode', (
        tester,
      ) async {
        stub(_offlineState(translation: _onDevice));
        await tester.pumpQuick(
          withPrivacy(
            quickView(cubit, speech: speech),
            PrivacyMode.offlineOnly,
          ),
        );
        expect(byKey('quick_translate_listen'), findsOneWidget);
      });

      testWidgets('never offers to listen online', (tester) async {
        when(() => speech.preferDeviceVoice).thenReturn(true);
        when(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenThrow(const SpeechUnavailableException('fr', cause: online));
        stub(_offlineState(translation: _onDevice));
        await tester.pumpQuick(quickView(cubit, speech: speech));

        await tester.tap(byKey('quick_translate_listen'));
        await tester.pump(const Duration(seconds: 3));

        expect(byKey('quick_translate_notice'), findsOneWidget);
        expect(byKey('quick_translate_notice_action'), findsNothing);
        expect(find.text('Listen online'), findsNothing);
        await tester.pumpAndSettle(const Duration(seconds: 15));
      });
    });
  });

  group('showQuickTranslate offline only', () {
    late MockTranslationRepository repository;
    late MockSettingsCubit settings;
    late MockOfflineTranslator translator;

    setUp(() {
      repository = MockTranslationRepository();
      settings = mockSettings(
        const AppSettings(target: french, privacyMode: PrivacyMode.online),
      );
      translator = MockOfflineTranslator();
      when(() => repository.hasOfflineEngine).thenReturn(true);
      when(() => repository.getTargetLanguages(any()))
          .thenAnswer((_) async => mozhiTargets);
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(_onDevice));
      when(() => translator.isAvailable).thenReturn(true);
      when(() => translator.supportedLanguages)
          .thenReturn(const {'en', 'fr', 'de', 'ja'});
      when(translator.downloadedLanguages)
          .thenAnswer((_) async => const {'en', 'fr', 'de'});
      when(() => translator.identifyLanguage(any()))
          .thenAnswer((_) async => 'de');
    });

    Widget providers(Widget child, {bool withOffline = true}) =>
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<TranslationRepository>.value(value: repository),
            if (withOffline)
              RepositoryProvider<OfflineTranslator>.value(value: translator),
          ],
          child: BlocProvider<SettingsCubit>.value(
            value: settings,
            child: child,
          ),
        );

    Widget opener(void Function(BuildContext context) onPressed) => Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => onPressed(context),
          child: const Text('open'),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('translates on the device only', (tester) async {
      await tester.pumpQuick(
        providers(
          opener(
            (context) => showQuickTranslate(
              context,
              text: 'Hallo Welt',
              offlineOnly: true,
            ),
          ),
        ),
      );
      await open(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Translate offline'), findsOneWidget);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      verify(() => repository.translate(offlineEngine, any())).called(1);
      verifyNever(() => repository.getEngines(refresh: any(named: 'refresh')));
    });

    testWidgets('QuickTranslateSheet.show passes offlineOnly on', (
      tester,
    ) async {
      await tester.pumpQuick(
        providers(
          opener(
            (context) => QuickTranslateSheet.show(
              context,
              text: 'Hallo Welt',
              offlineOnly: true,
            ),
          ),
        ),
        size: const Size(1200, 800),
      );
      await open(tester);

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Translate offline'), findsOneWidget);
      verify(() => repository.translate(offlineEngine, any())).called(1);
    });

    testWidgets('without an on-device engine nothing is translated', (
      tester,
    ) async {
      await tester.pumpQuick(
        providers(
          opener(
            (context) => showQuickTranslate(
              context,
              text: 'Hallo Welt',
              offlineOnly: true,
            ),
          ),
          withOffline: false,
        ),
      );
      await open(tester);

      expect(find.text('Can’t translate on this device'), findsOneWidget);
      verifyNever(() => repository.translate(any(), any()));
      verifyNever(() => repository.getEngines(refresh: any(named: 'refresh')));
    });

    testWidgets('the download button closes the sheet and opens the offline '
        'languages', (tester) async {
      when(() => translator.identifyLanguage(any()))
          .thenAnswer((_) async => 'ja');
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: opener(
                (context) => showQuickTranslate(
                  context,
                  text: 'こんにちは',
                  offlineOnly: true,
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.offline,
            builder: (context, state) =>
                const Scaffold(body: Text('offline languages')),
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        providers(
          MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await open(tester);

      expect(find.text('Download needed'), findsOneWidget);
      verifyNever(() => repository.translate(any(), any()));

      await tester.tap(
        find.byKey(const Key('quick_translate_offline_download')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('offline languages'), findsOneWidget);
    });

    testWidgets('without a router there is no download button', (tester) async {
      when(() => translator.identifyLanguage(any()))
          .thenAnswer((_) async => 'ja');
      await tester.pumpQuick(
        providers(
          opener(
            (context) =>
                showQuickTranslate(context, text: 'こんにちは', offlineOnly: true),
          ),
        ),
      );
      await open(tester);

      expect(find.text('Download needed'), findsOneWidget);
      expect(
        find.byKey(const Key('quick_translate_offline_download')),
        findsNothing,
      );
    });
  });
}
