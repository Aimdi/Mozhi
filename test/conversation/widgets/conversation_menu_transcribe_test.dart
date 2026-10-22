import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/conversation_actions.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../helpers.dart';

class _MockRouter extends Mock implements GoRouter;

void main() {
  setUpAll(registerConversationFallbacks);

  late ConversationCubit cubit;

  setUp(() {
    final speech = MockSpeechService();
    stubSpeech(speech);
    cubit = ConversationCubit(
      repository: MockTranslationRepository(),
      speech: speech,
      engine: () => deepl,
      languageA: english,
      languageB: spanish,
    );
  });

  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester, {GoRouter? router}) async {
    Widget menu = const ConversationMenuButton();
    if (router != null) {
      menu = InheritedGoRouter(goRouter: router, child: menu);
    }
    await tester.pumpWidget(
      BlocProvider<ConversationCubit>.value(
        value: cubit,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(appBar: AppBar(actions: [menu])),
        ),
      ),
    );
  }

  testWidgets('opens Transcribe', (tester) async {
    final router = _MockRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
    await pump(tester, router: router);
    await tester.tap(find.byKey(const Key('conversation_menu')));
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.conversationTranscribe), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation_menu_transcribe')));
    await tester.pumpAndSettle();
    verify(() => router.push<void>(AppRoutes.transcribe)).called(1);
  });

  testWidgets('is not offered without a router', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('conversation_menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation_menu_transcribe')), findsNothing);
  });
}
