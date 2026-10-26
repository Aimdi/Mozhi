import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/conversation_actions.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  late AppLocalizations l10n;
  late FakeConversationRecognizer recognizer;

  setUp(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
    recognizer = FakeConversationRecognizer();
  });

  ConversationCubit cubitFor({required bool handsFree}) {
    final speech = MockSpeechService();
    stubSpeech(speech);
    return ConversationCubit(
      repository: MockTranslationRepository(),
      speech: speech,
      engine: () => deepl,
      languageA: english,
      languageB: spanish,
      recognizer: handsFree ? recognizer : null,
    );
  }

  Future<void> pump(WidgetTester tester, ConversationCubit cubit) async {
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BlocProvider<ConversationCubit>.value(
        value: cubit,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            appBar: AppBar(actions: const [ConversationMenuButton()]),
          ),
        ),
      ),
    );
  }

  Future<void> openOptions(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('conversation_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation_menu_voice_options')));
    await tester.pumpAndSettle();
  }

  testWidgets('are offered for a hands-free conversation only', (tester) async {
    await pump(tester, cubitFor(handsFree: false));
    await tester.tap(find.byKey(const Key('conversation_menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('conversation_menu_voice_options')),
      findsNothing,
    );
  });

  testWidgets('turn speaker detection off and on', (tester) async {
    final cubit = cubitFor(handsFree: true);
    await pump(tester, cubit);
    await openOptions(tester);
    expect(find.text(l10n.conversationVoiceOptions), findsOneWidget);
    expect(find.text(l10n.conversationDetectSpeakerHint), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation_detect_speaker')));
    await tester.pump();
    expect(cubit.state.detectSpeaker, isFalse);
    await tester.tap(find.byKey(const Key('conversation_detect_speaker')));
    await tester.pump();
    expect(cubit.state.detectSpeaker, isTrue);
  });

  testWidgets('set the pause that ends a turn, in tenths of a second', (
    tester,
  ) async {
    final cubit = cubitFor(handsFree: true);
    await pump(tester, cubit);
    await openOptions(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('conversation_turn_pause_value')))
          .data,
      l10n.conversationTurnPauseValue('0.8'),
    );
    final slider = tester.widget<Slider>(
      find.byKey(const Key('conversation_turn_pause')),
    );
    expect(slider.min, 0.5);
    expect(slider.max, 2);
    expect(slider.divisions, 15);
    slider.onChanged!(1.2);
    await tester.pumpAndSettle();
    expect(cubit.state.turnPause, const Duration(milliseconds: 1200));
    expect(find.text(l10n.conversationTurnPauseValue('1.2')), findsWidgets);
    // Screen readers hear the value in seconds.
    expect(slider.semanticFormatterCallback!(1.5), '1.5 s');
  });
}
