import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/app_lock.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../app_lock/helpers/fake_app_lock_platform.dart';
import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeAppLockPlatform platform;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    platform = FakeAppLockPlatform(unlocked: true);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(resultOf('Secreto traducido')));
  });

  tearDown(() => speaking.close());

  Future<void> goTo(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  testWidgets('locking keeps the conversation and the drafts, hidden', (
    tester,
  ) async {
    final lock = AppLockController(
      platform: platform,
      timeout: AppLockTimeout.immediately,
    );
    addTearDown(lock.dispose);
    await tester.pumpConversation(
      AppLockGate(lock: lock, child: const ConversationPage()),
      translate: translate,
      settings: settings,
      repository: repository,
      speech: speech,
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('conversation_input_a')),
      'Secret said',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('conversation_send_a')));
    await tester.pumpAndSettle();
    expect(find.text('Secreto traducido'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('conversation_input_b')),
      'Unsent draft',
    );
    await tester.pump();
    final cubit = tester
        .element(find.byType(ConversationView, skipOffstage: false))
        .read<ConversationCubit>();
    expect(cubit.state.turns, hasLength(1));

    platform.leave(Duration.zero);
    await goTo(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump(Duration.zero);
    // Back on the screen (frames again), before the prompt opens.
    await goTo(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ]);

    expect(find.byType(AppLockScreen), findsOneWidget);
    expect(cubit.state.turns, hasLength(1));
    expect(find.text('Secreto traducido'), findsNothing);
    expect(find.text('Secreto traducido', skipOffstage: false), findsOneWidget);
    expect(find.text('Unsent draft'), findsNothing);
    expect(find.text('Unsent draft', skipOffstage: false), findsOneWidget);

    platform.comeBack();
    await goTo(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(AppLockScreen), findsNothing);
    expect(find.text('Unsent draft'), findsOneWidget);
    expect(find.text('Secreto traducido'), findsOneWidget);
    expect(cubit.state.turns, hasLength(1));
  });
}
