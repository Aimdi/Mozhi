import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  final l10n = lookupAppLocalizations(const Locale('en'));

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeConversationRecognizer recognizer;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    recognizer = FakeConversationRecognizer();
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
  });

  tearDown(() => speaking.close());

  Future<ConversationCubit> pump(
    WidgetTester tester, {
    required bool withRecognizer,
  }) async {
    final cubit = ConversationCubit(
      repository: MockTranslationRepository(),
      speech: speech,
      engine: () => deepl,
      languageA: english,
      languageB: spanish,
      recognizer: withRecognizer ? recognizer : null,
    );
    addTearDown(cubit.close);
    await tester.pumpConversation(
      const Scaffold(body: Center(child: ConversationSessionMic())),
      translate: translate,
      settings: settings,
      speech: speech,
      conversation: cubit,
    );
    return cubit;
  }

  IconButton button(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(ConversationSessionMic.buttonKey));

  testWidgets('without a recogniser it is off, not a mic that does nothing', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final cubit = await pump(tester, withRecognizer: false);

    expect(button(tester).onPressed, isNull);
    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(findTooltipMessage(l10n.voiceInputUnavailable), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel(l10n.voiceInputUnavailable)),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );
    expect(find.bySemanticsLabel(l10n.conversationSessionStart), findsNothing);

    await tester.tap(find.byKey(ConversationSessionMic.buttonKey));
    await tester.pump();
    expect(cubit.state.session, ConversationSession.idle);
    handle.dispose();
  });

  testWidgets('with a recogniser it starts the conversation', (tester) async {
    final cubit = await pump(tester, withRecognizer: true);

    expect(button(tester).onPressed, isNotNull);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(
      find.bySemanticsLabel(l10n.conversationSessionStart),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ConversationSessionMic.buttonKey));
    await tester.pump();
    expect(cubit.state.session, isA<ConversationSessionListening>());
    expect(recognizer.listens, hasLength(1));
  });
}
