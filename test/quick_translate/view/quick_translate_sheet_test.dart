import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  late MockTranslationRepository repository;
  late MockSettingsCubit settings;

  setUp(() {
    repository = MockTranslationRepository();
    settings = mockSettings(const AppSettings(target: french));
    when(() => repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => const [google, deepl]);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => mozhiTargets);
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(result('Bonjour le monde')));
  });

  /// App content with the dependencies above the [Navigator] (like the app
  /// does) and a button that runs [onPressed].
  Widget host(
    void Function(BuildContext context) onPressed, {
    SpeechService? speech,
    HistoryCubit? history,
  }) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TranslationRepository>.value(value: repository),
        if (speech != null)
          RepositoryProvider<SpeechService>.value(value: speech),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(value: settings),
          if (history != null) BlocProvider<HistoryCubit>.value(value: history),
        ],
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => onPressed(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showQuickTranslate', () {
    testWidgets('opens a bottom sheet on phones and translates right away', (
      tester,
    ) async {
      await tester.pumpQuick(
        host((context) => showQuickTranslate(context, text: 'Hello world')),
      );
      await open(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      verify(
        () => repository.translate(
          google,
          const TranslationRequest(
            text: 'Hello world',
            source: Language.auto,
            target: french,
          ),
        ),
      ).called(1);
      // No SpeechService / replace callback: no Listen or Replace.
      expect(find.byKey(const Key('quick_translate_listen')), findsNothing);
      expect(find.byKey(const Key('quick_translate_replace')), findsNothing);
    });

    testWidgets('opens a dialog on wide windows', (tester) async {
      await tester.pumpQuick(
        host((context) => showQuickTranslate(context, text: 'Hello world')),
        size: const Size(1200, 800),
      );
      await open(tester);

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('ignores blank text', (tester) async {
      var completed = false;
      await tester.pumpQuick(
        host((context) async {
          await showQuickTranslate(context, text: '  ');
          completed = true;
        }),
      );
      await open(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(completed, isTrue);
      verifyNever(() => repository.getEngines());
    });

    testWidgets('closes with the close button', (tester) async {
      var completed = false;
      await tester.pumpQuick(
        host((context) async {
          await QuickTranslateSheet.show(context, text: 'Hello world');
          completed = true;
        }),
      );
      await open(tester);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(completed, isTrue);
    });

    testWidgets('Replace closes and hands over the translation', (
      tester,
    ) async {
      String? replaced;
      await tester.pumpQuick(
        host(
          (context) => showQuickTranslate(
            context,
            text: 'Hello world',
            canReplace: true,
            onReplace: (text) => replaced = text,
          ),
        ),
      );
      await open(tester);

      await tester.tap(find.byKey(const Key('quick_translate_replace')));
      await tester.pumpAndSettle();
      expect(replaced, 'Bonjour le monde');
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('Open in app closes and calls back', (tester) async {
      var opened = 0;
      await tester.pumpQuick(
        host(
          (context) => showQuickTranslate(
            context,
            text: 'Hello world',
            onOpenInApp: () => opened++,
          ),
        ),
        size: const Size(1200, 800),
      );
      await open(tester);

      await tester.tap(find.text('Open in app'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('offers Listen with a speech service', (tester) async {
      final speech = MockSpeechService();
      final speaking = StreamController<String?>.broadcast();
      addTearDown(speaking.close);
      when(() => speech.speaking).thenAnswer((_) => speaking.stream);
      await tester.pumpQuick(
        host(
          (context) => showQuickTranslate(context, text: 'Hello world'),
          speech: speech,
        ),
      );
      await open(tester);
      expect(find.byKey(const Key('quick_translate_listen')), findsOneWidget);
    });

    testWidgets('saves the translation to history', (tester) async {
      final history = MockHistoryCubit();
      when(() => history.add(any())).thenAnswer((_) async {});
      await tester.pumpQuick(
        host(
          (context) => showQuickTranslate(context, text: 'Hello world'),
          history: history,
        ),
      );
      await open(tester);
      verify(() => history.add(any())).called(1);
    });

    testWidgets('closing cancels a running translation', (tester) async {
      final controller = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => controller.stream);
      await tester.pumpQuick(
        host((context) => showQuickTranslate(context, text: 'Hello world')),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.hasListener, isTrue);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.hasListener, isFalse);
      await controller.close();
    });
  });

  testWidgets('QuickTranslateSheet pops its route by default', (tester) async {
    final page = MaterialPageRoute<void>(
      builder: (_) => RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider<SettingsCubit>.value(
          value: settings,
          child: const Scaffold(body: QuickTranslateSheet(text: 'Hello world')),
        ),
      ),
    );
    await tester.pumpQuick(host((context) => Navigator.of(context).push(page)));
    await open(tester);
    expect(find.text('Bonjour le monde'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickTranslateSheet), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
