import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
  });

  tearDown(() => speaking.close());

  /// The app's tabs (Translate, Conversation) with face-to-face mode at its
  /// own location, like `createRouter`.
  Future<GoRouter> pumpRouter(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rootKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: rootKey,
      initialLocation: AppRoutes.translate,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => Scaffold(body: shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: AppRoutes.translate,
                  builder: (context, state) =>
                      const Scaffold(body: Text('translate tab')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: AppRoutes.conversation,
                  builder: (context, state) => const ConversationPage(),
                  routes: [
                    GoRoute(
                      path: 'face-to-face',
                      parentNavigatorKey: rootKey,
                      redirect: (context, state) =>
                          state.extra == null ? AppRoutes.conversation : null,
                      builder: (context, state) =>
                          ConversationFaceToFacePage.fromExtra(state.extra),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TranslationRepository>.value(value: repository),
          RepositoryProvider<SpeechService>.value(value: speech),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      ),
    );
    router.go(AppRoutes.conversation);
    await tester.pumpAndSettle();
    return router;
  }

  String location(GoRouter router) => router.state.uri.path;

  ConversationCubit cubitOf(WidgetTester tester) => BlocProvider.of(
    tester.element(find.byKey(const Key('conversation_standard_layout'))),
  );

  Future<void> openFaceToFace(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
    await tester.pumpAndSettle();
  }

  group('face-to-face mode', () {
    testWidgets('has a location of its own', (tester) async {
      final router = await pumpRouter(tester);
      await openFaceToFace(tester);

      expect(find.byType(ConversationFaceToFaceView), findsOneWidget);
      expect(location(router), AppRoutes.conversationFaceToFace);
    });

    testWidgets('back closes it and stays on the conversation', (tester) async {
      final router = await pumpRouter(tester);
      final cubit = cubitOf(tester);
      await openFaceToFace(tester);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(ConversationFaceToFaceView), findsNothing);
      expect(location(router), AppRoutes.conversation);
      expect(find.text('translate tab'), findsNothing);
      expect(cubit.state.faceToFace, isFalse);
    });

    testWidgets('going back to the conversation (the browser) closes it', (
      tester,
    ) async {
      final router = await pumpRouter(tester);
      final cubit = cubitOf(tester);
      await openFaceToFace(tester);

      router.go(AppRoutes.conversation);
      await tester.pumpAndSettle();

      expect(find.byType(ConversationFaceToFaceView), findsNothing);
      expect(cubit.state.faceToFace, isFalse);
      // It opens again.
      await openFaceToFace(tester);
      expect(find.byType(ConversationFaceToFaceView), findsOneWidget);
    });

    testWidgets('its own toggle closes it', (tester) async {
      final router = await pumpRouter(tester);
      await openFaceToFace(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(ConversationFaceToFaceView),
          matching: find.byKey(const Key('conversation_layout_toggle')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ConversationFaceToFaceView), findsNothing);
      expect(location(router), AppRoutes.conversation);
    });

    testWidgets('a link without the conversation goes to it', (tester) async {
      final router = await pumpRouter(tester);
      router.go(AppRoutes.conversationFaceToFace);
      await tester.pumpAndSettle();

      expect(location(router), AppRoutes.conversation);
      expect(find.byType(ConversationFaceToFaceView), findsNothing);
    });
  });

  group('snack bars', () {
    Rect snackBarRect(WidgetTester tester) => tester.getRect(
      // The snack bar itself, inside its margin.
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );

    Future<void> showSnackBar(WidgetTester tester) async {
      ScaffoldMessenger.of(
        tester.element(find.byType(ConversationLanguagePill)),
      ).showSnackBar(const SnackBar(content: Text('Copied')));
      await tester.pumpAndSettle();
    }

    testWidgets('never cover the hands-free microphone', (tester) async {
      await tester.pumpConversation(
        ConversationPage(
          micBuilder: (context, request) =>
              const SizedBox.square(dimension: 48),
          recognizer: (_) => FakeConversationRecognizer(),
        ),
        translate: translate,
        settings: settings,
        repository: repository,
        speech: speech,
      );
      await tester.pumpAndSettle();
      await showSnackBar(tester);

      final mic = tester.getRect(find.byKey(ConversationSessionMic.buttonKey));
      final status = tester.getRect(
        find.byKey(const Key('conversation_session_status')),
      );
      expect(snackBarRect(tester).bottom, lessThanOrEqualTo(status.top));
      expect(snackBarRect(tester).bottom, lessThan(mic.top));
    });

    testWidgets('without a dock they stay at the bottom', (tester) async {
      await tester.pumpConversation(
        const ConversationPage(),
        translate: translate,
        settings: settings,
        repository: repository,
        speech: speech,
      );
      await showSnackBar(tester);

      final pill = tester.getRect(find.byType(ConversationLanguagePill));
      expect(snackBarRect(tester).bottom, greaterThan(pill.top));
    });
  });
}
