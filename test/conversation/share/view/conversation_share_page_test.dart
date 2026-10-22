import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:mozhi/conversation/share/view/conversation_share_page.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

class MockConversationShareCubit extends MockCubit<ConversationShareState>
    implements ConversationShareCubit;

class MockConversationCubit extends MockCubit<ConversationState>
    implements ConversationCubit;

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org'),
  engineId: 'mozhi:deepl',
  source: 'en',
  target: 'de',
);

final _live = ConversationShareState(
  status: ConversationShareStatus.live,
  url: Uri.parse('http://192.168.1.23:4242/s/abcdefghijklmnopqrstuv'),
  pin: '4821',
  guests: [
    ShareGuest(
      id: 'a',
      number: 1,
      language: french,
      joinedAt: sentAt,
      connected: true,
    ),
    ShareGuest(id: 'b', number: 2, language: german, joinedAt: sentAt),
  ],
  languages: const [
    ShareLanguageState(language: french, mode: ShareLanguageMode.engine),
    ShareLanguageState(
      language: Language(code: 'it', name: 'Italian'),
      mode: ShareLanguageMode.onDevice,
    ),
    ShareLanguageState(
      language: Language(code: 'ja', name: 'Japanese'),
      mode: ShareLanguageMode.unavailable,
    ),
    ShareLanguageState(
      language: german,
      mode: ShareLanguageMode.needsConsent,
      consent: _consent,
      waiting: 2,
    ),
  ],
  engineName: 'DeepL',
);

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(Object());
  });

  late MockConversationShareCubit share;
  late MockConversationCubit conversation;
  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;

  void stubShare(ConversationShareState state) {
    when(() => share.state).thenReturn(state);
    whenListen(
      share,
      const Stream<ConversationShareState>.empty(),
      initialState: state,
    );
  }

  setUp(() {
    share = MockConversationShareCubit();
    when(() => share.start(pin: any(named: 'pin'))).thenAnswer((_) async {});
    when(share.stop).thenAnswer((_) async {});
    when(() => share.isClosed).thenReturn(false);
    conversation = MockConversationCubit();
    translate = MockTranslateCubit();
    when(() => translate.state).thenReturn(translateState());
    settings = MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
    repository = MockTranslationRepository();
    when(() => repository.instances).thenReturn(const []);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ConversationShareState state, {
    Size size = const Size(400, 1600),
  }) async {
    stubShare(state);
    await tester.pumpConversation(
      ConversationSharePage(
        launch: ConversationShareLaunch(
          share: share,
          conversation: conversation,
        ),
      ),
      translate: translate,
      settings: settings,
      repository: repository,
      size: size,
    );
  }

  group('ConversationSharePage', () {
    testWidgets('starts sharing when opened', (tester) async {
      await pumpPage(
        tester,
        const ConversationShareState(status: ConversationShareStatus.starting),
      );

      verifyNever(() => share.start(pin: any(named: 'pin')));
      expect(find.text('Starting…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      verify(() => share.setVisible(any(), visible: true)).called(1);
    });

    testWidgets('starts an idle sharing', (tester) async {
      await pumpPage(tester, const ConversationShareState());

      verify(share.start).called(1);
      expect(
        find.text('Sharing stopped. Guests see that the conversation ended.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Share again'));
      verify(share.start).called(1);
    });

    testWidgets('explains a missing network', (tester) async {
      await pumpPage(
        tester,
        const ConversationShareState(status: ConversationShareStatus.noNetwork),
      );
      clearInteractions(share);

      expect(find.text('Not on a local network'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(share.start).called(1);
    });

    testWidgets('explains a failed start', (tester) async {
      await pumpPage(
        tester,
        const ConversationShareState(status: ConversationShareStatus.failed),
      );
      clearInteractions(share);

      expect(
        find.text("Couldn't start sharing on this network."),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      verify(share.start).called(1);
    });

    testWidgets('shows the code, link, PIN, guests and languages', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester, _live);

      verifyNever(() => share.start(pin: any(named: 'pin')));
      final code = tester.widget<QrCodeView>(find.byType(QrCodeView));
      expect(code.data, 'http://192.168.1.23:4242/s/abcdefghijklmnopqrstuv');
      expect(code.semanticLabel, 'QR code of the link below');
      expect(
        find.text('http://192.168.1.23:4242/s/abcdefghijklmnopqrstuv'),
        findsOneWidget,
      );
      expect(find.text('PIN 4821'), findsOneWidget);
      expect(find.bySemanticsLabel('PIN 4 8 2 1'), findsOneWidget);
      expect(find.text('2 guests'), findsOneWidget);
      expect(find.text('Guest 1 · French'), findsOneWidget);
      expect(find.text('Guest 2 · German'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Guest 2 · German, reconnecting'),
        findsOneWidget,
      );
      expect(find.text('French: translated by DeepL'), findsOneWidget);
      expect(find.text('Italian: translated on this device'), findsOneWidget);
      expect(
        find.text(
          'Japanese: no engine can translate it; these guests read the '
          'original',
        ),
        findsOneWidget,
      );
      final prompt = tester.widget<ConsentInlinePrompt>(
        find.byType(ConsentInlinePrompt),
      );
      expect(prompt.consent, _consent);
      expect(prompt.requests, 2);
      prompt.onGranted();
      verify(() => share.retryLanguage(german)).called(1);
      expect(find.textContaining('plain http'), findsOneWidget);
      expect(find.textContaining('from now on'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('changes the PIN and replies', (tester) async {
      await pumpPage(tester, _live);

      await tester.tap(find.byKey(const Key('conversation_share_pin_switch')));
      verify(() => share.setPinRequired(required: false)).called(1);
      await tester.ensureVisible(
        find.byKey(const Key('conversation_share_replies_switch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('conversation_share_replies_switch')),
      );
      verify(() => share.setRepliesAllowed(allowed: false)).called(1);
    });

    testWidgets('warns about too many wrong PINs', (tester) async {
      await pumpPage(
        tester,
        ConversationShareState(
          status: ConversationShareStatus.live,
          url: _live.url,
          locked: true,
        ),
      );

      expect(find.textContaining('Too many wrong PINs'), findsOneWidget);
      expect(find.text('No guests yet'), findsOneWidget);
      expect(find.byKey(const Key('conversation_share_pin')), findsNothing);
    });

    testWidgets('copies the link', (tester) async {
      final copied = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpPage(tester, _live);

      await tester.tap(find.byKey(const Key('conversation_share_copy')));
      await tester.pumpAndSettle();

      expect(copied, [_live.url.toString()]);
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('stops and goes back', (tester) async {
      stubShare(_live);
      await tester.pumpConversation(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationSharePage(
                  launch: ConversationShareLaunch(
                    share: share,
                    conversation: conversation,
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
        translate: translate,
        settings: settings,
        repository: repository,
        size: const Size(400, 1600),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('conversation_share_stop')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation_share_stop')));
      await tester.pumpAndSettle();

      verify(share.stop).called(1);
      expect(find.byType(ConversationShareView), findsNothing);
    });

    testWidgets('stops without a page to go back to', (tester) async {
      await pumpPage(tester, _live);

      await tester.ensureVisible(
        find.byKey(const Key('conversation_share_stop')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation_share_stop')));
      await tester.pumpAndSettle();

      verify(share.stop).called(1);
    });

    testWidgets('puts the code beside the details on wide screens', (
      tester,
    ) async {
      await pumpPage(tester, _live, size: const Size(1200, 900));

      final code = tester.getCenter(find.byType(QrCodeView));
      final stop = tester.getCenter(
        find.byKey(const Key('conversation_share_stop')),
      );
      expect(code.dx, lessThan(stop.dx));
      expect(tester.widget<QrCodeView>(find.byType(QrCodeView)).size, 320);
    });

    testWidgets('is empty without a launch', (tester) async {
      await tester.pumpConversation(
        ConversationSharePage.fromExtra(null),
        translate: translate,
        settings: settings,
      );

      expect(find.byType(ConversationShareView), findsNothing);
      expect(
        ConversationSharePage.fromExtra(
          ConversationShareLaunch(share: share, conversation: conversation),
        ),
        isA<ConversationSharePage>(),
      );
    });
  });

  group('openConversationShare', () {
    Widget opener() => MultiBlocProvider(
      providers: [
        BlocProvider<ConversationShareCubit>.value(value: share),
        BlocProvider<ConversationCubit>.value(value: conversation),
      ],
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => openConversationShare(context),
          child: const Text('open'),
        ),
      ),
    );

    testWidgets('pushes the page on the navigator', (tester) async {
      stubShare(_live);
      await tester.pumpConversation(
        opener(),
        translate: translate,
        settings: settings,
        repository: repository,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationShareView), findsOneWidget);
    });

    testWidgets('opens the share location with the router', (tester) async {
      stubShare(_live);
      Object? extra;
      final router = GoRouter(
        initialLocation: AppRoutes.conversation,
        routes: [
          GoRoute(
            path: AppRoutes.conversation,
            builder: (context, state) => opener(),
            routes: [
              GoRoute(
                path: 'share',
                builder: (context, state) {
                  extra = state.extra;
                  return const Text('share page');
                },
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpConversation(
        Router.withConfig(config: router),
        translate: translate,
        settings: settings,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('share page'), findsOneWidget);
      expect(extra, isA<ConversationShareLaunch>());
      expect((extra! as ConversationShareLaunch).share, share);
    });
  });
}
