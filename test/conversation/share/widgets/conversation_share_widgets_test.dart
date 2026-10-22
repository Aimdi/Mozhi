import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/view/conversation_share_page.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_banner.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_guard.dart';
import 'package:mozhi/conversation/widgets/conversation_actions.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../helpers.dart';

class MockConversationShareCubit extends MockCubit<ConversationShareState>
    implements ConversationShareCubit;

final _live = ConversationShareState(
  status: ConversationShareStatus.live,
  url: Uri.parse('http://192.168.1.23:4242/s/abcdefghijklmnopqrstuv'),
  guests: [
    ShareGuest(id: 'a', number: 1, language: french, joinedAt: sentAt),
    ShareGuest(id: 'b', number: 2, language: german, joinedAt: sentAt),
  ],
);

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(Object());
  });

  late MockConversationShareCubit share;
  late MockTranslateCubit translate;
  late MockSettingsCubit settings;

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
    when(() => share.isClosed).thenReturn(false);
    when(share.stop).thenAnswer((_) async {});
    when(() => share.start(pin: any(named: 'pin'))).thenAnswer((_) async {});
    translate = MockTranslateCubit();
    when(() => translate.state).thenReturn(translateState());
    settings = MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
  });

  Future<void> pump(WidgetTester tester, Widget child, {bool provide = true}) =>
      tester.pumpConversation(
        provide
            ? BlocProvider<ConversationShareCubit>.value(
                value: share,
                child: child,
              )
            : child,
        translate: translate,
        settings: settings,
      );

  group('ConversationShareBanner', () {
    testWidgets('is hidden without sharing', (tester) async {
      await pump(
        tester,
        const Scaffold(body: ConversationShareBanner()),
        provide: false,
      );
      expect(find.byKey(const Key('conversation_share_banner')), findsNothing);

      stubShare(const ConversationShareState());
      await pump(tester, const Scaffold(body: ConversationShareBanner()));
      expect(find.byKey(const Key('conversation_share_banner')), findsNothing);
    });

    testWidgets('shows the guests, the code and Stop', (tester) async {
      stubShare(_live);
      await tester.pumpConversation(
        MultiBlocProvider(
          providers: [
            BlocProvider<ConversationShareCubit>.value(value: share),
            BlocProvider<ConversationCubit>(
              create: (_) => ConversationCubit(
                repository: MockTranslationRepository(),
                speech: _speech(),
                engine: () => deepl,
                languageA: english,
                languageB: spanish,
              ),
            ),
          ],
          child: const Scaffold(body: ConversationShareBanner()),
        ),
        translate: translate,
        settings: settings,
      );

      expect(find.text('Shared on this network · 2 guests'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop sharing'));
      verify(share.stop).called(1);

      await tester.tap(find.text('Show code'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationShareView), findsOneWidget);
    });
  });

  group('ConversationShareGuard', () {
    testWidgets('does nothing without sharing', (tester) async {
      await pump(
        tester,
        const ConversationShareGuard(child: Text('screen')),
        provide: false,
      );

      expect(find.text('screen'), findsOneWidget);
      expect(
        maybeConversationShare(tester.element(find.text('screen'))),
        isNull,
      );
    });

    testWidgets('reports whether the screen is shown', (tester) async {
      stubShare(_live);
      await pump(
        tester,
        const TickerMode(
          enabled: true,
          child: ConversationShareGuard(child: Text('screen')),
        ),
      );
      verify(() => share.setVisible(any(), visible: true)).called(1);

      await pump(
        tester,
        const TickerMode(
          enabled: false,
          child: ConversationShareGuard(child: Text('screen')),
        ),
      );
      verify(() => share.setVisible(any(), visible: false)).called(1);

      await pump(tester, const SizedBox.shrink());
      verify(() => share.setVisible(any(), visible: false)).called(1);
    });

    testWidgets('reports the app going to the background', (tester) async {
      stubShare(_live);
      await pump(tester, const ConversationShareGuard(child: Text('screen')));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      verify(share.appHidden).called(1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      verify(share.appShown).called(1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('lets go of a closed cubit', (tester) async {
      stubShare(_live);
      await pump(tester, const ConversationShareGuard(child: Text('screen')));
      clearInteractions(share);
      when(() => share.isClosed).thenReturn(true);

      await pump(tester, const SizedBox.shrink());

      verifyNever(
        () => share.setVisible(any(), visible: any(named: 'visible')),
      );
    });
  });

  group('Conversation menu', () {
    Future<void> pumpMenu(
      WidgetTester tester, {
      required bool shareable,
    }) async {
      stubShare(_live);
      final conversation = ConversationCubit(
        repository: MockTranslationRepository(),
        speech: _speech(),
        engine: () => deepl,
        languageA: english,
        languageB: spanish,
      );
      addTearDown(conversation.close);
      await tester.pumpConversation(
        BlocProvider<ConversationCubit>.value(
          value: conversation,
          child: Scaffold(
            appBar: AppBar(
              actions: [
                if (shareable)
                  BlocProvider<ConversationShareCubit>.value(
                    value: share,
                    child: const ConversationMenuButton(),
                  )
                else
                  const ConversationMenuButton(),
              ],
            ),
          ),
        ),
        translate: translate,
        settings: settings,
      );
      await tester.tap(find.byKey(const Key('conversation_menu')));
      await tester.pumpAndSettle();
    }

    testWidgets('offers sharing on the network', (tester) async {
      await pumpMenu(tester, shareable: true);

      await tester.tap(find.text('Share on this network'));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationShareView), findsOneWidget);
    });

    testWidgets('does not offer it where it cannot be hosted', (tester) async {
      await pumpMenu(tester, shareable: false);

      expect(find.text('Share on this network'), findsNothing);
    });
  });

  group('ConversationPage', () {
    testWidgets('keeps sharing in face-to-face mode', (tester) async {
      await tester.pumpConversation(
        const ConversationPage(networkShare: true),
        translate: translate,
        settings: settings,
        speech: _speech(),
      );
      final cubit = tester
          .element(find.byType(ConversationView))
          .read<ConversationShareCubit>();

      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();

      final faceToFace = tester.element(
        find.byType(ConversationFaceToFaceView),
      );
      expect(faceToFace.read<ConversationShareCubit>(), cubit);
    });

    testWidgets('can share on the network when asked to', (tester) async {
      final speech = _speech();
      for (final networkShare in [true, false]) {
        await tester.pumpConversation(
          ConversationPage(networkShare: networkShare),
          translate: translate,
          settings: settings,
          speech: speech,
        );
        await tester.tap(find.byKey(const Key('conversation_menu')));
        await tester.pumpAndSettle();

        expect(
          find.text('Share on this network'),
          networkShare ? findsOneWidget : findsNothing,
        );
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();
      }
    });
  });
}

MockSpeechService _speech() {
  final speech = MockSpeechService();
  stubSpeech(speech);
  return speech;
}
