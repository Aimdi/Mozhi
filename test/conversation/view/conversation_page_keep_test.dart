import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/data/leave_warning.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(const ConversationPreferences());
  });

  const german = Language(code: 'de', name: 'German');
  const french = Language(code: 'fr', name: 'French');

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late List<bool> warnings;
  late void Function({required bool enabled}) platformWarning;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(resultOf('Hola')));
    warnings = [];
    platformWarning = setLeaveWarning;
    setLeaveWarning = ({required enabled}) => warnings.add(enabled);
  });

  tearDown(() async {
    setLeaveWarning = platformWarning;
    await speaking.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpConversation(
      const ConversationPage(),
      translate: translate,
      settings: settings,
      repository: repository,
      speech: speech,
    );
    await tester.pumpAndSettle();
  }

  ConversationCubit cubitOf(WidgetTester tester) => BlocProvider.of(
    tester.element(find.byKey(const Key('conversation_standard_layout'))),
  );

  testWidgets('starts with the pair and options chosen last time', (
    tester,
  ) async {
    when(() => settings.state).thenReturn(
      const AppSettings(
        conversation: ConversationPreferences(
          languageA: german,
          languageB: french,
          detectSpeaker: false,
          turnPause: Duration(milliseconds: 1500),
        ),
      ),
    );
    await pumpPage(tester);

    final state = cubitOf(tester).state;
    expect(state.languageA, german);
    expect(state.languageB, french);
    expect(state.detectSpeaker, isFalse);
    expect(state.turnPause, const Duration(milliseconds: 1500));
  });

  testWidgets('keeps a new pair and new options', (tester) async {
    await pumpPage(tester);
    final cubit = cubitOf(tester)..setLanguage(ConversationSide.a, german);
    await tester.pump();
    cubit
      ..setDetectSpeaker(enabled: false)
      ..setTurnPause(const Duration(seconds: 1));
    await tester.pump();

    final kept = verify(() => settings.setConversationPreferences(captureAny()))
        .captured
        .cast<ConversationPreferences>();
    expect(kept.first.languageA, german);
    expect(
      kept.last,
      ConversationPreferences(
        languageA: german,
        languageB: cubit.state.languageB,
        detectSpeaker: false,
        turnPause: const Duration(seconds: 1),
      ),
    );
  });

  testWidgets('asks before a reload loses the turns', (tester) async {
    await pumpPage(tester);
    expect(warnings, isEmpty);

    await cubitOf(tester).submit(ConversationSide.a, 'Hello');
    await tester.pumpAndSettle();
    expect(warnings, [true]);

    await cubitOf(tester).clear();
    await tester.pumpAndSettle();
    expect(warnings, [true, false]);

    await cubitOf(tester).submit(ConversationSide.a, 'Hello');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(warnings, [true, false, true, false]);
  });
}
