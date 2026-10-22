import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;

  setUpAll(() {
    registerFallbackValue(openAiEngine);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
  });

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    TranslateState state = readyTranslateState,
    Stream<TranslateState>? stream,
  }) async {
    setSurface(tester, const Size(800, 2400));
    whenListen(
      translateCubit,
      stream ?? const Stream<TranslateState>.empty(),
      initialState: state,
    );
    await tester.pumpProofread(
      const ProofreadPage(),
      translateCubit: translateCubit,
      repository: repository,
    );
  }

  ProofreadState proofreadState(WidgetTester tester) =>
      tester.element(find.byType(ProofreadView)).read<ProofreadCubit>().state;

  group('ProofreadPage', () {
    testWidgets('provides a cubit with the AI engines', (tester) async {
      await pumpPage(
        tester,
        state: const TranslateState(
          enginesStatus: EnginesStatus.ready,
          engines: [googleEngine, openAiEngine, ollamaEngine],
          assistEngine: ollamaEngine,
        ),
      );
      expect(find.byType(ProofreadView), findsOneWidget);
      final state = proofreadState(tester);
      expect(state.availableEngines, [openAiEngine, ollamaEngine]);
      expect(state.engine, ollamaEngine);
      await tester.tap(find.byKey(const Key('proofread_options_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_engine_menu')), findsOneWidget);
    });

    testWidgets('shows the empty state without AI engines', (tester) async {
      await pumpPage(
        tester,
        state: const TranslateState(
          enginesStatus: EnginesStatus.ready,
          engines: [googleEngine],
        ),
      );
      expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
    });

    testWidgets('picks up engines that load later', (tester) async {
      await pumpPage(
        tester,
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
        stream: Stream.value(readyTranslateState),
      );
      await tester.pump();
      expect(proofreadState(tester).engine, openAiEngine);
      expect(find.byType(ProofreadInputCard), findsOneWidget);
    });

    testWidgets('proofreads and applies edits end to end', (tester) async {
      when(
        () => repository.proofread(
          any(),
          any(),
          style: any(named: 'style'),
          level: any(named: 'level'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
        ),
      ).thenAnswer((_) async => sampleResult);

      await pumpPage(tester);
      await tester.enterText(
        find.byKey(const Key('proofread_input')),
        sampleInput,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('proofread_options_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('proofread_style_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Business'));
      await tester.pumpAndSettle();
      // Close the sheet.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('proofread_button')));
      await tester.pumpAndSettle();

      final captured = verify(
        () => repository.proofread(
          openAiEngine,
          sampleInput,
          style: WritingStyle.business,
          level: captureAny(named: 'level'),
          formality: captureAny(named: 'formality'),
          context: captureAny(named: 'context'),
          uiLanguage: captureAny(named: 'uiLanguage'),
        ),
      ).captured;
      expect(captured, [
        CorrectionLevel.standard,
        Formality.automatic,
        '',
        'English',
      ]);
      expect(find.text('3 of 3 applied'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('proofread_edit_0')),
          matching: find.byKey(const Key('proofread_edit_reject')),
        ),
      );
      await tester.pump();
      expect(find.text('2 of 3 applied'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide changes'));
      await tester.pump();
      expect(find.text('I has an apple and an orange.'), findsOneWidget);

      await tester.tap(find.text('Use as input'));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('proofread_input')),
      );
      expect(field.controller!.text, 'I has an apple and an orange.');
      expect(find.text('Suggested edits'), findsNothing);
    });
  });

  group('proofreadUiLanguage', () {
    test('returns English for English locales', () {
      expect(proofreadUiLanguage(const Locale('en', 'GB')), 'English');
    });

    test('names other languages and falls back to English', () {
      expect(proofreadUiLanguage(const Locale('de')), 'German');
      expect(proofreadUiLanguage(const Locale('zz')), 'English');
    });
  });
}
