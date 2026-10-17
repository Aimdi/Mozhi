import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _destination = PublicInstanceDestination(
  'mozhi.example.org',
  engine: 'google',
);

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: _destination,
  engineId: 'mozhi:google',
  source: 'auto',
  target: 'fr',
);

void main() {
  setUpAll(() {
    registerQuickTranslateFallbacks();
    registerFallbackValue(_consent);
  });

  late MockQuickTranslateCubit cubit;
  late MockTranslationRepository repository;
  late MockSettingsCubit settings;

  setUp(() {
    cubit = MockQuickTranslateCubit();
    repository = MockTranslationRepository();
    settings = mockSettings();
    when(() => cubit.retry()).thenAnswer((_) async {});
    when(() => repository.instances).thenReturn(const []);
  });

  void stub(QuickTranslateState state) => whenListen(
    cubit,
    const Stream<QuickTranslateState>.empty(),
    initialState: state,
  );

  Widget wrap(Widget child) => RepositoryProvider<TranslationRepository>.value(
    value: repository,
    child: BlocProvider<SettingsCubit>.value(value: settings, child: child),
  );

  testWidgets('text from another app waits for consent, inline', (
    tester,
  ) async {
    stub(readyState(status: QuickTranslateStatus.failure, error: _consent));
    await tester.pumpQuick(wrap(quickView(cubit)));
    expect(find.byKey(const Key('quick_translate_consent')), findsOneWidget);
    expect(find.textContaining('Google via mozhi.example.org'), findsWidgets);
    await tester.tap(find.text('Once'));
    verify(() => repository.allowOnce(_consent)).called(1);
    verify(() => cubit.retry()).called(1);
  });

  testWidgets('asks to choose an engine rather than picking one', (
    tester,
  ) async {
    stub(
      const QuickTranslateState(
        text: 'Hello',
        status: QuickTranslateStatus.chooseEngine,
        engines: [claude],
      ),
    );
    await tester.pumpQuick(wrap(quickView(cubit)));
    expect(find.text('Choose a translation engine'), findsOneWidget);
  });

  testWidgets('names where the translation was sent', (tester) async {
    stub(
      readyState(
        translation: result('Bonjour').copyWith(destination: _destination),
      ),
    );
    await tester.pumpQuick(wrap(quickView(cubit)));
    expect(
      find.byKey(const Key('quick_translate_destination')),
      findsOneWidget,
    );
    expect(find.text('Google via mozhi.example.org'), findsOneWidget);
  });

  group('listen', () {
    late MockSpeechService speech;

    const online = ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: _destination,
      engineId: 'mozhi:google',
      source: 'fr',
      target: 'fr',
    );

    setUp(() {
      speech = MockSpeechService();
      when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    });

    testWidgets('offers to listen through Mozhi in the notice', (tester) async {
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenAnswer((invocation) async {
        if (invocation.namedArguments[#allowOnline] == null) {
          throw const SpeechUnavailableException('fr', cause: online);
        }
      });
      stub(readyState(translation: result('Bonjour le monde')));
      await tester.pumpQuick(wrap(quickView(cubit, speech: speech)));
      await tester.tap(find.byKey(const Key('quick_translate_listen')));
      // Past the listen button's tooltip.
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.byKey(const Key('quick_translate_notice_action')),
        findsOneWidget,
      );
      expect(find.text('Listen online'), findsOneWidget);
      tester
          .widget<TextButton>(
            find.byKey(const Key('quick_translate_notice_action')),
          )
          .onPressed!();
      await tester.pump();
      verify(
        () => speech.toggle(
          id: QuickListenButton.defaultId,
          text: 'Bonjour le monde',
          languageCode: 'fr',
          allowOnline: online,
        ),
      ).called(1);
      await tester.pumpAndSettle(const Duration(seconds: 15));
      expect(find.byKey(const Key('quick_translate_notice')), findsNothing);
    });

    testWidgets('a refusal after consent only says why', (tester) async {
      when(
        () => speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenAnswer((invocation) async {
        throw const SpeechUnavailableException('fr', cause: online);
      });
      stub(readyState(translation: result('Bonjour le monde')));
      await tester.pumpQuick(wrap(quickView(cubit, speech: speech)));
      await tester.longPress(find.byKey(const Key('quick_translate_listen')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('quick_translate_notice_action')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('quick_translate_notice_action')),
        findsNothing,
      );
      expect(find.byKey(const Key('quick_translate_notice')), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 15));
    });
  });
}
