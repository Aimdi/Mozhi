import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  late MockProofreadCubit cubit;
  late MockTranslateCubit translateCubit;
  late MockGoRouter router;

  setUpAll(() {
    registerFallbackValue(openAiEngine);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
    registerFallbackValue(ReadingLevel.standard);
    registerFallbackValue(ProofreadVariety.enGb);
  });

  setUp(() {
    cubit = MockProofreadCubit();
    translateCubit = MockTranslateCubit();
    router = MockGoRouter();
    stubProofreadCubit(cubit);
  });

  Future<void> pumpView(
    WidgetTester tester,
    ProofreadState state, {
    Stream<ProofreadState>? stream,
    TranslateState translateState = readyTranslateState,
    Stream<TranslateState>? translateStream,
    Size size = const Size(800, 2400),
    ThemeData? theme,
    TranslationRepository? repository,
    SettingsCubit? settings,
  }) async {
    setSurface(tester, size);
    whenListen(
      cubit,
      stream ?? const Stream<ProofreadState>.empty(),
      initialState: state,
    );
    whenListen(
      translateCubit,
      translateStream ?? const Stream<TranslateState>.empty(),
      initialState: translateState,
    );
    await tester.pumpProofread(
      const ProofreadView(),
      translateCubit: translateCubit,
      proofreadCubit: cubit,
      router: router,
      theme: theme,
      repository: repository,
      settings: settings,
    );
  }

  /// Pumps the view and expands its collapsed "Options" card.
  Future<void> pumpControls(
    WidgetTester tester,
    ProofreadState state, {
    Stream<ProofreadState>? stream,
    TranslateState translateState = readyTranslateState,
    Size size = const Size(800, 2400),
  }) async {
    await pumpView(
      tester,
      state,
      stream: stream,
      translateState: translateState,
      size: size,
    );
    if (find.byKey(const Key('proofread_style_menu')).evaluate().isEmpty) {
      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
    }
  }

  /// Expects the menu button [key] to show [value].
  void expectMenuValue(WidgetTester tester, String key, String value) {
    expect(
      find.descendant(of: find.byKey(Key(key)), matching: find.text(value)),
      findsOneWidget,
      reason: key,
    );
  }

  group('ProofreadView', () {
    group('empty state', () {
      testWidgets('explains that an AI provider is needed', (tester) async {
        await pumpView(tester, const ProofreadState());
        expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
        expect(find.byType(ProofreadInputCard), findsNothing);

        when(() => router.push<void>(any())).thenAnswer((_) async {});
        await tester.tap(find.text('Add AI provider'));
        // Above the tabs: back returns to proofreading.
        verify(() => router.push<void>('/settings/providers')).called(1);
      });

      testWidgets('offers a retry when the engines failed to load', (
        tester,
      ) async {
        when(() => translateCubit.loadEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async {});
        await pumpView(
          tester,
          const ProofreadState(),
          translateState: const TranslateState(
            enginesStatus: EnginesStatus.failure,
          ),
        );
        expect(find.byType(ProofreadEmptyState), findsNothing);
        expect(find.text("Couldn't load your AI providers"), findsOneWidget);
        await tester.tap(find.text('Retry'));
        verify(() => translateCubit.loadEngines(refresh: true)).called(1);
      });

      testWidgets('shows a spinner while engines load', (tester) async {
        await pumpView(
          tester,
          const ProofreadState(),
          translateState: const TranslateState(
            enginesStatus: EnginesStatus.loading,
          ),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(ProofreadEmptyState), findsNothing);
      });
    });

    testWidgets('syncs engines from the translate cubit', (tester) async {
      const updated = TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: [googleEngine, openAiEngine, ollamaEngine],
        assistEngine: ollamaEngine,
      );
      await pumpView(
        tester,
        readyState,
        translateStream: Stream.value(updated),
      );
      await tester.pump();
      verify(() => cubit.setEngines(updated.engines, preferred: ollamaEngine))
          .called(1);
    });

    testWidgets('follows a new assist engine from the translate cubit', (
      tester,
    ) async {
      // Same engine list, only the assist engine changed (e.g. the user
      // switched the Translate tab to a local model).
      final updated = readyTranslateState.copyWith(
        assistEngine: () => ollamaEngine,
      );
      await pumpView(
        tester,
        readyState,
        translateStream: Stream.value(updated),
      );
      await tester.pump();
      verify(
        () => cubit.setEngines(
          readyTranslateState.engines,
          preferred: ollamaEngine,
        ),
      ).called(1);
    });

    group('hero', () {
      testWidgets('greets above the input until the first check', (
        tester,
      ) async {
        await pumpView(tester, readyState);
        expect(find.byKey(const Key('proofread_hero')), findsOneWidget);
        expect(find.text('Does this look right?'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('proofread_hero')),
            matching: find.byIcon(Icons.spellcheck_rounded),
          ),
          findsOneWidget,
        );
        expect(
          tester.getCenter(find.text('Does this look right?')).dy,
          lessThan(tester.getCenter(find.byType(ProofreadInputCard)).dy),
        );
      });

      testWidgets('is gone once proofreading started', (tester) async {
        await pumpView(
          tester,
          readyState.copyWith(
            input: 'I has a cat.',
            status: ProofreadStatus.loading,
          ),
        );
        expect(find.byKey(const Key('proofread_hero')), findsNothing);
        expect(find.byType(ProofreadInputCard), findsOneWidget);
      });

      testWidgets('sits above the input on wide screens too', (tester) async {
        await pumpView(tester, readyState, size: const Size(1200, 900));
        expect(find.byKey(const Key('proofread_hero')), findsOneWidget);
      });
    });

    testWidgets('has History and Settings in the app bar', (tester) async {
      await pumpView(tester, readyState);
      expect(find.byType(TopLevelActions), findsOneWidget);
    });

    group('input', () {
      testWidgets('shows the input and forwards typing', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'Hello'));
        expect(find.text('Hello'), findsOneWidget);
        expect(find.text('5 characters'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('proofread_input')),
          'Hello wrold',
        );
        verify(() => cubit.setInput('Hello wrold')).called(1);
      });

      testWidgets('keeps the field label once text is entered', (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpView(tester, readyState.copyWith(input: 'I has a cat.'));
        final field = tester.getSemantics(
          find.byKey(const Key('proofread_input')),
        );
        expect(
          field,
          isSemantics(
            label: 'Text to proofread',
            value: 'I has a cat.',
            isTextField: true,
            isMultiline: true,
          ),
        );
        // The character count is announced separately, not as the name.
        expect(field.label, isNot(contains('character')));
        expect(
          tester.getSemantics(find.text('12 characters')),
          isSemantics(label: '12 characters'),
        );
        semantics.dispose();
      });

      testWidgets('follows external input changes', (tester) async {
        final controller = StreamController<ProofreadState>();
        addTearDown(controller.close);
        await pumpView(tester, readyState, stream: controller.stream);
        controller.add(readyState.copyWith(input: 'From outside'));
        await tester.pump();
        final field = tester.widget<TextField>(
          find.byKey(const Key('proofread_input')),
        );
        expect(field.controller!.text, 'From outside');
        expect(find.text('1 character'), findsNothing);
      });

      testWidgets('pastes from the clipboard', (tester) async {
        FakeClipboard()
          ..clipboardText = 'pasted'
          ..install(tester);
        await pumpView(tester, readyState);
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verify(() => cubit.setInput('pasted')).called(1);
      });

      TextEditingController inputController(WidgetTester tester) => tester
          .widget<TextField>(find.byKey(const Key('proofread_input')))
          .controller!;

      testWidgets('pastes at the cursor without losing typed text', (
        tester,
      ) async {
        FakeClipboard()
          ..clipboardText = ' there'
          ..install(tester);
        await pumpView(tester, readyState.copyWith(input: 'Hello world'));
        inputController(tester).selection = const TextSelection.collapsed(
          offset: 5,
        );
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verify(() => cubit.setInput('Hello there world')).called(1);
        expect(inputController(tester).text, 'Hello there world');
        expect(
          inputController(tester).selection,
          const TextSelection.collapsed(offset: 11),
        );
      });

      testWidgets('pasting replaces the selected text', (tester) async {
        FakeClipboard()
          ..clipboardText = 'there'
          ..install(tester);
        await pumpView(tester, readyState.copyWith(input: 'Hello world'));
        inputController(tester).selection = const TextSelection(
          baseOffset: 6,
          extentOffset: 11,
        );
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verify(() => cubit.setInput('Hello there')).called(1);
      });

      testWidgets('pastes at the end when the field has no cursor', (
        tester,
      ) async {
        FakeClipboard()
          ..clipboardText = ' Bye.'
          ..install(tester);
        await pumpView(tester, readyState.copyWith(input: 'Hi.'));
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verify(() => cubit.setInput('Hi. Bye.')).called(1);
      });

      testWidgets('ignores an empty clipboard', (tester) async {
        FakeClipboard().install(tester);
        await pumpView(tester, readyState);
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verifyNever(() => cubit.setInput(any()));
      });

      testWidgets('clears the input', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'x'));
        expect(find.text('1 character'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear'));
        verify(() => cubit.clear()).called(1);
      });

      testWidgets('hides the clear button for empty input', (tester) async {
        await pumpView(tester, readyState);
        expect(find.byTooltip('Clear'), findsNothing);
      });

      testWidgets('Ctrl+Enter proofreads', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'text'));
        await tester.tap(find.byKey(const Key('proofread_input')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('Ctrl+Enter does nothing when not ready', (tester) async {
        await pumpView(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_input')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verifyNever(() => cubit.proofread());
      });
    });

    group('proofread button', () {
      FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(
        find.byKey(const Key('proofread_button')),
      );

      testWidgets('is disabled without input', (tester) async {
        await pumpView(tester, readyState);
        expect(button(tester).onPressed, isNull);
      });

      testWidgets('proofreads on tap', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'text'));
        await tester.tap(find.byKey(const Key('proofread_button')));
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('shows progress while loading', (tester) async {
        await pumpView(
          tester,
          readyState.copyWith(input: 'text', status: ProofreadStatus.loading),
        );
        expect(find.text('Checking…'), findsOneWidget);
        expect(find.text('Checking your text…'), findsOneWidget);
        expect(button(tester).onPressed, isNull);
      });
    });

    group('controls', () {
      testWidgets('start collapsed with a summary on narrow screens', (
        tester,
      ) async {
        await pumpView(
          tester,
          readyState.copyWith(
            correctionLevel: CorrectionLevel.light,
            writingStyle: WritingStyle.academic,
            formality: Formality.more,
            readingLevel: ReadingLevel.b2,
            variety: () => ProofreadVariety.enGb,
          ),
        );
        expect(find.byKey(const Key('proofread_style_menu')), findsNothing);
        expect(
          find.text('Light · Academic · More formal · B2 · English (UK)'),
          findsOneWidget,
        );
        await tester.tap(find.text('Options'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('proofread_style_menu')), findsOneWidget);
      });

      testWidgets('summary names a set context', (tester) async {
        await pumpView(tester, readyState.copyWith(context: 'thesis'));
        expect(find.text('Standard · General · Context'), findsOneWidget);
        // A set context keeps the options open.
        expect(find.byKey(const Key('proofread_context')), findsOneWidget);
      });

      testWidgets('start expanded on wide screens', (tester) async {
        await pumpView(tester, readyState, size: const Size(1200, 1600));
        expect(find.byKey(const Key('proofread_style_menu')), findsOneWidget);
      });

      testWidgets('lay the menus out in two equal columns', (tester) async {
        await pumpControls(tester, readyState);
        final style = tester.getRect(
          find.byKey(const Key('proofread_style_menu')),
        );
        final formality = tester.getRect(
          find.byKey(const Key('proofread_formality_menu')),
        );
        expect(style.top, formality.top);
        expect(style.width, closeTo(formality.width, 0.5));
        expect(style.height, formality.height);
      });

      testWidgets('changes the writing style', (tester) async {
        await pumpControls(tester, readyState);
        expectMenuValue(tester, 'proofread_style_menu', 'General');
        await tester.tap(find.byKey(const Key('proofread_style_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Academic'));
        await tester.pumpAndSettle();
        verify(() => cubit.setStyle(WritingStyle.academic)).called(1);
      });

      testWidgets('changes the formality', (tester) async {
        await pumpControls(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_formality_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Less formal'));
        await tester.pumpAndSettle();
        verify(() => cubit.setFormality(Formality.less)).called(1);
      });

      testWidgets('changes the reading level', (tester) async {
        await pumpControls(tester, readyState);
        expectMenuValue(tester, 'proofread_reading_level_menu', 'As written');
        await tester.tap(find.byKey(const Key('proofread_reading_level_menu')));
        await tester.pumpAndSettle();
        // Each option shows its CEFR description.
        expect(find.text("Keep the author's reading level"), findsOneWidget);
        expect(find.text('Upper intermediate'), findsOneWidget);
        await tester.tap(find.text('B1'));
        await tester.pumpAndSettle();
        verify(() => cubit.setReadingLevel(ReadingLevel.b1)).called(1);
      });

      testWidgets('changes the regional variety', (tester) async {
        await pumpControls(tester, readyState);
        expectMenuValue(tester, 'proofread_variety_menu', 'As written');
        await tester.tap(find.byKey(const Key('proofread_variety_menu')));
        await tester.pumpAndSettle();
        expect(
          find.text("Keep the author's spelling and vocabulary"),
          findsOneWidget,
        );
        for (final label in [
          'English (US)',
          'English (Australia)',
          'English (Canada)',
          'Portuguese (Brazil)',
          'Portuguese (Portugal)',
          'Spanish (Spain)',
          'Spanish (Latin America)',
          'French (France)',
          'French (Canada)',
          'German (Germany)',
          'German (Switzerland)',
          'German (Austria)',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        await tester.tap(find.text('English (UK)'));
        await tester.pumpAndSettle();
        verify(() => cubit.setVariety(ProofreadVariety.enGb)).called(1);
      });

      testWidgets("goes back to the author's variety", (tester) async {
        await pumpControls(
          tester,
          readyState.copyWith(variety: () => ProofreadVariety.deCh),
        );
        expectMenuValue(
          tester,
          'proofread_variety_menu',
          'German (Switzerland)',
        );
        await tester.tap(find.byKey(const Key('proofread_variety_menu')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('As written'),
          ),
        );
        await tester.pumpAndSettle();
        verify(() => cubit.setVariety(null)).called(1);
      });

      testWidgets('shows the chosen reading level', (tester) async {
        await pumpControls(
          tester,
          readyState.copyWith(readingLevel: ReadingLevel.c1),
        );
        expectMenuValue(tester, 'proofread_reading_level_menu', 'C1');
      });

      testWidgets('updates when the new options change', (tester) async {
        await pumpControls(
          tester,
          readyState,
          stream: Stream.value(
            readyState.copyWith(
              readingLevel: ReadingLevel.a2,
              variety: () => ProofreadVariety.ptBr,
            ),
          ),
        );
        await tester.pump();
        expectMenuValue(tester, 'proofread_reading_level_menu', 'A2');
        expectMenuValue(
          tester,
          'proofread_variety_menu',
          'Portuguese (Brazil)',
        );
      });

      testWidgets('fit a phone at 200% text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpControls(
          tester,
          readyState.copyWith(availableEngines: [openAiEngine, ollamaEngine]),
          size: const Size(320, 3200),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('proofread_reading_level_menu')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('proofread_variety_menu')), findsOneWidget);
        for (final key in [
          'proofread_style_menu',
          'proofread_formality_menu',
          'proofread_reading_level_menu',
          'proofread_variety_menu',
        ]) {
          expect(
            tester.getSize(find.byKey(Key(key))).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
        }
      });

      testWidgets('menu buttons show their whole value at 200% text', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpControls(
          tester,
          readyState.copyWith(
            readingLevel: ReadingLevel.a2,
            variety: () => ProofreadVariety.es419,
          ),
          size: const Size(320, 3200),
        );
        expect(tester.takeException(), isNull);
        RenderParagraph label(String key) => tester.renderObject(
          find
              .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
              .last,
        );
        for (final key in [
          'proofread_level_menu',
          'proofread_style_menu',
          'proofread_formality_menu',
          'proofread_reading_level_menu',
          'proofread_variety_menu',
        ]) {
          expect(label(key).didExceedMaxLines, isFalse, reason: key);
        }
        expectMenuValue(
          tester,
          'proofread_variety_menu',
          'Spanish (Latin America)',
        );
        // The long value wraps onto more lines instead.
        final variety = label('proofread_variety_menu');
        expect(
          variety.size.height,
          greaterThan(variety.getMaxIntrinsicHeight(double.infinity) * 1.5),
        );
      });

      testWidgets('menu button toggles its menu', (tester) async {
        await pumpControls(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_formality_menu')));
        await tester.pumpAndSettle();
        expect(find.text('Prefer informal'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('proofread_formality_menu')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Prefer informal'), findsNothing);
      });

      testWidgets('changes the correction level', (tester) async {
        await pumpControls(tester, readyState);
        await tester.tap(find.text('Comprehensive'));
        verify(() => cubit.setLevel(CorrectionLevel.comprehensive)).called(1);
      });

      testWidgets('uses a menu for the level when labels would not fit', (
        tester,
      ) async {
        await pumpControls(tester, readyState, size: const Size(360, 2400));
        expect(find.byType(SegmentedButton<CorrectionLevel>), findsNothing);
        await tester.tap(find.byKey(const Key('proofread_level_menu')));
        await tester.pumpAndSettle();
        // Each option shows its description.
        expect(
          find.text('A thorough polish of wording, flow and tone'),
          findsOneWidget,
        );
        await tester.tap(find.text('Comprehensive'));
        await tester.pumpAndSettle();
        verify(() => cubit.setLevel(CorrectionLevel.comprehensive)).called(1);
      });

      testWidgets('menus expose the selected option to screen readers', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pumpControls(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_style_menu')));
        await tester.pumpAndSettle();
        final general = find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('General'),
        );
        expect(
          tester.getSemantics(general),
          isSemantics(
            label: 'General',
            isSelected: true,
            isInMutuallyExclusiveGroup: true,
          ),
        );
        expect(
          tester.getSemantics(find.text('Academic')),
          isSemantics(
            label: 'Academic',
            isSelected: false,
            isInMutuallyExclusiveGroup: true,
          ),
        );
        semantics.dispose();
      });

      testWidgets('hides the engine picker for a single engine', (
        tester,
      ) async {
        await pumpControls(tester, readyState);
        expect(find.byKey(const Key('proofread_engine_menu')), findsNothing);
      });

      testWidgets('picks among several AI engines', (tester) async {
        await pumpControls(
          tester,
          readyState.copyWith(availableEngines: [openAiEngine, ollamaEngine]),
        );
        await tester.tap(find.byKey(const Key('proofread_engine_menu')));
        await tester.pumpAndSettle();
        expect(find.text('llama3'), findsOneWidget);
        expect(find.byTooltip('Runs locally'), findsOneWidget);
        await tester.tap(find.text('Ollama'));
        await tester.pumpAndSettle();
        verify(() => cubit.setEngine(ollamaEngine)).called(1);
      });

      testWidgets('adds and removes context', (tester) async {
        await pumpControls(tester, readyState);
        expect(find.byKey(const Key('proofread_context')), findsNothing);
        await tester.tap(find.text('Add context'));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('proofread_context')),
          'cover letter',
        );
        verify(() => cubit.setContext('cover letter')).called(1);

        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        verify(() => cubit.setContext('')).called(1);
        expect(find.byKey(const Key('proofread_context')), findsNothing);
      });

      testWidgets('shows existing context', (tester) async {
        await pumpControls(tester, readyState.copyWith(context: 'thesis'));
        expect(find.text('thesis'), findsOneWidget);
        expect(find.text('Add context'), findsNothing);
      });
    });

    group('result', () {
      testWidgets('shows the diff, summary and edits', (tester) async {
        await pumpView(tester, successState());
        expect(find.byKey(const Key('proofread_stale')), findsNothing);
        expect(find.text('Corrected text'), findsOneWidget);
        expect(find.byKey(const Key('proofread_diff')), findsOneWidget);
        expect(find.text('Fixed agreement and articles.'), findsOneWidget);
        expect(find.text('Suggested edits'), findsOneWidget);
        expect(find.text('3 of 3 applied'), findsOneWidget);
        expect(find.text('Grammar'), findsOneWidget);
        expect(find.text('Word choice'), findsOneWidget);
        expect(find.text('Fact check'), findsOneWidget);
        expect(find.text('Subject-verb agreement.'), findsOneWidget);
        expect(find.byType(ProofreadEditTile), findsNWidgets(3));
        expect(find.byIcon(Icons.arrow_forward), findsNWidgets(3));
      });

      testWidgets('toggles, accepts and rejects edits', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        expect(find.text('1 of 3 applied'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('proofread_edit_1')),
            matching: find.byType(Checkbox),
          ),
        );
        verify(() => cubit.toggleEdit(1)).called(1);

        await tester.tap(find.text('Accept all'));
        verify(() => cubit.acceptAll()).called(1);
        await tester.tap(find.text('Reject all'));
        verify(() => cubit.rejectAll()).called(1);
      });

      testWidgets('disables accept all when everything is applied', (
        tester,
      ) async {
        await pumpView(tester, successState());
        final accept = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Accept all'),
        );
        expect(accept.onPressed, isNull);
      });

      testWidgets('disables reject all when nothing is applied', (
        tester,
      ) async {
        await pumpView(tester, successState(accepted: {}));
        final reject = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Reject all'),
        );
        expect(reject.onPressed, isNull);
      });

      testWidgets('hides changes to show the clean output', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        await tester.tap(find.byTooltip('Hide changes'));
        await tester.pump();
        expect(find.byKey(const Key('proofread_diff')), findsNothing);
        expect(find.text('I have a apple and a orange.'), findsOneWidget);

        await tester.tap(find.byTooltip('Show changes'));
        await tester.pump();
        expect(find.byKey(const Key('proofread_diff')), findsOneWidget);
      });

      testWidgets('highlights accepted edits in the diff', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        final spans = _diffSpans(tester);
        final colors = ProofreadDiffColors.of(
          tester.element(find.byKey(const Key('proofread_diff'))),
        );
        final removed = spans.singleWhere((s) => s.text == 'has');
        final inserted = spans.singleWhere((s) => s.text == 'have');
        expect(removed.style, colors.removedStyle);
        expect(removed.style!.decoration, TextDecoration.lineThrough);
        expect(removed.semanticsLabel, 'removed: has');
        expect(inserted.style, colors.insertedStyle);
        expect(inserted.semanticsLabel, 'added: have');
        expect(spans.map((s) => s.text).join(), contains('a apple'));
      });

      testWidgets('uses a word diff for a corrected text without edits', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            input: 'I has an apple.',
            result: () =>
                const ProofreadResult(correctedText: 'We have an apple.'),
            proofreadInput: 'I has an apple.',
            acceptedEdits: {},
          ),
        );
        final spans = _diffSpans(tester);
        expect(spans.map((s) => s.text), ['I has', 'We have', ' an apple.']);
        expect(spans.every((s) => s.recognizer == null), isTrue);
      });

      testWidgets('output only contains changes that have an edit', (
        tester,
      ) async {
        final clipboard = FakeClipboard()..install(tester);
        await pumpView(
          tester,
          successState().copyWith(
            input: 'I has an apple.',
            result: () => const ProofreadResult(
              correctedText: 'We have an apple.',
              edits: [ProofreadEdit(original: 'has', replacement: 'have')],
            ),
            proofreadInput: 'I has an apple.',
            acceptedEdits: {0},
          ),
        );
        final spans = _diffSpans(tester);
        expect(spans.map((s) => s.text), ['I ', 'has', 'have', ' an apple.']);
        await tester.tap(find.byTooltip('Copy'));
        await tester.pump();
        expect(clipboard.copied, 'I have an apple.');
      });

      testWidgets('tapping a change opens its details', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        final removed = _diffSpans(tester).singleWhere((s) => s.text == 'has');
        (removed.recognizer! as TapGestureRecognizer).onTap!();
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Subject-verb agreement.'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Revert edit'));
        await tester.pumpAndSettle();
        verify(() => cubit.toggleEdit(0)).called(1);
        expect(find.byType(BottomSheet), findsNothing);
      });

      testWidgets('details of a rejected edit offer to apply it', (
        tester,
      ) async {
        await pumpView(tester, successState(accepted: {}));
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        unawaited(showProofreadEditSheet(element, 2));
        await tester.pumpAndSettle();
        expect(find.text('Fact check'), findsNWidgets(2));
        await tester.tap(find.text('Apply edit'));
        await tester.pumpAndSettle();
        verify(() => cubit.toggleEdit(2)).called(1);
      });

      testWidgets('edit sheet ignores invalid indices', (tester) async {
        await pumpView(tester, successState());
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        await showProofreadEditSheet(element, 9);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
      });

      testWidgets('edit sheet closes when a new result arrives', (
        tester,
      ) async {
        final controller = StreamController<ProofreadState>();
        addTearDown(controller.close);
        await pumpView(tester, successState(), stream: controller.stream);
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        unawaited(showProofreadEditSheet(element, 1));
        await tester.pumpAndSettle();
        expect(find.text('Revert edit'), findsOneWidget);

        controller.add(
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: 'We have an orange.',
              edits: [
                ProofreadEdit(original: 'I', replacement: 'We'),
                ProofreadEdit(original: 'apple', replacement: 'pear'),
              ],
            ),
            acceptedEdits: {0, 1},
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        verifyNever(() => cubit.toggleEdit(any()));
      });

      testWidgets('edit sheet follows the state of its edit', (tester) async {
        final controller = StreamController<ProofreadState>();
        addTearDown(controller.close);
        await pumpView(tester, successState(), stream: controller.stream);
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        unawaited(showProofreadEditSheet(element, 0));
        await tester.pumpAndSettle();
        expect(find.text('Revert edit'), findsOneWidget);

        controller.add(successState(accepted: {1, 2}));
        await tester.pumpAndSettle();
        expect(find.text('Apply edit'), findsOneWidget);
        expect(find.byType(BottomSheet), findsOneWidget);
      });

      testWidgets('copies the output', (tester) async {
        final clipboard = FakeClipboard()..install(tester);
        await pumpView(tester, successState());
        await tester.tap(find.byTooltip('Copy'));
        await tester.pump();
        expect(clipboard.copied, 'I have an apple and an orange.');
        expect(find.text('Copied to clipboard'), findsOneWidget);
      });

      testWidgets('shares the output', (tester) async {
        final calls = <MethodCall>[];
        const channel = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return 'dev.fluttercommunity.plus/share/unavailable';
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await pumpView(tester, successState(accepted: {1, 2}));
        await tester.tap(find.byTooltip('Share'));
        await tester.pump();
        expect(calls, hasLength(1));
        final arguments = calls.single.arguments as Map;
        expect(arguments['text'], 'I has an apple and an orange.');
        expect(arguments['originWidth'], greaterThan(0));
      });

      testWidgets('swallows share failures', (tester) async {
        const channel = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'error'),
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await pumpView(tester, successState());
        await tester.tap(find.byTooltip('Share'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('uses the output as input', (tester) async {
        await pumpView(tester, successState());
        await tester.tap(find.text('Use as input'));
        verify(() => cubit.useOutputAsInput()).called(1);
      });

      testWidgets('flags a result that no longer matches the input', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(input: '$sampleInput It were red.'),
        );
        expect(find.byKey(const Key('proofread_stale')), findsOneWidget);
        expect(
          find.text('Your text has changed since it was checked.'),
          findsOneWidget,
        );
        final useAsInput = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text('Use as input'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        expect(useAsInput.onPressed, isNull);

        await tester.tap(find.text('Proofread again'));
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('hides the stale notice while re-proofreading', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            input: '$sampleInput It were red.',
            status: ProofreadStatus.loading,
          ),
        );
        expect(find.byKey(const Key('proofread_stale')), findsNothing);
      });

      testWidgets('disables output actions for empty output', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              edits: [ProofreadEdit(original: 'x', replacement: '')],
            ),
            proofreadInput: 'x',
          ),
        );
        final copy = tester.widget<XActionButton>(
          find.widgetWithIcon(XActionButton, Icons.copy_rounded),
        );
        expect(copy.onPressed, isNull);
      });

      testWidgets('flags edits that could not be located', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: 'Fixed.',
              edits: [ProofreadEdit(original: 'nowhere', replacement: 'x')],
            ),
          ),
        );
        expect(
          find.text("Couldn't match this edit to your text."),
          findsOneWidget,
        );
      });

      testWidgets('shows insertions and deletions in edit tiles', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              edits: [
                ProofreadEdit(original: '', replacement: 'inserted'),
                ProofreadEdit(original: 'has ', replacement: ''),
              ],
            ),
            acceptedEdits: {0, 1},
          ),
        );
        expect(find.textContaining('inserted'), findsOneWidget);
        expect(find.byIcon(Icons.arrow_forward), findsNothing);
      });

      testWidgets('shows a clean result', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(correctedText: sampleInput),
            acceptedEdits: {},
          ),
        );
        expect(find.text('Looks good!'), findsOneWidget);
        expect(find.text('No issues found in your text.'), findsOneWidget);
        expect(find.text('Suggested edits'), findsNothing);
      });

      testWidgets('shows the summary of a clean result', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              summary: 'Clear and concise.',
            ),
            acceptedEdits: {},
          ),
        );
        expect(find.text('Clear and concise.'), findsOneWidget);
      });

      testWidgets('shows collapsible writing statistics', (tester) async {
        await pumpView(tester, successState());
        expect(find.text('Writing statistics'), findsOneWidget);
        // "I have an apple and an orange." with every edit applied.
        expect(find.text('7 words · 2 sec read'), findsOneWidget);
        expect(find.text('Words per sentence'), findsNothing);
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(find.text('Words per sentence'), findsOneWidget);
        // The language is unknown: no Flesch score.
        expect(find.text('Flesch reading ease'), findsNothing);
      });

      testWidgets('statistics follow the accepted edits', (tester) async {
        await pumpView(tester, successState(accepted: {}));
        // Nothing applied: the output is the input, 27 characters.
        expect(find.text('7 words · 2 sec read'), findsOneWidget);
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(find.text('27'), findsOneWidget);
      });

      testWidgets('shows the Flesch score for English results', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: 'I have an apple and an orange.',
              edits: sampleEdits,
              detectedLanguage: 'en',
            ),
          ),
        );
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(find.text('Flesch reading ease'), findsOneWidget);
      });

      testWidgets('needs a detected language, not just an English variety', (
        tester,
      ) async {
        // e.g. Spanish text proofread with English (UK) chosen, by a model
        // that echoed the "xx" placeholder as the language.
        await pumpView(
          tester,
          successState().copyWith(variety: () => ProofreadVariety.enGb),
        );
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(find.text('Words'), findsOneWidget);
        expect(find.text('Flesch reading ease'), findsNothing);
      });

      testWidgets('hides the Flesch score for other languages', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            variety: () => ProofreadVariety.enGb,
            result: () => const ProofreadResult(
              correctedText: 'Ich habe einen Apfel.',
              detectedLanguage: 'de',
            ),
            input: 'Ich hab einen Apfel.',
            proofreadInput: 'Ich hab einen Apfel.',
            acceptedEdits: {},
          ),
        );
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(find.text('Words'), findsOneWidget);
        expect(find.text('Flesch reading ease'), findsNothing);
      });

      testWidgets('shows writing statistics for a clean result', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(correctedText: sampleInput),
            acceptedEdits: {},
          ),
        );
        expect(find.text('Looks good!'), findsOneWidget);
        expect(find.text('Writing statistics'), findsOneWidget);
      });

      testWidgets('has no statistics before the first result', (tester) async {
        await pumpView(tester, readyState.copyWith(input: sampleInput));
        expect(find.text('Writing statistics'), findsNothing);
      });

      testWidgets('edits header wraps on a phone at 200% text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpView(
          tester,
          successState(accepted: {0}),
          size: const Size(320, 6000),
        );
        expect(tester.takeException(), isNull);
        final title = tester.getRect(find.text('Suggested edits'));
        final accept = tester.getRect(find.text('Accept all'));
        expect(accept.top, greaterThan(title.bottom));
        await tester.tap(find.text('Accept all'));
        verify(() => cubit.acceptAll()).called(1);
        await tester.tap(find.text('Reject all'));
        verify(() => cubit.rejectAll()).called(1);
      });

      testWidgets('edits header keeps the buttons beside the title', (
        tester,
      ) async {
        await pumpView(tester, successState(accepted: {0}));
        final title = tester.getRect(find.text('Suggested edits'));
        final accept = tester.getRect(find.text('Accept all'));
        expect(accept.left, greaterThan(title.right));
      });

      testWidgets('lays out right to left', (tester) async {
        setSurface(tester, const Size(800, 2400));
        whenListen(
          cubit,
          const Stream<ProofreadState>.empty(),
          initialState: successState(accepted: {0}),
        );
        whenListen(
          translateCubit,
          const Stream<TranslateState>.empty(),
          initialState: readyTranslateState,
        );
        await tester.pumpProofread(
          const Directionality(
            textDirection: TextDirection.rtl,
            child: ProofreadView(),
          ),
          translateCubit: translateCubit,
          proofreadCubit: cubit,
          router: router,
        );
        await tester.tap(find.text('Writing statistics'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final title = tester.getRect(find.text('Suggested edits'));
        final accept = tester.getRect(find.text('Accept all'));
        expect(accept.right, lessThan(title.left));
        final label = tester.getRect(find.text('Words'));
        final value = tester.getRect(find.text('7'));
        expect(value.left, lessThan(label.left));
      });

      testWidgets('keeps the result visible while re-proofreading', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(status: ProofreadStatus.loading),
        );
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('Corrected text'), findsOneWidget);
      });
    });

    group('errors', () {
      Future<void> pumpError(WidgetTester tester, Object error) => pumpView(
        tester,
        readyState.copyWith(
          input: 'text',
          status: ProofreadStatus.failure,
          error: () => error,
        ),
      );

      testWidgets('shows a generic message and retries', (tester) async {
        await pumpError(tester, Exception('boom'));
        expect(find.text("Couldn't proofread"), findsOneWidget);
        expect(
          find.text('Something went wrong. Please try again.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('explains refusals', (tester) async {
        await pumpError(tester, const LlmRefusalException('no'));
        expect(
          find.text('The model declined to proofread this text.'),
          findsOneWidget,
        );
      });

      testWidgets('explains auth errors', (tester) async {
        await pumpError(tester, const LlmApiException('x', statusCode: 401));
        expect(
          find.text(
            'The AI provider rejected the API key. Check it in Settings.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('explains rate limits', (tester) async {
        await pumpError(tester, const LlmApiException('x', statusCode: 429));
        expect(
          find.text(
            'The AI provider is rate limiting requests. Try again in a moment.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows provider messages', (tester) async {
        await pumpError(
          tester,
          const LlmApiException('model not found', statusCode: 404),
        );
        expect(
          find.text('The AI provider returned an error: model not found'),
          findsOneWidget,
        );
      });

      testWidgets('falls back for empty provider messages', (tester) async {
        await pumpError(tester, const LlmApiException(' ', statusCode: 500));
        expect(
          find.text('Something went wrong. Please try again.'),
          findsOneWidget,
        );
      });
    });

    group('privacy', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.cloudProvider,
        destination: CloudProviderDestination('OpenAI', host: 'api.openai.com'),
        engineId: 'ai:openai',
      );

      late MockTranslationRepository repository;
      late MockSettingsCubit settings;

      setUp(() {
        repository = MockTranslationRepository();
        settings = MockSettingsCubit();
        when(() => settings.state).thenReturn(const AppSettings());
        when(() => repository.instances).thenReturn(const []);
      });

      testWidgets('proofreading asks right away, then proofreads', (
        tester,
      ) async {
        final loading = readyState.copyWith(
          input: 'text',
          status: ProofreadStatus.loading,
        );
        await pumpView(
          tester,
          loading,
          stream: Stream.value(
            loading.copyWith(
              status: ProofreadStatus.failure,
              error: () => consent,
            ),
          ),
          repository: repository,
          settings: settings,
        );
        await tester.pumpAndSettle();
        expect(find.text('Send your text to OpenAI?'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Allow'),
          ),
        );
        await tester.pumpAndSettle();
        verify(() => settings.consentToProvider('openai')).called(1);
        verify(() => repository.allowOnce(consent)).called(1);
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('a refusal waiting for an answer asks inline', (
        tester,
      ) async {
        await pumpView(
          tester,
          readyState.copyWith(
            input: 'text',
            status: ProofreadStatus.failure,
            error: () => consent,
          ),
          repository: repository,
          settings: settings,
        );
        expect(find.byKey(const Key('proofread_consent')), findsOneWidget);
        await tester.tap(find.text('Allow'));
        await tester.pump();
        verify(() => repository.allowOnce(consent)).called(1);
        verify(() => cubit.proofread()).called(1);
      });
    });

    group('announcements', () {
      Future<List<String>> announce(
        WidgetTester tester,
        ProofreadState from,
        ProofreadState to,
      ) async {
        await pumpView(tester, from, stream: Stream.value(to));
        await tester.pump();
        return [
          for (final announcement in tester.takeAnnouncements())
            announcement.message,
        ];
      }

      final loading = readyState.copyWith(
        input: sampleInput,
        status: ProofreadStatus.loading,
      );

      testWidgets('announces how many edits were found', (tester) async {
        expect(await announce(tester, loading, successState()), [
          'Proofreading done: 3 suggested edits',
        ]);
      });

      testWidgets('announces a clean result', (tester) async {
        final clean = successState().copyWith(
          result: () => const ProofreadResult(correctedText: sampleInput),
          acceptedEdits: {},
        );
        expect(await announce(tester, loading, clean), [
          'No issues found in your text.',
        ]);
      });

      testWidgets('announces errors', (tester) async {
        final failed = loading.copyWith(
          status: ProofreadStatus.failure,
          error: () => const LlmRefusalException('no'),
        );
        expect(await announce(tester, loading, failed), [
          "Couldn't proofread. ${_refusalMessage(tester)}",
        ]);
      });

      testWidgets('stays quiet for other changes', (tester) async {
        expect(
          await announce(tester, successState(), successState(accepted: {0})),
          isEmpty,
        );
      });
    });

    group('wide layout', () {
      testWidgets('shows input and result side by side', (tester) async {
        await pumpView(tester, readyState, size: const Size(1400, 1000));
        expect(
          find.text(
            'Your corrected text and suggested edits will appear here.',
          ),
          findsOneWidget,
        );
        final input = tester.getTopLeft(find.byType(ProofreadInputCard));
        final result = tester.getTopLeft(find.byType(ProofreadResultSection));
        expect(result.dx, greaterThan(input.dx));
      });

      testWidgets('narrow layout has no placeholder', (tester) async {
        await pumpView(tester, readyState);
        expect(
          find.text(
            'Your corrected text and suggested edits will appear here.',
          ),
          findsNothing,
        );
      });
    });

    testWidgets('renders in dark mode with dark diff colors', (tester) async {
      await pumpView(
        tester,
        successState(),
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      final context = tester.element(find.byKey(const Key('proofread_diff')));
      final dark = ProofreadDiffColors.of(context);
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(
        dark.insertedBackground.computeLuminance(),
        lessThan(dark.insertedForeground.computeLuminance()),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

List<TextSpan> _diffSpans(WidgetTester tester) {
  final richText = tester.widget<RichText>(
    find.descendant(
      of: find.byKey(const Key('proofread_diff')),
      matching: find.byType(RichText),
    ),
  );
  final spans = <TextSpan>[];
  richText.text.visitChildren((span) {
    if (span is TextSpan && span.text != null) spans.add(span);
    return true;
  });
  return spans;
}

String _refusalMessage(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ProofreadResultSection)))
        .proofreadError(const LlmRefusalException('no'));
